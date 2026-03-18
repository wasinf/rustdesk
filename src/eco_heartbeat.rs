use std::sync::Once;
use std::thread;
use std::time::{Duration, Instant};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
};

use hbb_common::config::Config;
use hbb_common::log::{self, warn};
use serde_json::json;

use crate::hbbs_http::create_http_client_with_url;

const DEFAULT_ECO_PANEL_URL: &str = "https://painelaremoto.portalecomdo.com.br/api/heartbeat";
const DEFAULT_ECO_PANEL_API_KEY: &str =
    "2c034d3a8afc44481492d155afc167dd2962f6cd6e5c0bac24bae8d8df035e25";
const HEARTBEAT_INTERVAL_SECS: u64 = 30;
const HEARTBEAT_REQUEST_TIMEOUT_SECS: u64 = 10;
const HEARTBEAT_RETRY_DELAY_SECS: u64 = 2;
const HEARTBEAT_MAX_ATTEMPTS: u8 = 2;
const HEARTBEAT_INTERVAL_JITTER_MAX_SECS: u64 = 5;
const MISSING_CONFIG_WARN_INTERVAL_SECS: u64 = 300;
const EMPTY_ID_WARN_INTERVAL_SECS: u64 = 300;
const SERVICE_INACTIVE_WARN_INTERVAL_SECS: u64 = 300;
const HEARTBEAT_SUCCESS_LOG_INTERVAL_SECS: u64 = 600;

fn get_option_or_default(key: &str, default: &str) -> String {
    let v = Config::get_option(key);
    if v.is_empty() {
        default.to_owned()
    } else {
        v
    }
}

fn should_log_periodic(last: &mut Option<Instant>, interval_secs: u64) -> bool {
    let now = Instant::now();
    match last {
        Some(prev) if prev.elapsed() < Duration::from_secs(interval_secs) => false,
        _ => {
            *last = Some(now);
            true
        }
    }
}

fn compute_stable_jitter_secs(client_id: &str, jitter_max_secs: u64) -> u64 {
    if jitter_max_secs == 0 || client_id.is_empty() {
        return 0;
    }
    let mut hasher = DefaultHasher::new();
    client_id.hash(&mut hasher);
    hasher.finish() % (jitter_max_secs + 1)
}

pub fn start() {
    static START_ONCE: Once = Once::new();
    START_ONCE.call_once(|| {
        thread::spawn(|| {
            let mut last_missing_config_warn: Option<Instant> = None;
            let mut last_empty_id_warn: Option<Instant> = None;
            let mut client_cache: Option<(String, reqwest::blocking::Client)> = None;
            let mut consecutive_failures: u32 = 0;
            let mut last_service_inactive_warn: Option<Instant> = None;
            let mut last_success_log: Option<Instant> = None;

            loop {
                let start = Instant::now();


                #[cfg(windows)]
                {
                    if crate::platform::is_installed() && !crate::platform::is_self_service_running() {
                        if should_log_periodic(
                            &mut last_service_inactive_warn,
                            SERVICE_INACTIVE_WARN_INTERVAL_SECS,
                        ) {
                            warn!(
                                "eco heartbeat skipped: installed windows client without active EcoRemoto service"
                            );
                        }
                        thread::sleep(Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
                        continue;
                    }
                }

                let url = get_option_or_default("eco-panel-url", DEFAULT_ECO_PANEL_URL);
                let api_key =
                    get_option_or_default("eco-panel-api-key", DEFAULT_ECO_PANEL_API_KEY);
                if url.is_empty() || api_key.is_empty() {
                    if should_log_periodic(
                        &mut last_missing_config_warn,
                        MISSING_CONFIG_WARN_INTERVAL_SECS,
                    ) {
                        warn!("eco heartbeat skipped: missing eco-panel-url or eco-panel-api-key");
                    }
                    thread::sleep(Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
                    continue;
                }

                let client_id = Config::get_id();
                if client_id.is_empty() {
                    if should_log_periodic(&mut last_empty_id_warn, EMPTY_ID_WARN_INTERVAL_SECS) {
                        warn!("eco heartbeat skipped: empty client id");
                    }
                    thread::sleep(Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
                    continue;
                }
                let jitter_secs =
                    compute_stable_jitter_secs(&client_id, HEARTBEAT_INTERVAL_JITTER_MAX_SECS);

                let refresh_client = client_cache
                    .as_ref()
                    .map(|(cached_url, _)| cached_url != &url)
                    .unwrap_or(true);
                if refresh_client {
                    client_cache = Some((url.clone(), create_http_client_with_url(&url)));
                }

                let hostname = crate::common::hostname();
                let username = crate::common::username();
                let sysinfo = crate::common::get_sysinfo();
                let os = sysinfo
                    .get("os")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_owned();

                let ip = Config::get_option("local-ip-addr");
                let alias = Config::get_option("eco-alias");

                let payload = json!({
                    "client_id": client_id,
                    "hostname": hostname,
                    "username": username,
                    "alias": alias,
                    "os": os,
                    "ip": if ip.is_empty() { None::<String> } else { Some(ip) },
                    "version": crate::VERSION,
                    // Keep legacy field for backward compatibility with current panel deployments.
                    "client_version": crate::VERSION,
                    "timestamp": hbb_common::get_time(),
                });

                let mut sent = false;
                for attempt in 1..=HEARTBEAT_MAX_ATTEMPTS {
                    let Some((_, client)) = client_cache.as_ref() else {
                        break;
                    };
                    match client
                        .post(&url)
                        .header("x-api-key", api_key.clone())
                        .timeout(Duration::from_secs(HEARTBEAT_REQUEST_TIMEOUT_SECS))
                        .json(&payload)
                        .send()
                    {
                        Ok(resp) if resp.status().is_success() => {
                            sent = true;
                            if should_log_periodic(
                                &mut last_success_log,
                                HEARTBEAT_SUCCESS_LOG_INTERVAL_SECS,
                            ) {
                                log::info!(
                                    "eco heartbeat sent successfully (attempt {}/{})",
                                    attempt,
                                    HEARTBEAT_MAX_ATTEMPTS
                                );
                            }
                            if consecutive_failures > 0 {
                                log::info!(
                                    "eco heartbeat recovered after {} failure(s)",
                                    consecutive_failures
                                );
                                consecutive_failures = 0;
                            }
                            break;
                        }
                        Ok(resp) => {
                            warn!(
                                "eco heartbeat attempt {}/{} returned http {}",
                                attempt,
                                HEARTBEAT_MAX_ATTEMPTS,
                                resp.status()
                            );
                        }
                        Err(err) => {
                            warn!(
                                "eco heartbeat attempt {}/{} failed: {}",
                                attempt,
                                HEARTBEAT_MAX_ATTEMPTS,
                                err
                            );
                        }
                    }

                    if attempt < HEARTBEAT_MAX_ATTEMPTS {
                        client_cache = Some((url.clone(), create_http_client_with_url(&url)));
                        thread::sleep(Duration::from_secs(HEARTBEAT_RETRY_DELAY_SECS));
                    }
                }

                if !sent {
                    consecutive_failures = consecutive_failures.saturating_add(1);
                }

                let elapsed = start.elapsed();
                let cycle_sleep = Duration::from_secs(HEARTBEAT_INTERVAL_SECS + jitter_secs);
                if elapsed < cycle_sleep {
                    thread::sleep(cycle_sleep - elapsed);
                }
            }
        });
        log::info!("eco heartbeat started");
    });
}

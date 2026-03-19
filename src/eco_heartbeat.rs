use std::thread;
use std::time::{Duration, Instant};
use std::sync::Once;

use hbb_common::config::Config;
use hbb_common::log::{self, warn};
use serde_json::json;

use crate::hbbs_http::create_http_client_with_url;

const DEFAULT_ECO_PANEL_URL: &str = "https://painelaremoto.portalecomdo.com.br/api/heartbeat";
const DEFAULT_ECO_PANEL_API_KEY: &str = "2c034d3a8afc44481492d155afc167dd2962f6cd6e5c0bac24bae8d8df035e25";
const HEARTBEAT_INTERVAL_SECS: u64 = 30;
const HEARTBEAT_REQUEST_TIMEOUT_SECS: u64 = 10;
const HEARTBEAT_RETRY_DELAY_SECS: u64 = 2;
const HEARTBEAT_MAX_ATTEMPTS: u8 = 2;
const MISSING_CONFIG_WARN_INTERVAL_SECS: u64 = 300;
const EMPTY_ID_WARN_INTERVAL_SECS: u64 = 300;

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

pub fn start() {
    static START_ONCE: Once = Once::new();
    START_ONCE.call_once(|| {
        thread::spawn(|| {
            let mut last_missing_config_warn: Option<Instant> = None;
            let mut last_empty_id_warn: Option<Instant> = None;
            let mut client_cache: Option<(String, reqwest::blocking::Client)> = None;
            let mut consecutive_failures: u32 = 0;

            loop {
                let start = Instant::now();

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
                let now_ms = hbb_common::get_time();
                let now_s = now_ms / 1000;

                let payload = json!({
                    "id": client_id.clone(),
                    "client_id": client_id,
                    "hostname": hostname,
                    "username": username,
                    "alias": alias,
                    "os": os,
                    "ip": if ip.is_empty() { None::<String> } else { Some(ip) },
                    "version": crate::VERSION,
                    "client_version": crate::VERSION,
                    "timestamp": now_s,
                    "ts": now_s,
                    "timestamp_ms": now_ms,
                });

                let mut sent = false;
                for attempt in 1..=HEARTBEAT_MAX_ATTEMPTS {
                    let Some((_, client)) = client_cache.as_ref() else {
                        break;
                    };
                    match client
                        .post(&url)
                        .header("x-api-key", api_key.clone())
                        .header("X-API-Key", api_key.clone())
                        .header("Authorization", format!("Bearer {}", api_key))
                        .timeout(Duration::from_secs(HEARTBEAT_REQUEST_TIMEOUT_SECS))
                        .json(&payload)
                        .send()
                    {
                        Ok(resp) if resp.status().is_success() => {
                            sent = true;
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
                if elapsed < Duration::from_secs(HEARTBEAT_INTERVAL_SECS) {
                    thread::sleep(Duration::from_secs(HEARTBEAT_INTERVAL_SECS) - elapsed);
                }
            }
        });
        log::info!("eco heartbeat started");
    });
}

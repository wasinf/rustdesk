"""Reference implementation for PainelAremoto heartbeat compatibility.

This module is intentionally self-contained so it can be copied into the painel
repository and integrated with existing models/routes without changing endpoint
shape.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass
from typing import Optional

from fastapi import Header, HTTPException
from pydantic import BaseModel, Field, root_validator

logger = logging.getLogger("painel.heartbeat")


class HeartbeatIn(BaseModel):
    client_id: str = Field(min_length=1)
    hostname: Optional[str] = ""
    username: Optional[str] = ""
    alias: Optional[str] = ""
    os: Optional[str] = ""
    ip: Optional[str] = ""
    version: Optional[str] = None
    client_version: Optional[str] = None
    timestamp: Optional[int] = None

    @root_validator(pre=False)
    def normalize_fields(cls, values):
        version = (values.get("version") or "").strip()
        legacy = (values.get("client_version") or "").strip()
        if not version and not legacy:
            raise ValueError("version or client_version is required")
        values["version"] = version or legacy
        values["client_version"] = legacy or values["version"]
        values["timestamp"] = values.get("timestamp") or int(time.time())
        return values


@dataclass(frozen=True)
class StatusThresholds:
    online_s: int = int(os.getenv("HEARTBEAT_ONLINE_SECONDS", "60"))
    delay_s: int = int(os.getenv("HEARTBEAT_DELAY_SECONDS", "180"))


def accepted_api_keys() -> set[str]:
    keys: set[str] = set()
    primary = os.getenv("ECO_PANEL_API_KEY", "").strip()
    if primary:
        keys.add(primary)

    # Optional future key rotation: comma-separated list
    # ex: ECO_PANEL_API_KEYS="newkey,oldkey"
    for k in os.getenv("ECO_PANEL_API_KEYS", "").split(","):
        k = k.strip()
        if k:
            keys.add(k)
    return keys


def validate_api_key(x_api_key: str | None = Header(default=None, alias="x-api-key")) -> None:
    if not x_api_key:
        logger.warning("heartbeat rejected: missing x-api-key")
        raise HTTPException(status_code=401, detail="missing api key")

    if x_api_key not in accepted_api_keys():
        suffix = x_api_key[-4:] if len(x_api_key) >= 4 else "***"
        logger.warning("heartbeat rejected: invalid x-api-key suffix=%s", suffix)
        raise HTTPException(status_code=401, detail="invalid api key")


def compute_status(now_ts: int, last_heartbeat_ts: int, thresholds: StatusThresholds | None = None) -> str:
    thresholds = thresholds or StatusThresholds()
    lag = max(0, now_ts - last_heartbeat_ts)
    if lag <= thresholds.online_s:
        return "ONLINE"
    if lag <= thresholds.delay_s:
        return "DELAY"
    return "OFFLINE"


def normalize_for_storage(payload: HeartbeatIn) -> dict:
    return {
        "client_id": payload.client_id,
        "hostname": payload.hostname or "",
        "username": payload.username or "",
        "alias": payload.alias or "",
        "os": payload.os or "",
        "ip": payload.ip or "",
        "version": payload.version,
        # keep legacy field populated for backward compatibility
        "client_version": payload.client_version or payload.version,
        "last_heartbeat_ts": payload.timestamp,
        "status": compute_status(int(time.time()), int(payload.timestamp or int(time.time()))),
    }


def log_accept(payload: HeartbeatIn) -> None:
    logger.info(
        "heartbeat accepted client_id=%s version=%s ts=%s",
        payload.client_id,
        payload.version,
        payload.timestamp,
    )

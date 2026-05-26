"""Consent tokens + audit logger for privacy gate operations.

ConsentStore issues short-lived (30-minute default TTL) bounded-use tokens
that authorize a single privacy-sensitive operation (e.g., cloud cleanup).
The token binds (session_id, operation) and is consumed on N uses
(N defaults to 1; cleanup grants 2 to allow preview + commit).

AuditLogger emits structured JSON to the 'voxflow.audit' channel so audit
events can be routed separately from operational logs.
"""

from __future__ import annotations

import json
import logging
import secrets
import time
from dataclasses import dataclass
from threading import Lock


@dataclass
class ConsentRecord:
    token: str
    session_id: str
    operation: str
    original_text: str
    redacted_text: str
    created_at: float
    max_uses: int = 1
    use_count: int = 0


class ConsentStore:
    def __init__(self, ttl_seconds: int = 1800) -> None:
        self._ttl_seconds = ttl_seconds
        self._records: dict[str, ConsentRecord] = {}
        self._lock = Lock()

    def create(self, session_id: str, operation: str, original_text: str, redacted_text: str, max_uses: int = 1) -> ConsentRecord:
        token = secrets.token_urlsafe(20)
        record = ConsentRecord(
            token=token,
            session_id=session_id,
            operation=operation,
            original_text=original_text,
            redacted_text=redacted_text,
            created_at=time.time(),
            max_uses=max(1, max_uses),
        )
        with self._lock:
            self._prune_locked()
            self._records[token] = record
        return record

    def resolve(self, token: str, session_id: str, operation: str) -> ConsentRecord | None:
        with self._lock:
            self._prune_locked()
            record = self._records.get(token)
            if not record:
                return None
            if record.session_id != session_id or record.operation != operation:
                return None
            record.use_count += 1
            if record.use_count >= record.max_uses:
                self._records.pop(token, None)
            return record

    def _prune_locked(self) -> None:
        cutoff = time.time() - self._ttl_seconds
        expired = [token for token, record in self._records.items() if record.created_at < cutoff]
        for token in expired:
            self._records.pop(token, None)


class AuditLogger:
    _audit_logger = logging.getLogger("voxflow.audit")

    def log(self, *, operation: str, provider_mode: str, session_id: str, payload_length: int, redacted: bool) -> None:
        self._audit_logger.info(
            json.dumps(
                {
                    "event": "privacy_audit",
                    "operation": operation,
                    "provider_mode": provider_mode,
                    "session_id": session_id,
                    "payload_length": payload_length,
                    "redacted": redacted,
                    "timestamp": int(time.time()),
                }
            ),
        )

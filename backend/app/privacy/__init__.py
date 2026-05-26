"""Privacy primitives — consent tokens, audit logging, and PII redaction.

ConsentStore is thread-safe with a Lock; tokens are bounded-use (default 1,
with cleanup requests getting 2 to allow preview + commit). AuditLogger emits
JSON events to a dedicated 'voxflow.audit' logger so they can be routed
separately from operational logs.
"""

from .consent import AuditLogger, ConsentRecord, ConsentStore
from .redaction import redact_sensitive_text

__all__ = [
    "AuditLogger",
    "ConsentRecord",
    "ConsentStore",
    "redact_sensitive_text",
]

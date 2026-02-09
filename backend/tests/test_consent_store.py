"""Unit tests for ConsentStore."""

from __future__ import annotations

import sys
import threading
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import ConsentStore


class TestConsentStoreHappyPath:
    def test_create_and_resolve(self):
        store = ConsentStore()
        record = store.create("sess-1", "cleanup", "original", "redacted")
        resolved = store.resolve(record.token, "sess-1", "cleanup")
        assert resolved is not None
        assert resolved.original_text == "original"
        assert resolved.redacted_text == "redacted"


class TestConsentStoreIsolation:
    def test_wrong_session_returns_none(self):
        store = ConsentStore()
        record = store.create("sess-1", "cleanup", "original", "redacted")
        assert store.resolve(record.token, "sess-WRONG", "cleanup") is None

    def test_wrong_operation_returns_none(self):
        store = ConsentStore()
        record = store.create("sess-1", "cleanup", "original", "redacted")
        assert store.resolve(record.token, "sess-1", "translate") is None

    def test_invalid_token_returns_none(self):
        store = ConsentStore()
        store.create("sess-1", "cleanup", "original", "redacted")
        assert store.resolve("bogus-token", "sess-1", "cleanup") is None


class TestConsentStoreTTL:
    def test_expired_record_returns_none(self):
        store = ConsentStore(ttl_seconds=10)
        record = store.create("sess-1", "cleanup", "original", "redacted")

        # Simulate time advancing past TTL
        with patch("server.time") as mock_time:
            # First call: create was at real time. Now simulate resolve at +20s.
            mock_time.time.return_value = record.created_at + 20
            result = store.resolve(record.token, "sess-1", "cleanup")
        assert result is None


class TestConsentStoreUniqueness:
    def test_100_tokens_all_unique(self):
        store = ConsentStore()
        tokens = set()
        for i in range(100):
            record = store.create(f"sess-{i}", "cleanup", "text", "redacted")
            tokens.add(record.token)
        assert len(tokens) == 100


class TestConsentStorePrune:
    def test_prune_removes_expired_only(self):
        store = ConsentStore(ttl_seconds=10)
        old = store.create("sess-old", "cleanup", "old", "old-r")
        new = store.create("sess-new", "cleanup", "new", "new-r")

        # Make the old record appear expired
        old.created_at -= 20

        # Next resolve triggers prune
        result = store.resolve(new.token, "sess-new", "cleanup")
        assert result is not None
        assert store.resolve(old.token, "sess-old", "cleanup") is None


class TestConsentStoreThreadSafety:
    def test_concurrent_creates(self):
        store = ConsentStore()
        tokens: list[str] = []
        lock = threading.Lock()
        errors: list[Exception] = []

        def create_records(thread_id: int):
            try:
                for i in range(20):
                    record = store.create(f"sess-{thread_id}-{i}", "cleanup", "text", "redacted")
                    with lock:
                        tokens.append(record.token)
            except Exception as e:
                with lock:
                    errors.append(e)

        threads = [threading.Thread(target=create_records, args=(t,)) for t in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors, f"Thread errors: {errors}"
        assert len(tokens) == 100
        assert len(set(tokens)) == 100  # all unique

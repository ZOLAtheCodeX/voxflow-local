"""Context helper tests.

Session 29 stability review: `run_blocking` used the DEFAULT executor, so
the ML semaphore was the only concurrency bound — and a cancelled request
(esc mid-transcription, client timeout) releases its permit while the decode
thread runs on. An immediate re-dictation then put >2 ML evaluations on a
16 GB machine. A dedicated 2-worker pool makes the executor itself the hard
cap, independent of coroutine cancellation.
"""

import asyncio
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import context


def test_ml_executor_caps_concurrency_at_two():
    active = 0
    peak = 0
    lock = threading.Lock()

    def work():
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
        time.sleep(0.15)
        with lock:
            active -= 1

    async def main():
        await asyncio.gather(*(context.run_blocking(work) for _ in range(4)))

    asyncio.run(main())
    assert peak <= 2, f"ML work must never exceed 2 concurrent evaluations, saw {peak}"


def test_cached_probe_serves_within_ttl_and_refreshes_after(monkeypatch):
    """Session 29 review (low): /v1/ready ran fresh per-provider network
    probes on every 2 s warmup poll — up to ~1.5 s of threadpool time per
    configured provider per poll. Probes now share a short TTL cache."""
    fake_now = [1000.0]
    monkeypatch.setattr(context.time, "monotonic", lambda: fake_now[0])
    context._PROBE_CACHE.clear()

    calls = {"n": 0}

    def probe():
        calls["n"] += 1
        return {"gemma4:e2b-mlx"}

    assert context.cached_probe("ollama_models:ollama", probe) == {"gemma4:e2b-mlx"}
    assert context.cached_probe("ollama_models:ollama", probe) == {"gemma4:e2b-mlx"}
    assert calls["n"] == 1, "second call within the TTL must be served from cache"

    fake_now[0] += 6.0  # past the 5 s TTL
    context.cached_probe("ollama_models:ollama", probe)
    assert calls["n"] == 2, "TTL expiry must refresh the probe"


def test_cached_probe_does_not_cache_failures(monkeypatch):
    fake_now = [1000.0]
    monkeypatch.setattr(context.time, "monotonic", lambda: fake_now[0])
    context._PROBE_CACHE.clear()
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        raise RuntimeError("probe down")

    for _ in range(2):
        try:
            context.cached_probe("openai_compat:lmstudio", flaky)
        except RuntimeError:
            pass
    assert calls["n"] == 2, "failures must not be cached — recovery should be visible next poll"

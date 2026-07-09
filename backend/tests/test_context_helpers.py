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

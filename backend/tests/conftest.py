"""Shared pytest configuration for backend tests."""

import atexit
import os
import shutil
import sys
import tempfile
from pathlib import Path

import pytest

# Add the tests directory to sys.path so sibling modules (e.g. regression_utils)
# are importable even when pytest treats this directory as a package.
sys.path.insert(0, str(Path(__file__).resolve().parent))
# And the app directory, so fixtures can import engines regardless of which
# test module runs first.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

# Trust-boundary test environment. This must run at import time, before any
# test module imports ``server``: ``trust.active_token`` caches the token on
# first use. The assignments are unconditional (not ``setdefault``) so a
# developer's shell token never leaks into tests, and the token directory is a
# temp dir so tests never touch the real ~/Library/Application Support/VoxFlow.
os.environ["VOXFLOW_API_TOKEN"] = "ab" * 32
_TOKEN_DIR = tempfile.mkdtemp(prefix="voxflow-token-")
os.environ["VOXFLOW_TOKEN_DIR"] = _TOKEN_DIR
atexit.register(shutil.rmtree, _TOKEN_DIR, ignore_errors=True)


@pytest.fixture(params=["asyncio"])
def anyio_backend(request):
    """Run async tests with asyncio only (skip trio)."""
    return request.param


@pytest.fixture(autouse=True)
def _pin_memory_pressure_to_normal(monkeypatch):
    """The polish memory guard reads the HOST kernel's LIVE pressure level —
    caught in session 29 when a long build session pushed the dev machine to
    level 2 and 22 unrelated polish tests silently degraded to the regex
    floor and failed. Tests must not be hostage to host memory state: pin to
    normal here; the guard's own tests monkeypatch the source explicitly
    (their setattr overrides this autouse default)."""
    from engines import llm_backend

    monkeypatch.setattr(llm_backend, "detect_memory_pressure_level", lambda: 1)

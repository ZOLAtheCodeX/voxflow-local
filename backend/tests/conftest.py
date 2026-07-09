"""Shared pytest configuration for backend tests."""

import sys
from pathlib import Path

import pytest

# Add the tests directory to sys.path so sibling modules (e.g. regression_utils)
# are importable even when pytest treats this directory as a package.
sys.path.insert(0, str(Path(__file__).resolve().parent))
# And the app directory, so fixtures can import engines regardless of which
# test module runs first.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))


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

"""Shared pytest configuration for backend tests."""

import sys
from pathlib import Path

import pytest

# Add the tests directory to sys.path so sibling modules (e.g. regression_utils)
# are importable even when pytest treats this directory as a package.
sys.path.insert(0, str(Path(__file__).resolve().parent))


@pytest.fixture(params=["asyncio"])
def anyio_backend(request):
    """Run async tests with asyncio only (skip trio)."""
    return request.param

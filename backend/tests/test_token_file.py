"""Token file mirror: written at lifespan startup, removed at shutdown.

Spec Decision 5. Every path here lives under ``tmp_path`` (or conftest's temp
``VOXFLOW_TOKEN_DIR``); nothing touches the real Application Support folder.
"""

import os
import stat
from pathlib import Path

from api_clients import TEST_BASE_URL
from starlette.testclient import TestClient

from token_file import remove_token_file, token_file_path, write_token_file


def test_written_file_is_0600_with_exact_token(tmp_path):
    p = tmp_path / "backend.token"
    assert write_token_file("ab" * 32, p) is not None
    assert p.read_text() == "ab" * 32
    assert stat.S_IMODE(p.stat().st_mode) == 0o600


def test_missing_directory_is_created_0700(tmp_path):
    p = tmp_path / "VoxFlow" / "backend.token"
    write_token_file("ab" * 32, p)
    assert stat.S_IMODE(p.parent.stat().st_mode) == 0o700


def test_existing_directory_mode_is_untouched(tmp_path):
    tmp_path.chmod(0o755)
    write_token_file("ab" * 32, tmp_path / "backend.token")
    assert stat.S_IMODE(tmp_path.stat().st_mode) == 0o755


def test_remove_only_when_still_ours(tmp_path):
    p = tmp_path / "backend.token"
    mine = write_token_file("ab" * 32, p)
    write_token_file("cd" * 32, p)  # successor replaced it
    assert remove_token_file(p, mine) is False and p.exists()
    theirs = (p.stat().st_dev, p.stat().st_ino)
    assert remove_token_file(p, theirs) is True and not p.exists()


def test_write_failure_returns_none(tmp_path):
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o500)
    try:
        assert write_token_file("ab" * 32, ro / "backend.token") is None
    finally:
        ro.chmod(0o700)


def test_lifespan_writes_and_removes_token_file(monkeypatch, tmp_path):
    monkeypatch.setenv("VOXFLOW_TOKEN_DIR", str(tmp_path))
    import server

    # the real startup loads the Whisper model under the Python default backend
    monkeypatch.setattr(server, "initialize_runtime_state", lambda: None)
    with TestClient(server.app, base_url=TEST_BASE_URL):  # enters lifespan
        assert (tmp_path / "backend.token").read_text() == os.environ["VOXFLOW_API_TOKEN"]
    assert not (tmp_path / "backend.token").exists()


def test_token_file_path_honours_override():
    assert token_file_path({"VOXFLOW_TOKEN_DIR": "/x"}) == Path("/x/backend.token")
    assert token_file_path({}).parts[-3:] == ("Application Support", "VoxFlow", "backend.token")

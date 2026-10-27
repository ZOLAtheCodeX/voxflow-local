"""Mirror of the active backend token on disk.

The managed app already holds the token it launched the backend with, but
developer scripts and the app's adopt-foreign-backend mode need to read the
token of a backend someone else started. The backend therefore mirrors it to
``<dir>/backend.token`` (mode 0600) during lifespan startup and removes it on
shutdown, but only if the file is still the one this process wrote, so a
successor's file is never deleted.

The token is never logged.
"""

from __future__ import annotations

import logging
import os
import secrets
from collections.abc import Mapping
from pathlib import Path

logger = logging.getLogger("voxflow")

TOKEN_DIR_ENV_VAR = "VOXFLOW_TOKEN_DIR"
TOKEN_FILE_NAME = "backend.token"


def token_file_path(env: Mapping[str, str] | None = None) -> Path:
    """``$VOXFLOW_TOKEN_DIR/backend.token``, else the Application Support default."""
    environ = os.environ if env is None else env
    override = environ.get(TOKEN_DIR_ENV_VAR)
    if override:
        return Path(override) / TOKEN_FILE_NAME
    return Path.home() / "Library" / "Application Support" / "VoxFlow" / TOKEN_FILE_NAME


def write_token_file(token: str, path: Path) -> tuple[int, int] | None:
    """Atomically write ``token`` to ``path`` with mode 0600.

    Returns the ``(st_dev, st_ino)`` of the written file, or ``None`` after
    logging a warning if anything failed. A failure never raises: the backend
    keeps running, only scripts and adopt mode lose access to the token.
    """
    parent = path.parent
    temp_path = parent / f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}"
    try:
        # Create the directory only when absent, and never touch an existing one.
        if not parent.exists():
            os.makedirs(parent, mode=0o700)
        descriptor = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(token)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, path)
        except BaseException:
            temp_path.unlink(missing_ok=True)
            raise
        written = os.stat(path)
    except OSError as error:
        logger.warning("Could not write backend token file %s: %s", path, error.strerror or error)
        return None
    return (written.st_dev, written.st_ino)


def remove_token_file(path: Path, identity: tuple[int, int]) -> bool:
    """Unlink ``path`` only if its current ``(st_dev, st_ino)`` equals ``identity``."""
    try:
        current = os.stat(path)
        if (current.st_dev, current.st_ino) != identity:
            return False
        os.unlink(path)
    except FileNotFoundError:
        return False
    except OSError as error:
        logger.warning("Could not remove backend token file %s: %s", path, error.strerror or error)
        return False
    return True

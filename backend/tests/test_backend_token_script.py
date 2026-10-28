"""Shell helper that finds the backend token for doctor.sh / check_runtime_readiness.sh.

Spec Decision 12. Runs the helper through /bin/bash (macOS's 3.2) with a
scrubbed environment so the real Application Support folder is never read.
"""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run_lookup(env):
    script = f'source "{ROOT}/scripts/lib/backend_token.sh"; voxflow_backend_token'
    return subprocess.run(
        ["/bin/bash", "-c", script],
        env={"PATH": "/usr/bin:/bin", **env},
        capture_output=True,
        text=True,
    )


def test_token_lookup_reads_file(tmp_path):
    (tmp_path / "backend.token").write_text("ab" * 32)
    assert run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path)}).stdout == "ab" * 32


def test_token_lookup_trims_whitespace(tmp_path):
    (tmp_path / "backend.token").write_text("ab" * 32 + "\n")
    assert run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path)}).stdout == "ab" * 32


def test_token_lookup_falls_back_to_env_then_fails(tmp_path):
    result = run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path), "VOXFLOW_API_TOKEN": "cd" * 32})
    assert result.stdout == "cd" * 32
    result = run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path)})
    assert result.returncode == 1 and result.stdout == ""

"""Registry tests are pure; subprocess checks only prepare JSON, never OS effects."""
import json
from pathlib import Path
import subprocess
import sys

import pytest

from computer_actions import load_registry, prepare

SCRIPT = Path(__file__).parents[1] / "app" / "computer_actions.py"


def test_every_shipped_action_prepares_exact_registered_arguments():
    registry = load_registry()
    assert len(registry) == 12
    for action_id, action in registry.items():
        assert prepare({"version": 1, "action_id": action_id}) == {
            "version": 1, "id": action_id, "operation": action["operation"], "argument": action["argument"],
        }


@pytest.mark.parametrize("payload", [
    None, [], {}, {"version": 2, "action_id": "copy_selection"},
    {"version": True, "action_id": "copy_selection"},
    {"version": 1, "action_id": []}, {"version": 1, "action_id": "unknown"},
    {"version": 1, "action_id": "copy_selection", "argument": "shell"},
    {"version": 1, "action_id": "copy_selection; rm -rf example"},
])
def test_invalid_requests_are_rejected(payload):
    with pytest.raises(ValueError):
        prepare(payload)


@pytest.mark.parametrize("changes", [
    {"operation": "shell"}, {"argument": "com.unregistered.app"},
    {"phrases": ["open finder", "open finder"]}, {"phrases": ["open\nfinder"]},
    {"phrases": []}, {"extra": True},
])
def test_invalid_registry_never_dispatches(tmp_path, changes):
    action = next(iter(load_registry().values())) | changes
    path = tmp_path / "actions.json"
    path.write_text(json.dumps({"version": 1, "actions": [action]}))
    with pytest.raises(ValueError):
        load_registry(path)


def test_standalone_protocol_is_isolated_and_reports_errors_without_echoing_input():
    result = subprocess.run([sys.executable, "-I", "-S", str(SCRIPT)],
                            input=b'{"version":1,"action_id":"copy_selection"}', capture_output=True, timeout=3)
    assert result.returncode == 0
    assert json.loads(result.stdout)["argument"] == "copy"
    for raw in [b"{private invalid json", b"x" * 4097]:
        result = subprocess.run([sys.executable, "-I", "-S", str(SCRIPT)], input=raw, capture_output=True, timeout=3)
        assert result.returncode == 1
        assert json.loads(result.stdout) == {"error": "Computer action could not be prepared"}
        assert not result.stderr


def test_standalone_import_does_not_load_model_or_web_server_dependencies():
    code = "import runpy,sys,json; runpy.run_path(sys.argv[1]); print(json.dumps(sorted(sys.modules)))"
    result = subprocess.run([sys.executable, "-I", "-S", "-c", code, str(SCRIPT)], capture_output=True, timeout=3, check=True)
    modules = set(json.loads(result.stdout))
    assert not modules.intersection({"torch", "transformers", "fastapi", "uvicorn", "ollama", "requests"})

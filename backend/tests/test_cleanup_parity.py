"""Behavioral parity with Sources/VoxFlowApp/Services/TextCleanupService.swift.

Both implementations consume Tests/Fixtures/cleanup_rules_parity.json.
Mirror the project-root mechanism used by the hallucination parity test in
test_utils.py — verify against that file and reuse its exact approach.
"""

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import light_cleanup


def test_cleanup_rules_parity_fixture():
    project_root = Path(__file__).resolve().parents[2]
    fixture = project_root / "Tests" / "Fixtures" / "cleanup_rules_parity.json"
    cases = json.loads(fixture.read_text(encoding="utf-8"))["cases"]
    assert len(cases) >= 10, "fixture unexpectedly small — wrong file?"

    failures = []
    for c in cases:
        got = light_cleanup(c["input"])
        if got != c["expected"]:
            failures.append(f"{c['input']!r}: expected {c['expected']!r}, got {got!r} — {c.get('note', '')}")
    assert not failures, "\n".join(failures)

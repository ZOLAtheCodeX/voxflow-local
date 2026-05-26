#!/usr/bin/env python3
"""Measure PolishEngine latency against a live Ollama server.

The Phase 3.4 acceptance gate asks us to *measure and document* on-device
latency for both ``gemma4:e2b-mlx`` and ``gemma4:e4b-mlx`` before flipping
the default. Real numbers can only be collected on the dev machine with
Ollama actually running, so this script lives outside the test suite —
running it isn't a CI gate.

Usage::

    # 1. Start Ollama and pull the models you want to benchmark:
    ollama pull gemma4:e2b-mlx
    ollama pull gemma4:e4b-mlx

    # 2. Run the benchmark:
    ./.venv/bin/python scripts/measure_polish_latency.py

    # 3. Paste the printed table into the Phase 3 PR description and
    #    into docs/plans/2026-05-25-stabilization-modernization-roadmap.md
    #    § Phase 3 § "Performance expectation" (replace the estimates).

The benchmark runs each golden case through both models, discards the
first call per model as the cold-start sample, and reports p50 / p95
plus the cold-start time so the reader can see what the worst-case
first call looks like after a fresh Ollama restart.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "app"))

from engines.llm_backend import OllamaBackend, probe_ollama_available  # noqa: E402
from engines.polish import PolishEngine  # noqa: E402

GOLDEN_PATH = REPO_ROOT / "backend" / "tests" / "golden_polish_set.json"
DEFAULT_MODELS = ["gemma4:e2b-mlx", "gemma4:e4b-mlx"]


def _load_cases() -> list[dict]:
    with GOLDEN_PATH.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _bench_model(model: str, cases: list[dict]) -> dict:
    backend = OllamaBackend(model=model)
    engine = PolishEngine(backend=backend)

    samples_ms: list[float] = []
    cold_ms: float | None = None
    triggered = 0

    for case in cases:
        start = time.perf_counter()
        _, was_triggered = engine.polish(case["input"], case["tone"])
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        if cold_ms is None:
            cold_ms = elapsed_ms
            continue  # discard the cold-start sample from steady-state stats
        samples_ms.append(elapsed_ms)
        if was_triggered:
            triggered += 1

    if not samples_ms:
        return {"model": model, "error": "no steady-state samples (corpus too small)"}

    sorted_samples = sorted(samples_ms)
    p50 = statistics.median(sorted_samples)
    p95 = sorted_samples[int(len(sorted_samples) * 0.95)] if len(sorted_samples) > 1 else sorted_samples[0]

    return {
        "model": model,
        "cold_ms": round(cold_ms or 0.0, 1),
        "steady_p50_ms": round(p50, 1),
        "steady_p95_ms": round(p95, 1),
        "guardrail_triggered": f"{triggered}/{len(samples_ms)}",
        "samples": len(samples_ms),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--models",
        nargs="+",
        default=DEFAULT_MODELS,
        help="Ollama model ids to benchmark (default: e2b-mlx and e4b-mlx).",
    )
    args = ap.parse_args()

    if not probe_ollama_available(force=True):
        print("error: Ollama is not reachable at http://localhost:11434", file=sys.stderr)
        print("       start it with `ollama serve` and retry.", file=sys.stderr)
        return 1

    cases = _load_cases()
    print(f"running {len(cases)} golden cases against {len(args.models)} model(s)\n")

    results = [_bench_model(model, cases) for model in args.models]

    # Markdown table for easy paste into PR / roadmap doc.
    print("| Model | Cold (ms) | Steady p50 (ms) | Steady p95 (ms) | Guardrail trips |")
    print("|---|---|---|---|---|")
    for r in results:
        if "error" in r:
            print(f"| {r['model']} | — | — | — | {r['error']} |")
            continue
        print(
            f"| {r['model']} | {r['cold_ms']} | {r['steady_p50_ms']} | "
            f"{r['steady_p95_ms']} | {r['guardrail_triggered']} |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

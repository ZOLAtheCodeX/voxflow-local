#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import statistics
import sys
import time
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from regression_utils import is_placeholder_text, meaning_drift_metrics, normalize_text, percentile, word_count

ROOT_DIR = Path(__file__).resolve().parents[2]
BACKEND_APP_DIR = ROOT_DIR / "backend" / "app"
if str(BACKEND_APP_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_APP_DIR))

# Default to workspace-local model cache when available.
if "VOXFLOW_MODELS_DIR" not in os.environ:
    default_models_dir = ROOT_DIR / "models"
    if default_models_dir.is_dir():
        os.environ["VOXFLOW_MODELS_DIR"] = str(default_models_dir)

# Keep deterministic local behavior by default.
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_STT_ALLOW_FALLBACK", "1")

import server  # noqa: E402


@dataclass
class CheckResult:
    id: str
    backend: str
    passed: bool
    details: str


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if "clips" not in manifest or not isinstance(manifest["clips"], list):
        raise ValueError("Manifest must define clips[]")
    if "cleanup_cases" not in manifest or not isinstance(manifest["cleanup_cases"], list):
        raise ValueError("Manifest must define cleanup_cases[]")
    return manifest


def decode_audio_file(path: Path) -> tuple[bytes, int]:
    if path.suffix.lower() != ".wav":
        raise ValueError(f"Unsupported audio extension for regression clip: {path}")

    with wave.open(str(path), "rb") as audio_file:
        channels = audio_file.getnchannels()
        sample_width = audio_file.getsampwidth()
        sample_rate = audio_file.getframerate()
        frames = audio_file.readframes(audio_file.getnframes())
        if sample_width != 2:
            raise ValueError(f"Expected 16-bit PCM wav, got sample width {sample_width} for {path}")
        if channels != 1:
            raise ValueError(f"Expected mono wav, got {channels} channels for {path}")

    return frames, sample_rate


def resolve_expectation(clip: dict[str, Any], backend: str) -> dict[str, Any]:
    base = dict(clip.get("expected", {}))
    override = clip.get("expected_by_backend", {}).get(backend, {})
    base.update(override)
    return base


def validate_transcript(text: str, expectation: dict[str, Any]) -> tuple[str | None, dict[str, float]]:
    normalized = normalize_text(text)
    lowered = normalized.lower()
    metrics: dict[str, float] = {}

    allow_placeholder = bool(expectation.get("allow_placeholder", False))
    if is_placeholder_text(normalized) and not allow_placeholder:
        return "received placeholder transcript", metrics

    min_words = int(expectation.get("min_words", 1))
    max_words = int(expectation.get("max_words", 200))
    words = word_count(normalized)
    if words < min_words or words > max_words:
        return f"word count {words} outside [{min_words}, {max_words}]", metrics

    must_include_all = [str(token).lower() for token in expectation.get("must_include_all", [])]
    missing_all = [token for token in must_include_all if token not in lowered]
    if missing_all:
        return f"missing required tokens: {missing_all}", metrics

    must_include_any = [str(token).lower() for token in expectation.get("must_include_any", [])]
    if must_include_any and not any(token in lowered for token in must_include_any):
        return f"none of must_include_any tokens present: {must_include_any}", metrics

    must_not_include = [str(token).lower() for token in expectation.get("must_not_include", [])]
    present_forbidden = [token for token in must_not_include if token in lowered]
    if present_forbidden:
        return f"forbidden tokens present: {present_forbidden}", metrics

    forbidden_patterns = [str(pattern) for pattern in expectation.get("forbidden_patterns", [])]
    for pattern in forbidden_patterns:
        if re.search(pattern, normalized, flags=re.IGNORECASE):
            return f"forbidden regex matched: {pattern}", metrics

    reference_text = str(expectation.get("reference_text", "")).strip()
    if reference_text and not (allow_placeholder and is_placeholder_text(normalized)):
        similarity, length_ratio, token_recall = meaning_drift_metrics(reference_text, normalized)
        metrics = {
            "similarity": similarity,
            "length_ratio": length_ratio,
            "token_recall": token_recall,
        }

        min_similarity = float(expectation.get("min_similarity", 0.0))
        min_token_recall = float(expectation.get("min_token_recall", 0.0))
        min_length_ratio = float(expectation.get("length_ratio_min", 0.0))
        max_length_ratio = float(expectation.get("length_ratio_max", 99.0))

        if similarity < min_similarity:
            return f"similarity {similarity:.3f} < {min_similarity:.3f}", metrics
        if token_recall < min_token_recall:
            return f"token recall {token_recall:.3f} < {min_token_recall:.3f}", metrics
        if length_ratio < min_length_ratio or length_ratio > max_length_ratio:
            return (
                f"length ratio {length_ratio:.3f} outside "
                f"[{min_length_ratio:.3f}, {max_length_ratio:.3f}]",
                metrics,
            )

    return None, metrics


def run_stt_checks(manifest: dict[str, Any], clips_root: Path, backends: list[str], iterations: int) -> tuple[list[CheckResult], dict[str, Any]]:
    results: list[CheckResult] = []
    backend_latencies: dict[str, list[float]] = {backend: [] for backend in backends}
    backend_cold_start_counts: dict[str, int] = {backend: 0 for backend in backends}
    backend_meta: dict[str, dict[str, Any]] = {}

    for backend in backends:
        os.environ["VOXFLOW_STT_BACKEND"] = backend
        if backend == "openai" and not server.openai_audio_client.configured:
            backend_meta[backend] = {"status": "skipped", "reason": "OpenAI backend is not configured"}
            continue
        warmup_started = time.perf_counter()
        server.initialize_runtime_state()
        backend_meta[backend] = {
            "status": "ran",
            "warmup_ms": round((time.perf_counter() - warmup_started) * 1000.0, 2),
        }

        for clip in manifest["clips"]:
            clip_id = str(clip["id"])
            clip_path = clips_root / str(clip["file"])
            if not clip_path.exists():
                results.append(CheckResult(id=clip_id, backend=backend, passed=False, details=f"missing clip: {clip_path}"))
                continue

            pcm, sample_rate = decode_audio_file(clip_path)
            expectation = resolve_expectation(clip, backend)

            for run_index in range(iterations):
                request = server.TranscribeRequest(
                    session_id=f"regression-{clip_id}-{uuid.uuid4().hex[:8]}",
                    audio_pcm16le=base64.b64encode(pcm).decode("utf-8"),
                    sample_rate=sample_rate,
                    language_hint=str(clip.get("language_hint", "en")),
                    chunk_index=run_index,
                )
                started = time.perf_counter()
                response = server.transcribe(request)
                elapsed_ms = (time.perf_counter() - started) * 1000.0
                measured_latency = max(float(response.latency_ms), elapsed_ms)
                backend_latencies[backend].append(measured_latency)
                if getattr(response, "cold_start", False):
                    backend_cold_start_counts[backend] += 1

                error, metrics = validate_transcript(response.text, expectation)
                test_id = f"{clip_id}#{run_index + 1}"
                stage_timings = getattr(response, "stage_timings_ms", {}) or {}
                timing_suffix = ""
                if stage_timings:
                    ordered = ", ".join(f"{key}={value}ms" for key, value in sorted(stage_timings.items()))
                    timing_suffix = f"; timings={ordered}"
                if error:
                    details = f"{error}; transcript='{response.text}'{timing_suffix}"
                    results.append(CheckResult(id=test_id, backend=backend, passed=False, details=details))
                else:
                    if metrics:
                        details = (
                            f"ok ({int(measured_latency)}ms, sim={metrics['similarity']:.3f}, "
                            f"recall={metrics['token_recall']:.3f}, ratio={metrics['length_ratio']:.3f}): "
                            f"{response.text}{timing_suffix}"
                        )
                    else:
                        details = f"ok ({int(measured_latency)}ms): {response.text}{timing_suffix}"
                    results.append(CheckResult(id=test_id, backend=backend, passed=True, details=details))

    summary = {"per_backend": {}}
    for backend in backends:
        samples = backend_latencies[backend]
        if not samples:
            summary["per_backend"][backend] = {**backend_meta.get(backend, {}), "sample_count": 0}
            continue
        summary["per_backend"][backend] = {
            **backend_meta.get(backend, {}),
            "sample_count": len(samples),
            "cold_start_sample_count": backend_cold_start_counts[backend],
            "min_ms": round(min(samples), 2),
            "max_ms": round(max(samples), 2),
            "mean_ms": round(statistics.fmean(samples), 2),
            "p50_ms": round(percentile(samples, 50), 2),
            "p90_ms": round(percentile(samples, 90), 2),
            "p95_ms": round(percentile(samples, 95), 2),
        }

    return results, summary


def validate_cleanup_output(case_id: str, mode: str, source: str, output: str, constraints: dict[str, Any]) -> str | None:
    normalized_output = normalize_text(output)
    lowered = normalized_output.lower()

    if not normalized_output:
        return f"{mode} produced empty output"

    must_include_all = [str(token).lower() for token in constraints.get("must_include_all", [])]
    missing = [token for token in must_include_all if token not in lowered]
    if missing:
        return f"{mode} missing tokens: {missing}"

    must_not_include = [str(token).lower() for token in constraints.get("must_not_include", [])]
    present_forbidden = [token for token in must_not_include if token in lowered]
    if present_forbidden:
        return f"{mode} contains forbidden tokens: {present_forbidden}"

    similarity, length_ratio, token_recall = meaning_drift_metrics(source, normalized_output)
    min_similarity = float(constraints.get("min_similarity", 0.0))
    min_token_recall = float(constraints.get("min_token_recall", 0.0))
    min_length_ratio = float(constraints.get("length_ratio_min", 0.0))
    max_length_ratio = float(constraints.get("length_ratio_max", 99.0))

    if similarity < min_similarity:
        return f"{mode} similarity {similarity:.3f} < {min_similarity:.3f}"
    if token_recall < min_token_recall:
        return f"{mode} token recall {token_recall:.3f} < {min_token_recall:.3f}"
    if length_ratio < min_length_ratio or length_ratio > max_length_ratio:
        return f"{mode} length ratio {length_ratio:.3f} outside [{min_length_ratio:.3f}, {max_length_ratio:.3f}]"

    return None


def run_cleanup_checks(manifest: dict[str, Any]) -> list[CheckResult]:
    results: list[CheckResult] = []
    for case in manifest["cleanup_cases"]:
        case_id = str(case["id"])
        source_text = str(case["input"])
        tone = str(case.get("tone", "neutral"))

        for mode in ("light", "polish"):
            constraints = case.get(mode)
            if not isinstance(constraints, dict):
                continue

            request = server.CleanupRequest(
                session_id=f"cleanup-{case_id}-{uuid.uuid4().hex[:8]}",
                mode=mode,
                input_text=source_text,
                tone_style=tone,
                provider_mode="localOnly",
            )
            response = server.cleanup(request)
            error = validate_cleanup_output(case_id, mode, source_text, response.output_text, constraints)
            test_id = f"{case_id}:{mode}"
            if error:
                details = f"{error}; output='{response.output_text}'"
                results.append(CheckResult(id=test_id, backend="cleanup", passed=False, details=details))
            else:
                similarity, length_ratio, token_recall = meaning_drift_metrics(source_text, response.output_text)
                details = (
                    f"ok (sim={similarity:.3f}, ratio={length_ratio:.3f}, "
                    f"token_recall={token_recall:.3f}): {response.output_text}"
                )
                results.append(CheckResult(id=test_id, backend="cleanup", passed=True, details=details))
    return results


def write_report(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run deterministic STT + cleanup regression suite.")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT_DIR / "backend/tests/regression_manifest.json",
        help="Path to regression manifest JSON",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=ROOT_DIR / "backend/tests/reports/stt_latency_report.json",
        help="JSON report output path",
    )
    parser.add_argument(
        "--backends",
        nargs="+",
        default=["whisper", "openai"],
        help="Backends to evaluate in order",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=2,
        help="How many repeated runs per clip/backend",
    )
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    iterations = max(1, int(args.iterations or manifest.get("iterations_per_clip", 2)))
    clip_root = ROOT_DIR

    stt_results, latency_summary = run_stt_checks(
        manifest=manifest,
        clips_root=clip_root,
        backends=[backend.lower() for backend in args.backends],
        iterations=iterations,
    )
    cleanup_results = run_cleanup_checks(manifest=manifest)

    all_results = stt_results + cleanup_results
    failures = [result for result in all_results if not result.passed]
    passed = [result for result in all_results if result.passed]

    print("== VoxFlow Regression Suite ==")
    print(f"passed={len(passed)} failed={len(failures)}")
    print("== Latency Percentiles (ms) ==")
    for backend, summary in latency_summary["per_backend"].items():
        if summary.get("sample_count", 0) == 0:
            reason = summary.get("reason", "no samples")
            print(f"  {backend:7s} skipped ({reason})")
            continue
        print(
            f"  {backend:7s} p50={summary['p50_ms']:>7} "
            f"p90={summary['p90_ms']:>7} p95={summary['p95_ms']:>7} "
            f"n={summary['sample_count']}"
        )

    if failures:
        print("== Failures ==")
        for failure in failures:
            print(f"  [{failure.backend}] {failure.id}: {failure.details}")

    report_payload = {
        "timestamp_epoch": int(time.time()),
        "manifest": str(args.manifest),
        "iterations": iterations,
        "latency_summary": latency_summary,
        "results": [result.__dict__ for result in all_results],
        "failed_count": len(failures),
    }
    write_report(args.report, report_payload)
    print(f"Report written to: {args.report}")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

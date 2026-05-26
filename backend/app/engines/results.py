"""Shared engine result types."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class STTExecutionResult:
    text: str
    confidence: float
    stage_timings_ms: dict[str, int]
    model_loaded_before_request: bool | None = None
    model_loaded_after_request: bool | None = None
    cold_start: bool = False

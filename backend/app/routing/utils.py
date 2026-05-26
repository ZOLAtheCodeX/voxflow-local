"""Routing helpers: input normalisation and structured-output coercion."""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from nlp import normalize_whitespace

logger = logging.getLogger("voxflow")


def normalize_provider_mode(provider_mode: str) -> str:
    normalized = provider_mode.strip().lower()
    if normalized in {"privateapi", "private_api", "private-api"}:
        return "private_api"
    return "local_only"


def normalize_stt_backend(raw: str) -> str:
    normalized = raw.strip().lower()
    if normalized in {"whisper", "whisperkit", "openai"}:
        return normalized
    return "whisper"


def extract_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if not stripped:
        return {}

    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped, flags=re.IGNORECASE)
        stripped = re.sub(r"\s*```$", "", stripped)

    start = stripped.find("{")
    end = stripped.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return {}

    try:
        parsed = json.loads(stripped[start : end + 1])
    except Exception as exc:
        logger.error("Failed to parse JSON object: %s", exc)
        return {}

    return parsed if isinstance(parsed, dict) else {}


def coerce_string_list(value: Any, limit: int) -> list[str]:
    if isinstance(value, list):
        items = value
    elif value is None:
        items = []
    else:
        items = [value]
    return [normalize_whitespace(str(item)) for item in items if str(item).strip()][:limit]


def is_placeholder_text(text: str) -> bool:
    lowered = text.lower()
    return lowered.startswith("[translation unavailable") or lowered.startswith("[transcription unavailable")

from __future__ import annotations

import math
import re
from difflib import SequenceMatcher


PLACEHOLDER_PREFIXES = (
    "[transcription unavailable",
    "[translation unavailable",
)


def normalize_text(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", normalize_text(text).lower())


def word_count(text: str) -> int:
    return len(tokenize(text))


def is_placeholder_text(text: str) -> bool:
    lowered = normalize_text(text).lower()
    return any(lowered.startswith(prefix) for prefix in PLACEHOLDER_PREFIXES)


def meaning_drift_metrics(original: str, candidate: str) -> tuple[float, float, float]:
    original_norm = normalize_text(original)
    candidate_norm = normalize_text(candidate)

    similarity = SequenceMatcher(None, original_norm.lower(), candidate_norm.lower()).ratio()
    original_words = max(1, word_count(original_norm))
    candidate_words = word_count(candidate_norm)
    length_ratio = candidate_words / float(original_words)

    original_tokens = {token for token in tokenize(original_norm) if len(token) >= 3}
    if not original_tokens:
        token_recall = 1.0
    else:
        candidate_tokens = set(tokenize(candidate_norm))
        token_recall = len(original_tokens & candidate_tokens) / float(len(original_tokens))

    return similarity, length_ratio, token_recall


def percentile(values: list[float], p: float) -> float:
    if not values:
        raise ValueError("Cannot compute percentile of empty list")
    if p < 0 or p > 100:
        raise ValueError("Percentile must be in [0, 100]")

    sorted_values = sorted(values)
    if len(sorted_values) == 1:
        return float(sorted_values[0])

    index = (len(sorted_values) - 1) * (p / 100.0)
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return float(sorted_values[lower])

    lower_value = sorted_values[lower]
    upper_value = sorted_values[upper]
    fraction = index - lower
    return float(lower_value + (upper_value - lower_value) * fraction)

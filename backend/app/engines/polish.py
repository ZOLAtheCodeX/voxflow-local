"""PolishEngine — FLAN-T5-Small based text polish + tone application.

Uses HuggingFace text2text-generation pipeline. On any failure or guardrail
trigger, falls back to apply_tone(light_cleanup(text), tone) — the regex
floor — so callers always get usable output.

The guardrail catches model echoes, length explosions, and low-similarity
outputs that would be worse than a clean light_cleanup result.
"""

from __future__ import annotations

import logging
import os
import re
from difflib import SequenceMatcher
from threading import Lock

from nlp import apply_tone, light_cleanup

from ._utils import preferred_torch_device, resolve_model_ref

logger = logging.getLogger("voxflow")


class PolishEngine:
    _TONE_INSTRUCTIONS = {
        "concise": "Remove unnecessary words. Be direct and brief.",
        "formal": "Use professional language. Avoid contractions and slang.",
        "friendly": "Use warm, approachable language.",
        "neutral": "Use clear, natural language.",
    }

    def __init__(self) -> None:
        model_ref = os.environ.get("VOXFLOW_POLISH_MODEL", "google/flan-t5-small")
        self.model_id = resolve_model_ref(model_ref)
        self._pipeline = None
        self._load_failed = False
        self._lock = Lock()

    def _load_pipeline(self) -> None:
        if self._pipeline is not None:
            return
        if self._load_failed:
            return

        with self._lock:
            if self._pipeline is not None:
                return
            if self._load_failed:
                return
            try:
                from transformers import pipeline

                self._pipeline = pipeline(
                    task="text2text-generation",
                    model=self.model_id,
                    device=preferred_torch_device(),
                )
                logger.info("Loaded polish model: %s", self.model_id)
            except Exception as exc:
                logger.error("Failed to load polish model %s: %s", self.model_id, exc)
                self._load_failed = True

    def retry_load(self) -> None:
        """Reset failure state to allow retrying model load."""
        self._load_failed = False
        self._load_pipeline()

    def polish(self, text: str, tone: str) -> tuple[str, bool]:
        self._load_pipeline()

        if not text.strip():
            return "", False

        if self._pipeline:
            tone_instruction = self._TONE_INSTRUCTIONS.get(tone.lower(), self._TONE_INSTRUCTIONS["neutral"])
            prompt = (
                f"Rewrite this spoken transcript as clean written text. "
                f"Do not add new information. {tone_instruction} "
                f"Transcript: {text}"
            )
            word_count = len(text.split())
            max_tokens = min(200, max(60, word_count * 3))
            try:
                result = self._pipeline(prompt, max_new_tokens=max_tokens)[0]["generated_text"].strip()
                if self._guardrail_triggered(text, result):
                    return apply_tone(light_cleanup(text), tone), True
                if self._is_echo(text, result):
                    return apply_tone(light_cleanup(text), tone), False
                return result, False
            except Exception as exc:
                logger.error("Polish inference failed: %s", exc)

        return apply_tone(light_cleanup(text), tone), False

    @staticmethod
    def _is_echo(original: str, candidate: str) -> bool:
        """Check if the model just echoed the input back (possibly with minor punctuation changes)."""
        def _normalize(s: str) -> str:
            return re.sub(r"[^\w\s]", "", s.strip().lower())
        return _normalize(original) == _normalize(candidate)

    @staticmethod
    def _guardrail_triggered(original: str, candidate: str) -> bool:
        if not candidate.strip():
            return True

        similarity = SequenceMatcher(None, original.lower(), candidate.lower()).ratio()
        if similarity < 0.55:
            return True

        original_length = max(1, len(original.split()))
        candidate_length = len(candidate.split())
        length_ratio = candidate_length / original_length

        if original_length <= 5:
            return False

        max_ratio = 2.5 if original_length <= 10 else 1.8
        return length_ratio < 0.6 or length_ratio > max_ratio

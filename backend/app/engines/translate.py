"""TranslateEngine — EN→DE translation.

Auto-detects the backend (TranslateGemma chat-template path vs Marian
seq2seq path) based on the configured model id, or honours an explicit
VOXFLOW_TRANSLATE_BACKEND env var.

Returns a sentinel string when the model is unavailable so the caller can
surface a graceful failure rather than crashing.
"""

from __future__ import annotations

import logging
import os
from threading import Lock
from typing import Any

from ._utils import preferred_torch_device, resolve_model_ref

logger = logging.getLogger("voxflow")


class TranslateEngine:
    def __init__(self) -> None:
        model_ref = os.environ.get("VOXFLOW_TRANSLATE_MODEL", "google/translategemma-4b-it")
        self.model_id = resolve_model_ref(model_ref)
        configured_backend = os.environ.get("VOXFLOW_TRANSLATE_BACKEND", "auto").lower()
        self.backend = self._resolve_backend(configured_backend, self.model_id)
        self._pipeline = None
        self._load_failed = False
        self._lock = Lock()

    @staticmethod
    def _resolve_backend(configured_backend: str, model_id: str) -> str:
        if configured_backend in {"translategemma", "marian"}:
            return configured_backend

        return "translategemma" if "translategemma" in model_id.lower() else "marian"

    def _load_pipeline(self) -> None:
        if self._pipeline is not None or self._load_failed:
            return

        with self._lock:
            if self._pipeline is not None or self._load_failed:
                return
            try:
                from transformers import pipeline

                if self.backend == "translategemma":
                    self._pipeline = pipeline(
                        task="image-text-to-text",
                        model=self.model_id,
                        device=preferred_torch_device(),
                        torch_dtype="auto",
                    )
                else:
                    self._pipeline = pipeline(task="translation", model=self.model_id, device=preferred_torch_device())
                logger.info("Loaded translate model: %s (backend=%s)", self.model_id, self.backend)
            except Exception as exc:
                logger.error("Failed to load translate model %s: %s", self.model_id, exc)
                self._load_failed = True

    def translate(self, text: str) -> str:
        self._load_pipeline()
        if self._pipeline:
            try:
                if self.backend == "translategemma":
                    messages = [
                        {
                            "role": "user",
                            "content": [
                                {
                                    "type": "text",
                                    "source_lang_code": "en",
                                    "target_lang_code": "de-DE",
                                    "text": text,
                                }
                            ],
                        }
                    ]
                    result = self._pipeline(text=messages, max_new_tokens=220, do_sample=False)
                    translated = self._extract_translategemma_output(result)
                    return translated or "[translation unavailable: malformed TranslateGemma output]"

                result = self._pipeline(text)
                return str(result[0]["translation_text"]).strip()
            except Exception as exc:
                logger.error("Translation inference failed: %s", exc)

        return "[translation unavailable: local EN→DE model not loaded]"

    @staticmethod
    def _extract_translategemma_output(result: list[dict[str, Any]]) -> str:
        if not result:
            return ""

        generated = result[0].get("generated_text")
        if isinstance(generated, list) and generated:
            last_message = generated[-1]
            if isinstance(last_message, dict):
                content = last_message.get("content")
                return str(content).strip() if content is not None else ""

        if isinstance(generated, str):
            return generated.strip()

        return ""

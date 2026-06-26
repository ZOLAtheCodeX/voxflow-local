"""PrivateAPIClient — talks to the configured private chat-completions API.

Provides cleanup / translate_en_de / meeting_summary methods with the same
shape as the local engines, so ProviderRouter can swap them transparently
when the user opts into 'private API' provider mode.

All cleanup/translate calls are gated by consent in ProviderRouter — this
module just executes the HTTP call.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Any
from urllib import parse as urlparse

from fastapi import HTTPException

from engines import PolishEngine
from nlp import (
    apply_tone,
    coerce_speaker_segments,
    coerce_task_owners,
    light_cleanup,
    normalize_whitespace,
    render_meeting_markdown_export,
    render_meeting_notion_export,
)

from .utils import coerce_string_list, extract_json_object

logger = logging.getLogger("voxflow")


@dataclass
class PrivateAPIPolicy:
    version: str
    require_consent: bool
    require_raw_confirmation: bool


class PrivateAPIClient:
    def __init__(self) -> None:
        self.base_url = os.environ.get("VOXFLOW_PRIVATE_API_BASE_URL", "").strip()
        self.model = os.environ.get("VOXFLOW_PRIVATE_API_MODEL", "gpt-4o-mini").strip() or "gpt-4o-mini"
        self.api_key = os.environ.get("VOXFLOW_PRIVATE_API_KEY", "").strip()

    @property
    def configured(self) -> bool:
        return bool(self.base_url and self.model and self.api_key)

    def _endpoint(self, path: str) -> str:
        base = self.base_url.rstrip("/")
        normalized_path = path.lstrip("/")
        if base.lower().endswith("/v1") and normalized_path.lower().startswith("v1/"):
            normalized_path = normalized_path[3:]
        return urlparse.urljoin(f"{base}/", normalized_path)

    def _chat_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 260) -> str:
        if not self.configured:
            raise HTTPException(status_code=503, detail="Private API not configured")

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.2,
            "max_tokens": max_tokens,
        }

        import concurrent.futures
        import httpx

        url = self._endpoint("/v1/chat/completions")
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
        }

        def do_request() -> str:
            with httpx.Client(timeout=20.0) as client:
                response = client.post(url, json=payload, headers=headers)
                response.raise_for_status()
                return response.text

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(do_request)
            try:
                response_body = future.result(timeout=20.0)
            except concurrent.futures.TimeoutError as exc:
                raise HTTPException(status_code=502, detail="Private API request timed out") from exc
            except httpx.HTTPStatusError as exc:
                detail = exc.response.text
                raise HTTPException(status_code=502, detail=f"Private API HTTP error: {detail[:160]}") from exc
            except Exception as exc:
                raise HTTPException(status_code=502, detail=f"Private API request failed: {exc}") from exc

        try:
            parsed = json.loads(response_body)
            choices = parsed.get("choices", [])
            if not choices:
                raise ValueError("empty choices")
            message = choices[0].get("message", {})
            content = message.get("content", "")
            if isinstance(content, list):
                joined = []
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "text":
                        joined.append(str(item.get("text", "")))
                    elif isinstance(item, str):
                        joined.append(item)
                return normalize_whitespace(" ".join(joined))
            return normalize_whitespace(str(content))
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Private API response parse failure: {exc}") from exc

    def cleanup(self, mode: str, tone: str, text: str) -> tuple[str, bool]:
        if mode == "raw":
            return normalize_whitespace(text), False

        system_prompt = (
            "You transform dictated text. Preserve meaning, proper nouns, dates, and numbers. "
            "Return only final text."
        )

        if mode == "light":
            user_prompt = (
                f"Apply light cleanup with tone '{tone}'. "
                "Fix punctuation/casing and remove obvious filler words conservatively.\n\n"
                f"Text:\n{text}"
            )
            return self._chat_completion(system_prompt, user_prompt, max_tokens=220), False

        if mode == "polish":
            user_prompt = (
                f"Apply polish cleanup with tone '{tone}'. "
                "Improve readability and fluency while preserving meaning exactly.\n\n"
                f"Text:\n{text}"
            )
            candidate = self._chat_completion(system_prompt, user_prompt, max_tokens=280)
            if PolishEngine._guardrail_triggered(text, candidate, tone):
                return apply_tone(light_cleanup(text), tone), True
            return candidate, False

        raise HTTPException(status_code=400, detail=f"Unsupported cleanup mode: {mode}")

    def translate_en_de(self, text: str) -> str:
        system_prompt = "Translate English to German accurately. Return only German text."
        user_prompt = f"Translate this to German:\n{text}"
        translated = self._chat_completion(system_prompt, user_prompt, max_tokens=260)
        return translated or "[translation unavailable: private API returned empty text]"

    def meeting_summary(self, transcript: str, tone: str) -> dict[str, Any]:
        system_prompt = (
            "You summarize meeting transcripts into structured JSON. "
            "Return JSON only with keys: summary, decisions, action_items, follow_ups, speaker_segments, task_owners."
        )
        user_prompt = (
            f"Tone: {tone}\n"
            "Transcript:\n"
            f"{transcript}\n\n"
            "JSON schema:\n"
            "{"
            '"summary":"string",'
            '"decisions":["string"],'
            '"action_items":["string"],'
            '"follow_ups":["string"],'
            '"speaker_segments":[{"speaker":"string","text":"string","utterance_count":1}],'
            '"task_owners":[{"task":"string","owner":"string","confidence":0.0}]'
            "}"
        )
        content = self._chat_completion(system_prompt, user_prompt, max_tokens=420)
        parsed = extract_json_object(content)

        decisions = coerce_string_list(parsed.get("decisions"), 5)
        action_items = coerce_string_list(parsed.get("action_items"), 6)
        follow_ups = coerce_string_list(parsed.get("follow_ups"), 4)
        speaker_segments = coerce_speaker_segments(parsed.get("speaker_segments"), transcript)
        task_owners = coerce_task_owners(parsed.get("task_owners"), action_items, transcript, speaker_segments)

        markdown_export = render_meeting_markdown_export(
            summary=normalize_whitespace(str(parsed.get("summary", ""))),
            decisions=decisions,
            action_items=action_items,
            follow_ups=follow_ups,
            speaker_segments=speaker_segments,
            task_owners=task_owners,
        )
        notion_export = render_meeting_notion_export(
            summary=normalize_whitespace(str(parsed.get("summary", ""))),
            decisions=decisions,
            action_items=action_items,
            follow_ups=follow_ups,
            speaker_segments=speaker_segments,
            task_owners=task_owners,
        )

        return {
            "summary": normalize_whitespace(str(parsed.get("summary", ""))),
            "decisions": decisions,
            "action_items": action_items,
            "follow_ups": follow_ups,
            "speaker_segments": speaker_segments,
            "task_owners": task_owners,
            "markdown_export": markdown_export,
            "notion_export": notion_export,
        }

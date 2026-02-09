from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

from fastapi import HTTPException

ROOT_DIR = Path(__file__).resolve().parents[2]
BACKEND_APP_DIR = ROOT_DIR / "backend" / "app"
if str(BACKEND_APP_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_APP_DIR))

import server


class PrivacyTokenFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        self._env_keys = [
            "VOXFLOW_PRIVACY_POLICY_VERSION",
            "VOXFLOW_PRIVACY_REQUIRE_CONSENT",
            "VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED",
        ]
        self._env_backup = {key: os.environ.get(key) for key in self._env_keys}
        os.environ["VOXFLOW_PRIVACY_POLICY_VERSION"] = "test-2026-02"
        os.environ["VOXFLOW_PRIVACY_REQUIRE_CONSENT"] = "1"
        os.environ["VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED"] = "1"

        self._private_api_backup = (
            server.private_api_client.base_url,
            server.private_api_client.model,
            server.private_api_client.api_key,
        )
        server.private_api_client.base_url = "https://example.invalid"
        server.private_api_client.model = "test-model"
        server.private_api_client.api_key = "test-key"

        self._cleanup_backup = server.private_api_client.cleanup
        self._translate_backup = server.private_api_client.translate_en_de
        self._meeting_backup = server.private_api_client.meeting_summary
        self._audit_backup = server.audit_logger.log

        server.private_api_client.cleanup = lambda mode, tone, text: (f"{mode}:{tone}:{text}", False)
        server.private_api_client.translate_en_de = lambda text: f"DE:{text}"
        server.private_api_client.meeting_summary = lambda transcript, tone: {
            "summary": f"Summary {tone}: {transcript}",
            "decisions": [f"Decision: {transcript}"],
            "action_items": ["Action: owner follows up"],
            "follow_ups": ["Follow up: tomorrow"],
        }
        server.audit_logger.log = lambda **_: None

        with server.consent_store._lock:  # noqa: SLF001 - test-only internal reset
            server.consent_store._records.clear()  # noqa: SLF001 - test-only internal reset

    def tearDown(self) -> None:
        for key, value in self._env_backup.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

        (
            server.private_api_client.base_url,
            server.private_api_client.model,
            server.private_api_client.api_key,
        ) = self._private_api_backup
        server.private_api_client.cleanup = self._cleanup_backup
        server.private_api_client.translate_en_de = self._translate_backup
        server.private_api_client.meeting_summary = self._meeting_backup
        server.audit_logger.log = self._audit_backup

    def _preview(self, operation: str, text: str, session_id: str = "session-privacy") -> server.PrivacyPreviewResponse:
        request = server.PrivacyPreviewRequest(
            session_id=session_id,
            operation=operation,
            input_text=text,
        )
        return server.privacy_preview(request)

    def test_cleanup_preview_then_approve_redacted(self) -> None:
        preview = self._preview(
            operation="cleanup",
            text="Email me at alice@example.com or call 415-555-1212",
        )
        self.assertIn("[EMAIL]", preview.redacted_text)
        self.assertIn("[PHONE]", preview.redacted_text)

        response = server.cleanup(
            server.CleanupRequest(
                session_id="session-privacy",
                mode="light",
                input_text=preview.original_text,
                tone_style="neutral",
                provider_mode="privateAPI",
                consent_token=preview.token,
                allow_raw=False,
            )
        )
        self.assertIn("[EMAIL]", response.output_text)
        self.assertNotIn("alice@example.com", response.output_text)

    def test_cleanup_preview_then_approve_raw(self) -> None:
        preview = self._preview(
            operation="cleanup",
            text="Contact bob@example.com right now",
        )
        response = server.cleanup(
            server.CleanupRequest(
                session_id="session-privacy",
                mode="polish",
                input_text=preview.original_text,
                tone_style="formal",
                provider_mode="privateAPI",
                consent_token=preview.token,
                allow_raw=True,
            )
        )
        self.assertIn("bob@example.com", response.output_text)

    def test_translate_and_meeting_use_preview_token(self) -> None:
        translate_preview = self._preview(
            operation="translate",
            text="Please email me at owner@example.com with status.",
            session_id="session-translate",
        )
        translate_response = server.translate(
            server.TranslateRequest(
                session_id="session-translate",
                source_text=translate_preview.original_text,
                source_language="en",
                target_language="de",
                provider_mode="privateAPI",
                consent_token=translate_preview.token,
                allow_raw=False,
            )
        )
        self.assertTrue(translate_response.translated_text.startswith("DE:"))
        self.assertIn("[EMAIL]", translate_response.source_text)

        meeting_preview = self._preview(
            operation="meeting",
            text="We agreed to follow up with client@example.com tomorrow.",
            session_id="session-meeting",
        )
        meeting_response = server.meeting_summarize(
            server.MeetingRequest(
                session_id="session-meeting",
                transcript=meeting_preview.original_text,
                tone_style="neutral",
                provider_mode="privateAPI",
                consent_token=meeting_preview.token,
                allow_raw=False,
            )
        )
        self.assertIn("[EMAIL]", meeting_response.transcript)
        self.assertTrue(any("Action" in item for item in meeting_response.action_items))

    def test_private_api_rejects_invalid_or_missing_token(self) -> None:
        with self.assertRaises(HTTPException) as invalid_ctx:
            server.cleanup(
                server.CleanupRequest(
                    session_id="missing-token-session",
                    mode="light",
                    input_text="text",
                    tone_style="neutral",
                    provider_mode="privateAPI",
                    consent_token="invalid-token",
                    allow_raw=False,
                )
            )
        self.assertEqual(invalid_ctx.exception.status_code, 400)
        self.assertIn("Invalid or expired", invalid_ctx.exception.detail)

        with self.assertRaises(HTTPException) as missing_ctx:
            server.translate(
                server.TranslateRequest(
                    session_id="missing-token-session",
                    source_text="hello world",
                    source_language="en",
                    target_language="de",
                    provider_mode="privateAPI",
                    consent_token=None,
                    allow_raw=False,
                )
            )
        self.assertEqual(missing_ctx.exception.status_code, 400)
        self.assertIn("consent_token", missing_ctx.exception.detail)

    def test_private_api_fail_closed_when_policy_flags_missing(self) -> None:
        os.environ.pop("VOXFLOW_PRIVACY_POLICY_VERSION", None)
        with self.assertRaises(HTTPException) as ctx:
            self._preview(operation="cleanup", text="test")
        self.assertEqual(ctx.exception.status_code, 503)
        self.assertIn("flags missing", ctx.exception.detail)


if __name__ == "__main__":
    unittest.main()

"""Unit tests for meeting analysis functions in server.py."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import (
    build_meeting_summary,
    infer_speaker_segments,
    infer_task_owners,
    render_meeting_markdown_export,
    render_meeting_notion_export,
)


# ── infer_speaker_segments ───────────────────────────────────────────

class TestInferSpeakerSegments:
    def test_named_speakers(self):
        transcript = "Alice: We should start.\nBob: I agree.\nAlice: Let's go."
        result = infer_speaker_segments(transcript)
        speakers = {s["speaker"] for s in result}
        assert "Alice" in speakers
        assert "Bob" in speakers

    def test_speaker_n_format(self):
        transcript = "Speaker 1: Hello everyone.\nSpeaker 2: Welcome."
        result = infer_speaker_segments(transcript)
        speakers = {s["speaker"] for s in result}
        assert "Speaker 1" in speakers
        assert "Speaker 2" in speakers

    def test_no_speakers_fallback(self):
        transcript = "Just a plain transcript with no speaker labels at all."
        result = infer_speaker_segments(transcript)
        assert len(result) == 1
        assert result[0]["speaker"] == "Speaker 1"
        assert result[0]["utterance_count"] == 1

    def test_empty_transcript(self):
        assert infer_speaker_segments("") == []
        assert infer_speaker_segments("   ") == []

    def test_fallback_truncates_long_text(self):
        long_text = "A " * 200  # 400 chars
        result = infer_speaker_segments(long_text)
        assert len(result[0]["text"]) <= 220

    def test_utterance_count_accumulates(self):
        transcript = "Alice: First.\nAlice: Second.\nAlice: Third."
        result = infer_speaker_segments(transcript)
        alice = [s for s in result if s["speaker"] == "Alice"][0]
        assert alice["utterance_count"] == 3

    def test_max_six_speakers(self):
        lines = [f"Speaker{i}: Hello from speaker {i}." for i in range(10)]
        transcript = "\n".join(lines)
        result = infer_speaker_segments(transcript)
        assert len(result) <= 6


# ── infer_task_owners ────────────────────────────────────────────────

class TestInferTaskOwners:
    def test_lead_match_high_confidence(self):
        items = ["Alice will finalize the report"]
        result = infer_task_owners(items, "Alice: I'll handle it.\nBob: Thanks.")
        assert result[0]["owner"] == "Alice"
        assert result[0]["confidence"] == 0.92

    def test_any_match_medium_confidence(self):
        items = ["The task is something Bob should review"]
        result = infer_task_owners(items, "Bob: ok.\nAlice: noted.")
        assert result[0]["owner"] == "Bob"
        assert result[0]["confidence"] == 0.78

    def test_known_speaker_fallback(self):
        items = ["Update the documentation"]
        result = infer_task_owners(items, "Alice: Let me check.\nBob: Sure.")
        # No "Name will/to/should" pattern → falls back to first known speaker
        assert result[0]["confidence"] == 0.45

    def test_fallback_speaker_when_no_named_speakers(self):
        # Even without named speakers, infer_speaker_segments returns a "Speaker 1"
        # fallback, so known_speakers is never empty. The owner becomes that fallback.
        items = ["Update the documentation"]
        result = infer_task_owners(items, "Just a plain transcript.")
        assert result[0]["owner"] == "Speaker 1"
        assert result[0]["confidence"] == 0.45

    def test_empty_items(self):
        assert infer_task_owners([], "Some transcript") == []

    def test_max_ten_items(self):
        items = [f"Task {i}" for i in range(15)]
        result = infer_task_owners(items, "")
        assert len(result) == 10


# ── build_meeting_summary ────────────────────────────────────────────

class TestBuildMeetingSummary:
    def test_basic_transcript(self):
        transcript = "We decided to ship v2. Alice will write the docs. Follow up next week."
        result = build_meeting_summary(transcript, "neutral")
        assert result["summary"]
        assert isinstance(result["decisions"], list)
        assert isinstance(result["action_items"], list)
        assert isinstance(result["follow_ups"], list)
        assert result["markdown_export"]
        assert result["notion_export"]

    def test_empty_transcript(self):
        result = build_meeting_summary("", "neutral")
        assert result["summary"] == ""
        assert result["decisions"] == []
        assert result["action_items"] == []
        assert result["follow_ups"] == []

    def test_decisions_detected_by_keyword(self):
        transcript = "We agreed on the plan. The budget was approved. Next steps follow."
        result = build_meeting_summary(transcript, "neutral")
        # "agreed" and "approved" are decision keywords
        assert len(result["decisions"]) >= 2

    def test_action_items_detected(self):
        transcript = "Alice will review the code. We need to update the docs."
        result = build_meeting_summary(transcript, "neutral")
        assert len(result["action_items"]) >= 1


# ── render_meeting_markdown_export ───────────────────────────────────

class TestRenderMeetingMarkdown:
    def test_structure(self):
        md = render_meeting_markdown_export(
            summary="Test summary",
            decisions=["Decision 1"],
            action_items=["Action 1"],
            follow_ups=["Follow up 1"],
            speaker_segments=[{"speaker": "Alice", "text": "Hello", "utterance_count": 1}],
            task_owners=[{"task": "Do thing", "owner": "Bob", "confidence": 0.9}],
        )
        assert "# Meeting Notes" in md
        assert "## Summary" in md
        assert "## Decisions" in md
        assert "## Action Items" in md
        assert "- [ ] Action 1" in md
        assert "## Task Owners" in md
        assert "Bob" in md
        assert "**Alice**" in md

    def test_empty_sections_show_none_captured(self):
        md = render_meeting_markdown_export(
            summary="Summary",
            decisions=[],
            action_items=[],
            follow_ups=[],
            speaker_segments=[],
            task_owners=[],
        )
        assert "None captured" in md
        assert "None inferred" in md


# ── render_meeting_notion_export ─────────────────────────────────────

class TestRenderMeetingNotion:
    def test_checkbox_format(self):
        notion = render_meeting_notion_export(
            summary="Test summary",
            decisions=["Decision 1"],
            action_items=["Action 1"],
            follow_ups=["Follow up 1"],
            speaker_segments=[{"speaker": "Alice", "text": "Hello", "utterance_count": 1}],
            task_owners=[{"task": "Do thing", "owner": "Bob", "confidence": 0.9}],
        )
        assert "# Meeting Summary" in notion
        assert "- [ ]" in notion
        assert "Owner: Bob" in notion

    def test_no_task_owners_uses_action_items(self):
        notion = render_meeting_notion_export(
            summary="Summary",
            decisions=[],
            action_items=["Review code"],
            follow_ups=[],
            speaker_segments=[],
            task_owners=[],
        )
        assert "- [ ] Review code" in notion

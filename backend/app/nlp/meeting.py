"""Meeting analysis helpers — speaker inference, task owners, structured
summaries, markdown/Notion export.

All pure-Python regex + keyword heuristics. No ML calls.
"""

from __future__ import annotations

import logging
from typing import Any

from text_cleanup_rules import (
    NAME_ANY_PATTERN,
    NAME_LEAD_PATTERN,
    SPEAKER_PATTERN,
)

from .cleanup import normalize_whitespace
from .sentences import split_sentences
from .tone import apply_tone

logger = logging.getLogger("voxflow")


def infer_speaker_segments(transcript: str) -> list[dict[str, Any]]:
    normalized = transcript.strip()
    if not normalized:
        return []

    segments: list[dict[str, Any]] = []
    by_speaker: dict[str, list[str]] = {}

    for line in transcript.splitlines():
        line = line.strip()
        if not line:
            continue
        match = SPEAKER_PATTERN.match(line)
        if not match:
            continue
        speaker = normalize_whitespace(match.group("speaker"))
        utterance = normalize_whitespace(match.group("text"))
        if not utterance:
            continue
        by_speaker.setdefault(speaker, []).append(utterance)

    if by_speaker:
        for speaker, utterances in by_speaker.items():
            segments.append(
                {
                    "speaker": speaker,
                    "text": " ".join(utterances[:2]),
                    "utterance_count": len(utterances),
                }
            )
        return segments[:6]

    fallback_excerpt = normalize_whitespace(transcript)
    if len(fallback_excerpt) > 220:
        fallback_excerpt = f"{fallback_excerpt[:217]}..."
    return [{"speaker": "Speaker 1", "text": fallback_excerpt, "utterance_count": 1}]


def infer_task_owners(
    action_items: list[str],
    transcript: str,
    speaker_segments: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    if not action_items:
        return []

    results: list[dict[str, Any]] = []

    segments = speaker_segments if speaker_segments is not None else infer_speaker_segments(transcript)
    known_speakers = {segment["speaker"] for segment in segments if segment.get("speaker")}

    for item in action_items[:10]:
        cleaned_item = normalize_whitespace(item)
        owner = "Unassigned"
        confidence = 0.35

        lead_match = NAME_LEAD_PATTERN.search(cleaned_item)
        if lead_match:
            owner = normalize_whitespace(lead_match.group("owner"))
            confidence = 0.92
        else:
            any_match = NAME_ANY_PATTERN.search(cleaned_item)
            if any_match:
                owner = normalize_whitespace(any_match.group("owner"))
                confidence = 0.78

        results.append(
            {
                "task": cleaned_item,
                "owner": owner,
                "confidence": round(confidence, 2),
            }
        )

    return results


def coerce_speaker_segments(value: Any, transcript: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return infer_speaker_segments(transcript)

    rows: list[dict[str, Any]] = []
    for entry in value[:6]:
        if not isinstance(entry, dict):
            continue
        speaker = normalize_whitespace(str(entry.get("speaker", "Speaker 1")))
        text = normalize_whitespace(str(entry.get("text", "")))
        if not text:
            continue
        try:
            utterance_count = max(1, int(entry.get("utterance_count", 1)))
        except Exception as exc:
            logger.error("Failed to coerce utterance_count: %s", exc)
            utterance_count = 1
        rows.append({"speaker": speaker, "text": text, "utterance_count": utterance_count})

    return rows or infer_speaker_segments(transcript)


def coerce_task_owners(
    value: Any,
    action_items: list[str],
    transcript: str,
    speaker_segments: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return infer_task_owners(action_items, transcript, speaker_segments)

    rows: list[dict[str, Any]] = []
    for entry in value[:10]:
        if not isinstance(entry, dict):
            continue
        task = normalize_whitespace(str(entry.get("task", "")))
        owner = normalize_whitespace(str(entry.get("owner", "Unassigned")))
        if not task:
            continue
        try:
            confidence = float(entry.get("confidence", 0.5))
        except Exception as exc:
            logger.error("Failed to coerce confidence: %s", exc)
            confidence = 0.5
        confidence = max(0.0, min(1.0, confidence))
        rows.append({"task": task, "owner": owner or "Unassigned", "confidence": round(confidence, 2)})

    return rows or infer_task_owners(action_items, transcript, speaker_segments)


def render_meeting_markdown_export(
    *,
    summary: str,
    decisions: list[str],
    action_items: list[str],
    follow_ups: list[str],
    speaker_segments: list[dict[str, Any]],
    task_owners: list[dict[str, Any]],
) -> str:
    lines: list[str] = []
    lines.append("# Meeting Notes")
    lines.append("")
    lines.append("## Summary")
    lines.append(summary or "No summary captured.")
    lines.append("")
    lines.append("## Decisions")
    lines.extend(decisions and [f"- {item}" for item in decisions] or ["- None captured"])
    lines.append("")
    lines.append("## Action Items")
    lines.extend(action_items and [f"- [ ] {item}" for item in action_items] or ["- [ ] None captured"])
    lines.append("")
    lines.append("## Follow Ups")
    lines.extend(follow_ups and [f"- {item}" for item in follow_ups] or ["- None captured"])
    lines.append("")
    lines.append("## Task Owners")
    if task_owners:
        lines.extend(
            [
                f"- {row.get('task', 'Unknown task')} — {row.get('owner', 'Unassigned')} "
                f"({float(row.get('confidence', 0.0)):.2f})"
                for row in task_owners
            ]
        )
    else:
        lines.append("- None inferred")
    lines.append("")
    lines.append("## Speaker Segments")
    if speaker_segments:
        lines.extend(
            [
                f"- **{row.get('speaker', 'Speaker')}** ({int(row.get('utterance_count', 1))}): "
                f"{row.get('text', '')}"
                for row in speaker_segments
            ]
        )
    else:
        lines.append("- None inferred")
    return "\n".join(lines).strip()


def render_meeting_notion_export(
    *,
    summary: str,
    decisions: list[str],
    action_items: list[str],
    follow_ups: list[str],
    speaker_segments: list[dict[str, Any]],
    task_owners: list[dict[str, Any]],
) -> str:
    lines: list[str] = []
    lines.append("# Meeting Summary")
    lines.append(summary or "No summary captured.")
    lines.append("")
    lines.append("## Decisions")
    lines.extend(decisions and [f"- {item}" for item in decisions] or ["- None captured"])
    lines.append("")
    lines.append("## Action Items")
    if task_owners:
        lines.extend([f"- [ ] {row.get('task', 'Unknown task')} (Owner: {row.get('owner', 'Unassigned')})" for row in task_owners])
    else:
        lines.extend(action_items and [f"- [ ] {item}" for item in action_items] or ["- [ ] None captured"])
    lines.append("")
    lines.append("## Follow Ups")
    lines.extend(follow_ups and [f"- {item}" for item in follow_ups] or ["- None captured"])
    lines.append("")
    lines.append("## Speakers")
    lines.extend(
        speaker_segments and [f"- {row.get('speaker', 'Speaker')}: {row.get('text', '')}" for row in speaker_segments] or ["- Speaker segments unavailable"]
    )
    return "\n".join(lines).strip()


def build_meeting_summary(transcript: str, tone: str) -> dict[str, Any]:
    sentences = split_sentences(transcript)
    if not sentences:
        return {
            "summary": "",
            "decisions": [],
            "action_items": [],
            "follow_ups": [],
            "speaker_segments": [],
            "task_owners": [],
            "markdown_export": "",
            "notion_export": "",
        }

    summary_base = " ".join(sentences[:2])
    summary = apply_tone(summary_base, tone)

    decision_keywords = ("decide", "decision", "approved", "agree", "agreed", "resolved")
    action_keywords = ("will", "need to", "todo", "action", "follow up", "by ", "next step")
    followup_keywords = ("follow up", "next", "later", "tomorrow", "by ")

    decisions = [s for s in sentences if any(keyword in s.lower() for keyword in decision_keywords)]
    action_items = [s for s in sentences if any(keyword in s.lower() for keyword in action_keywords)]
    follow_ups = [s for s in sentences if any(keyword in s.lower() for keyword in followup_keywords)]

    if not decisions and len(sentences) >= 2:
        decisions = [sentences[1]]
    if not action_items and sentences:
        action_items = [sentences[-1]]
    if not follow_ups and action_items:
        follow_ups = action_items[:1]

    speaker_segments = infer_speaker_segments(transcript)
    task_owners = infer_task_owners(action_items, transcript, speaker_segments)
    markdown_export = render_meeting_markdown_export(
        summary=summary,
        decisions=decisions[:5],
        action_items=action_items[:6],
        follow_ups=follow_ups[:4],
        speaker_segments=speaker_segments,
        task_owners=task_owners,
    )
    notion_export = render_meeting_notion_export(
        summary=summary,
        decisions=decisions[:5],
        action_items=action_items[:6],
        follow_ups=follow_ups[:4],
        speaker_segments=speaker_segments,
        task_owners=task_owners,
    )

    return {
        "summary": summary,
        "decisions": decisions[:5],
        "action_items": action_items[:6],
        "follow_ups": follow_ups[:4],
        "speaker_segments": speaker_segments,
        "task_owners": task_owners,
        "markdown_export": markdown_export,
        "notion_export": notion_export,
    }

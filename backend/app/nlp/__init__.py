"""Text cleanup, tone, hallucination filtering, sentence splitting, and meeting
analysis helpers. Pure Python (regex + stdlib) with no ML dependencies.

Mirrors the Swift TextCleanupService and HallucinationFilter for parity.
"""

from .cleanup import (
    light_cleanup,
    normalize_whitespace,
    remove_fillers,
    remove_repeated_words,
    replace_spoken_punctuation,
    split_and_recase,
)
from .hallucination import (
    _BOUNDARY_PUNCTUATION_RE,
    _WHISPER_HALLUCINATION_ALWAYS,
    _WHISPER_HALLUCINATION_ALWAYS_NORMALIZED,
    _WHISPER_HALLUCINATION_SHORT_NORMALIZED,
    _WHISPER_HALLUCINATION_SHORT_ONLY,
    is_whisper_hallucination,
)
from .meeting import (
    build_meeting_summary,
    coerce_speaker_segments,
    coerce_task_owners,
    infer_speaker_segments,
    infer_task_owners,
    render_meeting_markdown_export,
    render_meeting_notion_export,
)
from .sentences import split_sentences
from .tone import apply_tone

__all__ = [
    "apply_tone",
    "build_meeting_summary",
    "coerce_speaker_segments",
    "coerce_task_owners",
    "infer_speaker_segments",
    "infer_task_owners",
    "is_whisper_hallucination",
    "light_cleanup",
    "normalize_whitespace",
    "remove_fillers",
    "remove_repeated_words",
    "render_meeting_markdown_export",
    "render_meeting_notion_export",
    "replace_spoken_punctuation",
    "split_and_recase",
    "split_sentences",
]

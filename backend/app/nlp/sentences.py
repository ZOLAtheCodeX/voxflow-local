"""Sentence segmentation helper.

Uses regex split on sentence-ending punctuation followed by whitespace.
Same intentional gap as cleanup.split_and_recase: no nltk/spacy.
"""

from __future__ import annotations

import re

from .cleanup import normalize_whitespace


def split_sentences(text: str) -> list[str]:
    normalized = normalize_whitespace(text)
    if not normalized:
        return []

    sentences = [chunk.strip() for chunk in re.split(r"(?<=[.!?])\s+", normalized) if chunk.strip()]
    if sentences:
        return sentences
    return [normalized]

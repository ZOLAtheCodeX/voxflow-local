"""PromptFramingEngine — keyword + regex intent detection plus template wrapping.

Pure rule-based, no model call. Maps user input to one of six intents
(email, code, explain, creative, data, general) by counting keyword hits and
preferring earlier intents on tie. Each intent has a fixed prompt template.

Used both as the primary path (WhisperKit / in-process) and as a backend
fallback when Swift's PromptFramingService can't handle the input.
"""

from __future__ import annotations

import re


class PromptFramingEngine:
    _INTENT_KEYWORDS: list[tuple[str, list[str]]] = [
        ("email", ["email", "reply", "message to", "follow up", "follow-up"]),
        ("code", [r"\bfunction\b", r"\bcode\b", "debug", "refactor", "review", "implement", r"\bapi\b", "endpoint", "algorithm", r"\bclass\b", r"\bmethod\b"]),
        ("explain", ["explain", "what is", "how does", "teach", "break down", "why does", "how do"]),
        ("creative", ["blog", "tweet", "post", "story", "tagline", r"\bcopy\b", "headline", "slogan", "draft"]),
        ("data", ["summarize", "compare", "extract", "analyze", "list the", "differences between", "table of"]),
    ]

    _PRIORITY = ["email", "code", "explain", "creative", "data"]

    _TEMPLATES: dict[str, str] = {
        "email": (
            "Task: Draft an email based on the following instructions.\n\n"
            "Instructions: {text}\n\n"
            "Constraints:\n"
            "- Professional tone unless otherwise specified\n"
            "- Concise — aim for 3-5 sentences\n"
            "- Include subject line suggestion\n\n"
            "Output format: Complete email with Subject and Body."
        ),
        "code": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Write clean, production-ready code\n"
            "- Include brief comments for non-obvious logic\n"
            "- Handle edge cases\n\n"
            "Output format: Code with explanation of approach."
        ),
        "explain": (
            "Task: Explain the following clearly and concisely.\n\n"
            "Topic: {text}\n\n"
            "Constraints:\n"
            "- Assume intermediate knowledge level\n"
            "- Use concrete examples where helpful\n"
            "- Keep it under 200 words unless complexity requires more\n\n"
            "Output format: Clear explanation with examples."
        ),
        "creative": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Engaging and original\n"
            "- Match the tone implied in the instructions\n"
            "- Provide 2-3 variations if the output is short-form\n\n"
            "Output format: Creative content as described."
        ),
        "data": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Be precise and factual\n"
            "- Use structured format (bullets, tables) where appropriate\n"
            "- Call out assumptions\n\n"
            "Output format: Structured analysis."
        ),
        "general": (
            "Task: {text}\n\n"
            "Please provide a thorough, well-structured response."
        ),
    }

    @staticmethod
    def _phrase_matches(phrase: str, text: str) -> bool:
        if r"\b" in phrase:
            return bool(re.search(phrase, text))
        return phrase in text

    def detect_intent(self, text: str) -> str:
        lowered = text.lower()
        if not lowered.strip():
            return "general"

        scores: dict[str, int] = {}
        for intent, phrases in self._INTENT_KEYWORDS:
            count = sum(1 for p in phrases if self._phrase_matches(p, lowered))
            if count > 0:
                scores[intent] = count

        if not scores:
            return "general"

        max_score = max(scores.values())
        for intent in self._PRIORITY:
            if scores.get(intent) == max_score:
                return intent

        return "general"

    def frame(self, text: str, intent: str) -> str:
        template = self._TEMPLATES.get(intent, self._TEMPLATES["general"])
        return template.format(text=text)

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from server import PromptFramingEngine


class TestPromptFramingDetectIntent:
    def setup_method(self):
        self.engine = PromptFramingEngine()

    def test_email_intent(self):
        assert self.engine.detect_intent("write an email to my manager") == "email"

    def test_email_intent_reply(self):
        assert self.engine.detect_intent("draft a reply to the client") == "email"

    def test_code_intent(self):
        assert self.engine.detect_intent("write a function that sorts an array") == "code"

    def test_code_intent_debug(self):
        assert self.engine.detect_intent("debug this API endpoint") == "code"

    def test_explain_intent(self):
        assert self.engine.detect_intent("explain how dependency injection works") == "explain"

    def test_explain_intent_what_is(self):
        assert self.engine.detect_intent("what is a monad in functional programming") == "explain"

    def test_creative_intent(self):
        assert self.engine.detect_intent("write a blog post about remote work") == "creative"

    def test_creative_intent_tweet(self):
        assert self.engine.detect_intent("draft a tweet announcing our product launch") == "creative"

    def test_data_intent(self):
        assert self.engine.detect_intent("summarize the quarterly revenue") == "data"

    def test_general_fallback(self):
        assert self.engine.detect_intent("help me think through this") == "general"

    def test_empty_string(self):
        assert self.engine.detect_intent("") == "general"


class TestPromptFramingFrame:
    def setup_method(self):
        self.engine = PromptFramingEngine()

    def test_email_frame_contains_sections(self):
        result = self.engine.frame("reschedule the meeting", "email")
        assert "Task:" in result
        assert "Constraints:" in result
        assert "reschedule the meeting" in result

    def test_code_frame_contains_text(self):
        result = self.engine.frame("binary search function", "code")
        assert "binary search function" in result
        assert "Constraints:" in result

    def test_explain_frame_contains_topic(self):
        result = self.engine.frame("how dependency injection works", "explain")
        assert "Topic:" in result
        assert "how dependency injection works" in result

    def test_general_frame_is_minimal(self):
        result = self.engine.frame("help me think", "general")
        assert "Task:" in result
        assert "help me think" in result
        assert "Constraints:" not in result

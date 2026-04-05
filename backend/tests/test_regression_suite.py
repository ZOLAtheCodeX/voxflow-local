from __future__ import annotations

import unittest

from run_regression_suite import validate_transcript


class RegressionSuiteValidationTests(unittest.TestCase):
    def test_validate_transcript_accepts_close_reference_match(self) -> None:
        expectation = {
            "reference_text": "Schedule the design review for Tuesday at 10 30 AM.",
            "must_include_all": ["design", "review", "tuesday", "10", "30"],
            "min_words": 7,
            "max_words": 12,
            "min_similarity": 0.8,
            "min_token_recall": 0.8,
            "length_ratio_min": 0.75,
            "length_ratio_max": 1.25,
        }

        error, metrics = validate_transcript(
            "Schedule the design review for Tuesday at 10 30 am",
            expectation,
        )

        self.assertIsNone(error)
        self.assertGreaterEqual(metrics["similarity"], 0.8)
        self.assertGreaterEqual(metrics["token_recall"], 0.8)

    def test_validate_transcript_rejects_reference_drift(self) -> None:
        expectation = {
            "reference_text": "Switch Slack to concise mode and keep Mail formal.",
            "must_include_all": ["slack", "concise", "mail", "formal"],
            "min_words": 7,
            "max_words": 11,
            "min_similarity": 0.82,
            "min_token_recall": 0.85,
            "length_ratio_min": 0.8,
            "length_ratio_max": 1.2,
        }

        error, metrics = validate_transcript(
            "Thank you very much for your help",
            expectation,
        )

        self.assertIsNotNone(error)
        self.assertLess(metrics.get("token_recall", 0.0), 0.85)


if __name__ == "__main__":
    unittest.main()

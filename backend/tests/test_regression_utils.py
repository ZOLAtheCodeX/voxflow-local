from __future__ import annotations

import unittest

from regression_utils import is_placeholder_text, meaning_drift_metrics, normalize_text, percentile, word_count


class RegressionUtilsTests(unittest.TestCase):
    def test_percentile_linear_interpolation(self) -> None:
        values = [10.0, 20.0, 30.0, 40.0]
        self.assertEqual(percentile(values, 50), 25.0)
        self.assertEqual(percentile(values, 95), 38.5)

    def test_meaning_drift_metrics(self) -> None:
        original = "Please schedule the design review on Tuesday morning."
        candidate = "Schedule the design review on Tuesday morning."
        similarity, length_ratio, token_recall = meaning_drift_metrics(original, candidate)

        self.assertGreaterEqual(similarity, 0.7)
        self.assertGreaterEqual(length_ratio, 0.7)
        self.assertGreaterEqual(token_recall, 0.8)

    def test_placeholder_detection(self) -> None:
        self.assertTrue(is_placeholder_text("[transcription unavailable: model missing]"))
        self.assertFalse(is_placeholder_text("normal transcript text"))

    def test_word_count_normalization(self) -> None:
        text = "  Hello   from\nVoxFlow   "
        self.assertEqual(normalize_text(text), "Hello from VoxFlow")
        self.assertEqual(word_count(text), 3)


if __name__ == "__main__":
    unittest.main()

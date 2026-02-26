"""Unit tests for PrivateAPIClient network error handling."""
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib import error as urlerror

# Adjust sys.path to allow importing from backend/app
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from fastapi import HTTPException
from server import PrivateAPIClient

class TestPrivateAPIClient(unittest.TestCase):
    def test_chat_completion_http_error(self):
        """Test that PrivateAPIClient raises HTTPException 502 on network errors."""
        client = PrivateAPIClient()

        # Configure client manually to bypass environment variable checks
        client.base_url = "https://api.example.com"
        client.model = "test-model"
        client.api_key = "test-key"

        # Prepare the HTTPError mock
        error_content = b"Simulated API Error"
        fp = io.BytesIO(error_content)
        # HTTPError(url, code, msg, hdrs, fp)
        http_error = urlerror.HTTPError(
            url="https://api.example.com/v1/chat/completions",
            code=500,
            msg="Internal Server Error",
            hdrs={},
            fp=fp
        )

        # Patch urllib.request.urlopen in the server module
        with patch("server.urlrequest.urlopen") as mock_urlopen:
            mock_urlopen.side_effect = http_error

            with self.assertRaises(HTTPException) as cm:
                client._chat_completion("system prompt", "user prompt")

            self.assertEqual(cm.exception.status_code, 502)
            self.assertIn("Private API HTTP error", cm.exception.detail)
            self.assertIn("Simulated API Error", cm.exception.detail)

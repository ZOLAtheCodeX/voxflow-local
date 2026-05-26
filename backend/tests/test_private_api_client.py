"""Unit tests for PrivateAPIClient network error handling."""
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
import httpx
import concurrent.futures

# Adjust sys.path to allow importing from backend/app
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from fastapi import HTTPException
from server import PrivateAPIClient

class TestPrivateAPIClient(unittest.TestCase):
    def setUp(self):
        self.client = PrivateAPIClient()
        # Configure client manually to bypass environment variable checks
        self.client.base_url = "https://api.example.com"
        self.client.model = "test-model"
        self.client.api_key = "test-key"

    @patch("httpx.Client")
    def test_chat_completion_http_error(self, mock_client_class):
        """Test that PrivateAPIClient raises HTTPException 502 on network status errors."""
        mock_client = MagicMock()
        mock_response = MagicMock()
        mock_response.text = "Simulated API Error"
        mock_response.status_code = 500
        
        # Construct realistic HTTPStatusError
        request = httpx.Request("POST", "https://api.example.com/v1/chat/completions")
        mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
            message="Internal Server Error",
            request=request,
            response=mock_response
        )
        
        mock_client.post.return_value = mock_response
        mock_client_class.return_value.__enter__.return_value = mock_client

        with self.assertRaises(HTTPException) as cm:
            self.client._chat_completion("system prompt", "user prompt")

        self.assertEqual(cm.exception.status_code, 502)
        self.assertIn("Private API HTTP error", cm.exception.detail)
        self.assertIn("Simulated API Error", cm.exception.detail)

    @patch("httpx.Client")
    def test_chat_completion_timeout(self, mock_client_class):
        """Test that PrivateAPIClient raises HTTPException 502 on timeout."""
        # Force the thread submit inside _chat_completion to raise TimeoutError
        # or mock uvicorn/httpx post to raise/simulate timeout in executor.
        with patch("concurrent.futures.Future.result") as mock_result:
            mock_result.side_effect = concurrent.futures.TimeoutError("Timeout")
            
            with self.assertRaises(HTTPException) as cm:
                self.client._chat_completion("system prompt", "user prompt")
                
            self.assertEqual(cm.exception.status_code, 502)
            self.assertIn("Private API request timed out", cm.exception.detail)

    @patch("httpx.Client")
    def test_chat_completion_generic_exception(self, mock_client_class):
        """Test that PrivateAPIClient raises HTTPException 502 on generic exception."""
        mock_client = MagicMock()
        mock_client.post.side_effect = Exception("Generic Connection Failure")
        mock_client_class.return_value.__enter__.return_value = mock_client

        with self.assertRaises(HTTPException) as cm:
            self.client._chat_completion("system prompt", "user prompt")

        self.assertEqual(cm.exception.status_code, 502)
        self.assertIn("Private API request failed", cm.exception.detail)
        self.assertIn("Generic Connection Failure", cm.exception.detail)

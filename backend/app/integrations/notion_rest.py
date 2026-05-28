from __future__ import annotations

import json
import logging
from urllib import error as urlerror
from urllib import request as urlrequest

logger = logging.getLogger("voxflow")

_NOTION_API = "https://api.notion.com/v1"
_NOTION_VERSION = "2022-06-28"
_RICH_TEXT_MAX = 2000


class NotionError(Exception):
    """Notion API call failed (network, timeout, non-2xx, or malformed response)."""


class NotionRestClient:
    def __init__(self, base_url: str = _NOTION_API, version: str = _NOTION_VERSION,
                 timeout: float = 15.0) -> None:
        self.base_url = base_url
        self.version = version
        self.timeout = timeout

    def _request(self, method: str, path: str, token: str, payload: dict) -> dict:
        req = urlrequest.Request(
            f"{self.base_url}{path}",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {token}",
                "Notion-Version": self.version,
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with urlrequest.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read()
        except urlerror.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace") if exc.fp else ""
            logger.warning("Notion %s %s -> HTTP %s %s", method, path, exc.code, detail[:200])
            raise NotionError(f"Notion API error {exc.code}") from exc
        except (urlerror.URLError, TimeoutError, ConnectionError) as exc:
            logger.warning("Notion %s %s unreachable: %s", method, path, exc)
            raise NotionError("Notion API unreachable") from exc
        try:
            return json.loads(body.decode("utf-8"))
        except (ValueError, TypeError) as exc:
            logger.error("Notion response malformed: %s", exc)
            raise NotionError("Notion response malformed") from exc

    def search(self, token: str, query: str, page_size: int = 10) -> list[dict]:
        parsed = self._request("POST", "/search", token, {
            "query": query,
            "filter": {"property": "object", "value": "page"},
            "page_size": page_size,
        })
        out: list[dict] = []
        for item in parsed.get("results", []):
            if not isinstance(item, dict) or item.get("object") != "page":
                continue
            out.append({
                "id": item.get("id", ""),
                "title": self._extract_title(item),
                "url": item.get("url", ""),
            })
        return out

    def append(self, token: str, page_id: str, text: str) -> int:
        chunks = [text[i:i + _RICH_TEXT_MAX] for i in range(0, len(text), _RICH_TEXT_MAX)] or [""]
        children = [
            {"object": "block", "type": "paragraph",
             "paragraph": {"rich_text": [{"type": "text", "text": {"content": c}}]}}
            for c in chunks
        ]
        parsed = self._request("PATCH", f"/blocks/{page_id}/children", token, {"children": children})
        return len(parsed.get("results", []))

    @staticmethod
    def _extract_title(page: dict) -> str:
        for prop in page.get("properties", {}).values():
            if isinstance(prop, dict) and prop.get("type") == "title":
                title = "".join(
                    part.get("text", {}).get("content", "")
                    for part in prop.get("title", []) if isinstance(part, dict)
                )
                if title:
                    return title
        return "(untitled)"

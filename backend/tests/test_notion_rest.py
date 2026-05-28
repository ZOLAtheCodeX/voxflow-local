import io
import json
import sys
from pathlib import Path

import pytest
from urllib import error as urlerror

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from integrations.notion_rest import NotionRestClient, NotionError


class _FakeResp:
    def __init__(self, payload): self._b = json.dumps(payload).encode()
    def read(self): return self._b
    def __enter__(self): return self
    def __exit__(self, *a): return False


def _patch_urlopen(monkeypatch, capture, resp=None, exc=None):
    def fake(req, timeout=None):
        capture["method"] = req.method
        capture["url"] = req.full_url
        capture["headers"] = dict(req.header_items())
        capture["body"] = json.loads(req.data.decode()) if req.data else None
        if exc is not None:
            raise exc
        return resp
    monkeypatch.setattr("integrations.notion_rest.urlrequest.urlopen", fake)


def test_search_parses_results_and_title(monkeypatch):
    cap = {}
    payload = {"results": [
        {"object": "page", "id": "abc", "url": "https://notion.so/abc",
         "properties": {"Name": {"type": "title",
            "title": [{"text": {"content": "Privacy "}}, {"text": {"content": "Notes"}}]}}},
        {"object": "data_source", "id": "skip"},
    ]}
    _patch_urlopen(monkeypatch, cap, resp=_FakeResp(payload))
    out = NotionRestClient().search(token="t", query="privacy")
    assert out == [{"id": "abc", "title": "Privacy Notes", "url": "https://notion.so/abc"}]
    assert cap["method"] == "POST"
    assert cap["url"].endswith("/v1/search")
    assert cap["headers"]["Authorization"] == "Bearer t"
    assert cap["headers"]["Notion-version"] == "2022-06-28"  # urllib title-cases header keys
    assert cap["body"]["filter"] == {"property": "object", "value": "page"}


def test_search_untitled_when_no_title_prop(monkeypatch):
    cap = {}
    payload = {"results": [{"object": "page", "id": "x", "url": "u", "properties": {}}]}
    _patch_urlopen(monkeypatch, cap, resp=_FakeResp(payload))
    out = NotionRestClient().search(token="t", query="q")
    assert out[0]["title"] == "(untitled)"


def test_append_builds_paragraph_and_returns_count(monkeypatch):
    cap = {}
    _patch_urlopen(monkeypatch, cap, resp=_FakeResp({"results": [{"id": "b1"}]}))
    n = NotionRestClient().append(token="t", page_id="pg", text="hello world")
    assert n == 1
    assert cap["method"] == "PATCH"
    assert cap["url"].endswith("/v1/blocks/pg/children")
    block = cap["body"]["children"][0]
    assert block["type"] == "paragraph"
    assert block["paragraph"]["rich_text"][0]["text"]["content"] == "hello world"


def test_append_chunks_text_over_2000_chars(monkeypatch):
    cap = {}
    _patch_urlopen(monkeypatch, cap, resp=_FakeResp({"results": [{}, {}, {}]}))
    NotionRestClient().append(token="t", page_id="pg", text="x" * 4500)
    assert len(cap["body"]["children"]) == 3  # 2000 + 2000 + 500


def test_http_error_raises_notion_error(monkeypatch):
    cap = {}
    err = urlerror.HTTPError("u", 401, "Unauthorized", {}, io.BytesIO(b'{"message":"bad token"}'))
    _patch_urlopen(monkeypatch, cap, exc=err)
    with pytest.raises(NotionError):
        NotionRestClient().search(token="bad", query="q")


def test_network_error_raises_notion_error(monkeypatch):
    cap = {}
    _patch_urlopen(monkeypatch, cap, exc=urlerror.URLError("down"))
    with pytest.raises(NotionError):
        NotionRestClient().append(token="t", page_id="pg", text="hi")


def test_malformed_json_raises_notion_error(monkeypatch):
    cap = {}
    class _Bad(_FakeResp):
        def read(self): return b"not json"
    _patch_urlopen(monkeypatch, cap, resp=_Bad({}))
    with pytest.raises(NotionError):
        NotionRestClient().search(token="t", query="q")

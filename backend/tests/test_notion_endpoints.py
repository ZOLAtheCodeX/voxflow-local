import os
import sys
from pathlib import Path

os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_MODELS_DIR", "/nonexistent")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import pytest
from fastapi.testclient import TestClient

import server
from integrations.notion_rest import NotionError


@pytest.fixture
def client():
    return TestClient(server.app)


def test_search_ok(client, monkeypatch):
    monkeypatch.setattr(server.notion_client, "search",
                        lambda token, query, **k: [{"id": "p1", "title": "Notes", "url": "u"}])
    r = client.post("/v1/notion/search", json={"notion_token": "t", "query": "notes"})
    assert r.status_code == 200
    assert r.json()["results"][0]["title"] == "Notes"


def test_search_blank_token_422(client):
    r = client.post("/v1/notion/search", json={"notion_token": "", "query": "x"})
    assert r.status_code == 422


def test_search_notion_error_502(client, monkeypatch):
    def boom(token, query, **k): raise NotionError("bad")
    monkeypatch.setattr(server.notion_client, "search", boom)
    r = client.post("/v1/notion/search", json={"notion_token": "t", "query": "x"})
    assert r.status_code == 502


def test_append_ok(client, monkeypatch):
    monkeypatch.setattr(server.notion_client, "append", lambda token, page_id, text, **k: 2)
    r = client.post("/v1/notion/append",
                    json={"notion_token": "t", "page_id": "pg", "text": "hello"})
    assert r.status_code == 200
    assert r.json()["appended_blocks"] == 2


def test_append_notion_error_502(client, monkeypatch):
    def boom(token, page_id, text, **k): raise NotionError("fail")
    monkeypatch.setattr(server.notion_client, "append", boom)
    r = client.post("/v1/notion/append",
                    json={"notion_token": "t", "page_id": "pg", "text": "hello"})
    assert r.status_code == 502


def test_search_whitespace_token_422(client):
    r = client.post("/v1/notion/search", json={"notion_token": "   ", "query": "x"})
    assert r.status_code == 422


def test_append_whitespace_token_422(client):
    r = client.post("/v1/notion/append",
                    json={"notion_token": "   ", "page_id": "pg", "text": "hello"})
    assert r.status_code == 422

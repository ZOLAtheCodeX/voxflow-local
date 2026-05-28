# Cockpit Phase C — Notion REST Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the cockpit search the user's Notion workspace and append finished text (a dictation or a smart-action result) to a chosen Notion page, via the Notion REST API authenticated with a user-supplied integration token.

**Architecture:** The Python backend gains a dependency-free `NotionRestClient` (stdlib `urllib`, mirroring `OllamaBackend`) and two POST endpoints (`/v1/notion/search`, `/v1/notion/append`). The Notion **integration token lives only in the macOS Keychain on the Swift side** and travels to the local backend as a per-request body field (`notion_token`) — exactly like the existing `consent_token` — so the backend never persists a credential. Swift adds `BackendAPIClient.notionSearch/notionAppend`, a Settings token field, a cockpit target-picker "Notion · \<page\>" option, and an append-on-insert branch.

**Tech Stack:** Python 3.11 + FastAPI + Pydantic + stdlib `urllib` (no new runtime deps); pytest. Swift 6.2 + SwiftUI; `KeychainService`; `BackendAPIClient` (configured `URLSession`, `.convertTo/FromSnakeCase`). Notion REST API `2022-06-28`.

---

## Decisions locked

- **Token transport:** request **body field** `notion_token` (mirrors `consent_token`; explorer Pattern 5). NOT a header, NOT backend env. Backend uses it transiently then discards.
- **HTTP client:** stdlib `urllib` (`httpx` is dev-only — explorer Pattern 3b). Mirror `OllamaBackend` (`llm_backend.py:126–150`).
- **Notion-Version:** pinned constant `2022-06-28` (stable; page-object search + block-append contract confirmed via API docs).
- **Swift JSON keys:** rely on `BackendAPIClient`'s `.convertToSnakeCase`/`.convertFromSnakeCase`; choose field names that convert cleanly (`pageId`→`page_id`, `notionToken`→`notion_token`, `appendedBlocks`→`appended_blocks`). **Do NOT add explicit `CodingKeys`** — that redundancy is what caused the recent Ollama `keyNotFound` bug (`0c03bd4`).
- **Endpoints are I/O-bound, not ML-bound:** call `await run_blocking(notion_client.<op>, ...)` directly; skip the ML semaphore (explorer Pattern 2).
- **Both inbound routes are POST** → no CORS `allow_methods` change needed.

## Notion REST contract (verified from docs)

| Op | Method + URL | Body | Response (used fields) |
|---|---|---|---|
| Search | `POST https://api.notion.com/v1/search` | `{"query": str, "filter": {"property":"object","value":"page"}, "page_size": int}` | `results[]` → each `{object:"page", id, url, properties}`; title lives in the property whose `type=="title"` → `title[].text.content` |
| Append | `PATCH https://api.notion.com/v1/blocks/{page_id}/children` | `{"children":[{"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content": str}}]}}]}` | `results[]` (appended blocks) |

Headers (all): `Authorization: Bearer <token>`, `Notion-Version: 2022-06-28`, `Content-Type: application/json`.
Limits: ~3 req/s → HTTP `429` + `Retry-After`; rich-text content ≤ **2000 chars**; ≤ **100 children**/request. The client chunks text into ≤2000-char paragraphs.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `backend/app/integrations/__init__.py` | **create** | mark package |
| `backend/app/integrations/notion_rest.py` | **create** | `NotionRestClient` (urllib): `search`, `append`, `_extract_title`; `NotionError` |
| `backend/app/schemas.py` | modify | `NotionSearch/Append` request+response models |
| `backend/app/context.py` | modify | `notion_client = NotionRestClient()` singleton |
| `backend/app/server.py` | modify | re-export `notion_client` + `NotionError` |
| `backend/app/api/endpoints.py` | modify | `POST /v1/notion/search`, `POST /v1/notion/append` |
| `backend/tests/test_notion_rest.py` | **create** | client unit tests (mock `urlopen`) |
| `backend/tests/test_notion_endpoints.py` | **create** | endpoint tests (TestClient + mocked client) |
| `Sources/VoxFlowApp/Services/BackendAPIClient.swift` | modify | `notionSearch`, `notionAppend` |
| `Sources/VoxFlowApp/Models/AppModels.swift` | modify | `NotionTarget` (id+title) |
| `Sources/VoxFlowApp/Views/SettingsView.swift` | modify | "Notion" section: token `SecureField` → Keychain |
| `Sources/VoxFlowApp/Services/CockpitCoordinator.swift` | modify | Notion target state + append-on-insert branch |
| `Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift` | modify | target-picker "Notion · \<page\>" search + select |

**Backend conventions to mirror:** logger `logging.getLogger("voxflow")`; never bare `except: pass`; `run_blocking` + endpoint shape from `smart_action` (`endpoints.py:282`). **Swift:** `KeychainService.save/load`; `BackendAPIClient.session`; never `URLSession.shared`.

---

# Backend (C1–C3) — full TDD

## Task C1: Notion request/response schemas

**Files:** Modify `backend/app/schemas.py`

- [ ] **Step 1: Add the models** (near the other request models; mirror `SmartActionRequest` style)

```python
class NotionSearchRequest(BaseModel):
    notion_token: str = Field(min_length=1)
    query: str = Field(min_length=1, max_length=500)


class NotionSearchResult(BaseModel):
    id: str
    title: str
    url: str


class NotionSearchResponse(BaseModel):
    results: list[NotionSearchResult]


class NotionAppendRequest(BaseModel):
    notion_token: str = Field(min_length=1)
    page_id: str = Field(min_length=1, max_length=64)
    text: str = Field(min_length=1, max_length=50_000)

    @field_validator("text")
    @classmethod
    def _text_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("text must not be blank")
        return value


class NotionAppendResponse(BaseModel):
    appended_blocks: int
    error: str | None = None
```

- [ ] **Step 2: Verify import** — `cd backend && ../.venv/bin/python -c "from app.schemas import NotionSearchRequest, NotionAppendRequest; print('ok')"` → prints `ok`. (Run from repo root: `./.venv/bin/python -c "import sys; sys.path.insert(0,'backend/app'); import schemas; print('ok')"` if that matches the existing import style — check how other tests import `schemas`.)

- [ ] **Step 3: Commit** — `git add backend/app/schemas.py && git commit -m "feat(notion): request/response schemas"`

## Task C2: NotionRestClient (urllib) — TDD

**Files:** Create `backend/app/integrations/__init__.py`, `backend/app/integrations/notion_rest.py`, `backend/tests/test_notion_rest.py`

- [ ] **Step 1: Write the failing tests** `backend/tests/test_notion_rest.py`

```python
import io
import json
import pytest
from urllib import error as urlerror

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
```

- [ ] **Step 2: Run — expect failure** — `./.venv/bin/python -m pytest backend/tests/test_notion_rest.py -q` → FAIL (`integrations.notion_rest` missing).

- [ ] **Step 3: Implement** `backend/app/integrations/__init__.py` (empty) and `backend/app/integrations/notion_rest.py`

```python
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
```

- [ ] **Step 4: Run — expect pass** — `./.venv/bin/python -m pytest backend/tests/test_notion_rest.py -q` → 7 passed. (If the `Notion-version` header-case assertion fails, print `cap["headers"]` and match urllib's actual casing — it title-cases to `Notion-version`.)

- [ ] **Step 5: Commit** — `git add backend/app/integrations backend/tests/test_notion_rest.py && git commit -m "feat(notion): urllib NotionRestClient (search/append/title) + tests"`

## Task C3: `/v1/notion/*` endpoints + singleton wiring

**Files:** Modify `backend/app/context.py`, `backend/app/server.py`, `backend/app/api/endpoints.py`; Create `backend/tests/test_notion_endpoints.py`

- [ ] **Step 1: Write the failing endpoint tests** `backend/tests/test_notion_endpoints.py` (match how existing endpoint tests build the `TestClient` and patch singletons — open `backend/tests/test_endpoints.py` and mirror its client fixture + monkeypatch style exactly)

```python
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
```

- [ ] **Step 2: Run — expect failure** — `./.venv/bin/python -m pytest backend/tests/test_notion_endpoints.py -q` → FAIL (routes 404 / `server.notion_client` missing).

- [ ] **Step 3: Singleton** — in `backend/app/context.py`, beside the other singletons (~line 52–70):
```python
from integrations.notion_rest import NotionRestClient  # top with other imports
notion_client = NotionRestClient()
```

- [ ] **Step 4: Re-export** — in `backend/app/server.py`, add to the context re-export block (the `from context import (...)`): `notion_client`; and add `from integrations.notion_rest import NotionError  # noqa: F401`.

- [ ] **Step 5: Endpoints** — in `backend/app/api/endpoints.py`: add `notion_client` to the `from context import (...)` block and `from integrations.notion_rest import NotionError`; import the schemas; then add:
```python
@router.post("/v1/notion/search", response_model=NotionSearchResponse)
async def notion_search(payload: NotionSearchRequest) -> NotionSearchResponse:
    try:
        results = await run_blocking(
            notion_client.search, token=payload.notion_token, query=payload.query
        )
    except NotionError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return NotionSearchResponse(results=[NotionSearchResult(**r) for r in results])


@router.post("/v1/notion/append", response_model=NotionAppendResponse)
async def notion_append(payload: NotionAppendRequest) -> NotionAppendResponse:
    try:
        count = await run_blocking(
            notion_client.append,
            token=payload.notion_token, page_id=payload.page_id, text=payload.text,
        )
    except NotionError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return NotionAppendResponse(appended_blocks=count)
```
(Add `NotionSearchResult` to the schema imports.)

- [ ] **Step 6: Run — expect pass** — `./.venv/bin/python -m pytest backend/tests/test_notion_endpoints.py backend/tests/test_notion_rest.py -q` → all pass. Then full backend: `./.venv/bin/python -m pytest backend/tests -q` → no regressions.

- [ ] **Step 7: Commit** — `git add backend/app/context.py backend/app/server.py backend/app/api/endpoints.py backend/tests/test_notion_endpoints.py && git commit -m "feat(notion): /v1/notion/search + /v1/notion/append endpoints"`

---

# Swift (C4–C7)

> Swift unit tests use fakes; the **live Notion round-trip is a manual gate** (needs a real token + workspace). Build is the compile gate for UI tasks.

## Task C4: BackendAPIClient.notionSearch / notionAppend

**Files:** Modify `Sources/VoxFlowApp/Services/BackendAPIClient.swift`, `Sources/VoxFlowApp/Models/AppModels.swift`

- [ ] **Step 1: Model** — in `AppModels.swift` add (camelCase fields convert cleanly; **no CodingKeys**):
```swift
struct NotionTarget: Codable, Identifiable, Equatable, Sendable {
    let id: String      // Notion page id
    let title: String
    let url: String
}
```

- [ ] **Step 2: Client methods** — in `BackendAPIClient.swift`, mirror `performSmartAction` (inline structs, `BackendAPIClient.session`, `checkHTTPStatus`, the configured `encoder`/`decoder`). Field names convert via `.convertToSnakeCase` — **do not add CodingKeys**:
```swift
static func notionSearch(query: String, token: String) async throws -> [NotionTarget] {
    struct Request: Encodable { let notionToken: String; let query: String }   // -> notion_token, query
    struct Response: Decodable { let results: [NotionTarget] }
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/notion/search"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(Request(notionToken: token, query: query))
    let (data, response) = try await session.data(for: request)
    try checkHTTPStatus(response, data: data)
    return try decoder.decode(Response.self, from: data).results
}

static func notionAppend(pageId: String, text: String, token: String) async throws -> Int {
    struct Request: Encodable { let notionToken: String; let pageId: String; let text: String }
    struct Response: Decodable { let appendedBlocks: Int }   // <- appended_blocks
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/notion/append"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(Request(notionToken: token, pageId: pageId, text: text))
    let (data, response) = try await session.data(for: request)
    try checkHTTPStatus(response, data: data)
    return try decoder.decode(Response.self, from: data).appendedBlocks
}
```
(Confirm the exact names of `baseURL`, `encoder`, `decoder`, `session`, `checkHTTPStatus` in the file and match them — they're the same the inline `performSmartAction` uses.)

- [ ] **Step 3: Build + commit** — `swift build` clean → `git add Sources/VoxFlowApp/Services/BackendAPIClient.swift Sources/VoxFlowApp/Models/AppModels.swift && git commit -m "feat(notion): BackendAPIClient.notionSearch/notionAppend + NotionTarget"`

## Task C5: Settings → Notion token (Keychain)

**Files:** Modify `Sources/VoxFlowApp/Views/SettingsView.swift`

- [ ] **Step 1** — add a constant for the account key (one place, reused by C6/C7), e.g. `enum NotionKeychain { static let account = "notion.integration.token" }` (put in `BackendAPIClient.swift` or a small file so both Settings and the coordinator share it).
- [ ] **Step 2** — add a `Section("Notion")` to `SettingsView` (it already has `coordinator`/`state`). A `@State private var notionToken: String` seeded from `KeychainService.load(account: NotionKeychain.account) ?? ""`, a `SecureField`, and a Save button:
```swift
Section("Notion") {
    SecureField("Integration token (secret_…)", text: $notionToken)
    Button("Save token") {
        KeychainService.save(account: NotionKeychain.account, value: notionToken)
    }
    if KeychainService.load(account: NotionKeychain.account)?.isEmpty == false {
        Label("Token stored in Keychain", systemImage: "checkmark.seal")
            .font(VF.captionFont).foregroundStyle(.secondary)
    }
    Text("Create an internal integration at notion.so/my-integrations, share your target page with it, paste the token here.")
        .font(VF.captionFont).foregroundStyle(.secondary)
}
```
- [ ] **Step 3** — `swift build` clean. **Manual:** Settings → paste a token → Save → confirm the "stored" label appears and persists across relaunch. Commit.

## Task C6: Cockpit target picker — "Notion · \<page\>"

**Files:** Modify `Sources/VoxFlowApp/Services/CockpitCoordinator.swift`, `Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift`

- [ ] **Step 1** — add Notion-target state to `CockpitCoordinator`: `@Published var notionTarget: NotionTarget?` (published so the side panel reflects selection) and a method:
```swift
func searchNotion(_ query: String) async -> [NotionTarget] {
    guard let token = KeychainService.load(account: NotionKeychain.account), !token.isEmpty else { return [] }
    return (try? await BackendAPIClient.notionSearch(query: query, token: token)) ?? []
}
func selectNotionTarget(_ target: NotionTarget?) { notionTarget = target }
```
- [ ] **Step 2** — in `CockpitSidePanelView`'s target section, add a disclosure/search field that calls `coordinator.searchNotion(query)` and lists results as selectable rows (`Button { coordinator.selectNotionTarget(result) }`), showing the current `coordinator.notionTarget?.title` as "Notion · \<title\>" when set. Follow the existing card/`sectionTitle` style. (The side panel currently takes `state`/`sessionService`/`dictionary`; thread `coordinator` or the needed closures per the existing construction site in `CockpitWindowView`.)
- [ ] **Step 3** — `swift build` clean. **Manual:** with a token saved, type a query, see pages, select one → side panel shows "Notion · \<title\>". Commit.

## Task C7: Append on insert when a Notion target is set

**Files:** Modify `Sources/VoxFlowApp/Services/CockpitCoordinator.swift`

- [ ] **Step 1** — in `insertIntoTarget()` (the ⌘↩ path), branch: if `notionTarget != nil`, append to Notion instead of AX-insert:
```swift
func insertIntoTarget() async {
    guard let session = sessionService.currentSession, !session.transcript.isEmpty else { return }
    if let target = notionTarget {
        guard let token = KeychainService.load(account: NotionKeychain.account), !token.isEmpty else {
            state.statusLine = "Notion token missing — add it in Settings"; return
        }
        do {
            _ = try await BackendAPIClient.notionAppend(pageId: target.id, text: session.transcript, token: token)
            state.statusLine = "Appended to Notion · \(target.title)"
            state.cockpitVisible = false
            sessionService.reset()
        } catch {
            state.statusLine = "Notion append failed"
        }
        return
    }
    // ... existing AX-insert path unchanged ...
}
```
(Read the current `insertIntoTarget()` first; preserve the existing AX branch verbatim below the Notion branch.)
- [ ] **Step 2** — `swift build` clean; `swift test` full suite green (no regressions). **Manual:** select a Notion page, ⌘↩ → text appears on the Notion page; status line confirms. Commit.

---

## Sequencing & PR strategy

```
C1 schemas → C2 client(TDD) → C3 endpoints(TDD)   [backend — can ship as one PR]
                                   ↓
C4 Swift client → C5 token UI → C6 target picker → C7 append-on-insert   [Swift — second PR]
```
- Backend (C1–C3) is pure TDD and independently shippable/testable without Notion creds (mocked).
- Swift (C4–C7) is sequential (shared `CockpitCoordinator`/construction sites) — not a swarm; the live round-trip is the user's manual gate (needs a real token + a page shared with the integration).
- One worktree (`worktree-cockpit-l1-phase-c`); finish via `superpowers:finishing-a-development-branch`.

## Risks / open points
- **Notion-Version drift:** pinned `2022-06-28`; if search returns the newer `data_source` envelope, the `object=="page"` filter still selects pages. Bump the constant only if needed.
- **Title extraction:** database pages put the title under a named property (type `title`), not always `"title"` — handled by scanning for `type=="title"`. Pages with no title → `"(untitled)"`.
- **Header case:** urllib title-cases header keys (`Notion-version`); the C2 test asserts the real casing.
- **429 handling:** out of scope for v1 (single-shot calls, low volume). If hit, surface the 502 to the user; add `Retry-After` backoff later if needed.

# Local Backend Trust Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only the VoxFlow app (and developer tooling holding the launch token) can drive the backend on 127.0.0.1:8765; web pages and token-less local processes are refused.

**Architecture:** One pure-ASGI middleware (`backend/app/trust.py`) enforces Host, browser-marker, token, and JSON content-type checks on HTTP and WebSocket scopes, outermost in the stack. The app generates one token per launch, passes it to the managed backend as `VOXFLOW_API_TOKEN`, and attaches it to every request; the backend mirrors its active token to a 0600 file for scripts and adopt mode. The stale-backend identity probe moves to the token-free `/v1/health`.

**Tech Stack:** Python 3.11+, FastAPI 0.116.1 / Starlette, pytest + anyio; Swift 6.2 (strict concurrency), XCTest, macOS 14+; bash scripts.

**Spec:** `docs/superpowers/specs/2026-10-26-local-backend-trust-boundary-design.md` (revision 2). Read it before starting any task.

## Global Constraints

- Header name `X-VoxFlow-Token` (ASGI raw key `b"x-voxflow-token"`). Token format: exactly 64 lowercase hex characters.
- Env vars: `VOXFLOW_API_TOKEN` (token in), `VOXFLOW_TOKEN_DIR` (token-file directory override). Explicit adopt flag: `VOXFLOW_ADOPT_FOREIGN_BACKEND == "1"`.
- Token file: `<dir>/backend.token`, `<dir>` default `~/Library/Application Support/VoxFlow`; file mode 0600, no trailing newline; new directory mode 0700, existing directory never chmod'ed.
- Exempt path: exactly `/v1/health` (no prefix match).
- Host must fully match, case-insensitive: `^(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?$`, exactly one Host header.
- Responses (JSON body `{"detail": ...}`): 400 `Invalid host`; 403 `Browser requests are not accepted`; 401 `Missing or invalid token`; 415 `Content-Type must be application/json`. WebSocket rejection: close code 1008 before accept.
- Browser markers: any `Origin`, `Sec-Fetch-Site`, or `Sec-Fetch-Mode` header, any value.
- Never log a token. Python logging via `logging.getLogger("voxflow")`; no bare `except Exception: pass`.
- CLAUDE.md "Do Not" rules apply, in particular: tests never construct real system-touching services (use `BackendProcessRunning` fakes and `MockURLProtocol`); no `URLSession.shared`; never `print()` in Python.
- Commits: imperative subject, detailed body, trailer `Co-Authored-By: Claude <model> <noreply@anthropic.com>` for the model that did the work.

## Review Focus

1. Fresh install: the token directory does not exist when the backend first starts. Expect it created with mode 0700 and the file written (Task 4 test `test_missing_directory_is_created_0700`).
2. Large or streaming traffic: the middleware must never read a request body (base64 audio can be megabytes) and must not buffer `StreamingResponse` (`/v1/ollama/pull`). Expect bodies passed through untouched and NDJSON lines delivered incrementally (Task 1 `test_accepted_request_body_reaches_app_unread`, Task 2 `test_ollama_pull_streams_through_middleware`).
3. A token file with trailing whitespace or newline (hand-edited, or written by another tool). Expect scripts and the app reader to trim it and still authenticate (Task 5 `test_token_lookup_trims_whitespace`, Task 8 `testTokenFileTrimsWhitespaceAndRejectsMalformed`).
4. App relaunch while the previous launch's backend is still on the port. Expect the identity probe to classify it foreign from `/v1/health` and a 401 to be recognised as a token rejection, never shown as "Backend offline" (Task 6 `testIdentityProbeReadsInstanceStampWithoutToken`, Task 8 `testTokenRejectionIsRecognizedOnlyFor401`).
5. Custom port or `localhost` URL (`VOXFLOW_BACKEND_URL=http://localhost:9000`). Expect the Host check to accept it and the spawn to carry the token (Task 1 host cases include `localhost:9000`; Task 7 `testSpawnEnvironmentCarriesLaunchTokenAcrossRestart` uses port 9000).

---

### Task 1: TrustBoundaryMiddleware module

**Files:**
- Create: `backend/app/trust.py`
- Test: `backend/tests/test_trust_boundary.py` (middleware wrapped around a tiny in-test FastAPI app; Task 2 adds real-app tests to the same file)

**Interfaces:**
- Produces:
  - `TOKEN_HEADER: bytes = b"x-voxflow-token"`, `HEALTH_PATH: str = "/v1/health"`
  - `resolve_active_token(env: Mapping[str, str] | None = None) -> str` — env token if it matches `^[0-9a-f]{64}$`; malformed env token logs an error and raises `SystemExit`; absent env token returns `secrets.token_hex(32)`. Not cached.
  - `active_token() -> str` — `resolve_active_token()` once, cached at module level.
  - `class TrustBoundaryMiddleware` with `__init__(self, app: ASGIApp, token_provider: Callable[[], str] = active_token)` and `async __call__(self, scope, receive, send)`.

- [ ] **Step 1: Write the failing tests**

Build a tiny app inside the test module: `GET /v1/health` → `{"ok": True}`, `GET /v1/ready` → `{"ok": True}`, `POST /v1/echo` (JSON body `{"x": int}`) → echo, WebSocket `/v1/events` that accepts and sends `{"event": "connected"}`. Wrap it: `TrustBoundaryMiddleware(tiny_app, token_provider=lambda: TOKEN)` with `TOKEN = "ab" * 32`. Client: `TestClient(wrapped, base_url="http://127.0.0.1:8765")`. For cases `TestClient` cannot express (missing Host, duplicate headers, non-ASCII bytes, body-read checks), call the middleware directly with a hand-built ASGI scope and collect sent messages, through three test-local helpers:
- `http_scope(path: str = "/v1/health", method: str = "GET", headers: list[tuple[bytes, bytes]] = ...) -> dict` — a minimal ASGI 3 HTTP scope (`type`, `method`, `path`, `raw_path`, `headers`, `query_string=b""`, `client=("127.0.0.1", 50000)`).
- `async def raw_status(scope: dict, receive=empty_receive) -> int` — runs the wrapped app and returns the status from the `http.response.start` message.
- `receive_that_fails` — an async callable that fails the test if awaited.

```python
AUTH = {"X-VoxFlow-Token": TOKEN}

@pytest.mark.parametrize("host", ["evil.example:8765", "localhost.", "127.0.0.2", "::1:8765", "evil.example"])
def test_bad_host_is_400_even_on_health(client, host):
    for path in ("/v1/health", "/v1/ready"):
        r = client.get(path, headers={**AUTH, "Host": host})
        assert r.status_code == 400
        assert r.json() == {"detail": "Invalid host"}

@pytest.mark.parametrize("host", ["LOCALHOST:8765", "localhost:9000", "[::1]", "[::1]:8765", "127.0.0.1"])
def test_loopback_hosts_pass(client, host):
    assert client.get("/v1/ready", headers={**AUTH, "Host": host}).status_code == 200

async def test_missing_or_duplicate_host_is_400():
    assert await raw_status(http_scope(headers=[(b"x-voxflow-token", TOKEN.encode())])) == 400
    dup = [(b"host", b"127.0.0.1:8765"), (b"host", b"evil.example"), (b"x-voxflow-token", TOKEN.encode())]
    assert await raw_status(http_scope(headers=dup)) == 400

@pytest.mark.parametrize("header", [("Origin", "http://127.0.0.1"), ("Origin", "null"),
                                    ("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "no-cors")])
def test_browser_markers_are_403_even_with_token(client, header):
    assert client.get("/v1/health", headers=dict([header])).status_code == 403
    r = client.post("/v1/echo", json={"x": 1}, headers={**AUTH, header[0]: header[1]})
    assert r.status_code == 403
    assert r.json() == {"detail": "Browser requests are not accepted"}

def test_token_rules(client):
    assert client.get("/v1/ready").status_code == 401
    assert client.get("/v1/ready", headers={"X-VoxFlow-Token": "cd" * 32}).status_code == 401
    assert client.get("/v1/ready", headers=AUTH).status_code == 200
    assert client.get("/v1/health").status_code == 200
    assert client.get("/v1/health/x").status_code == 401   # exact-path exemption only

async def test_non_ascii_or_duplicate_token_is_401_not_500():
    base = [(b"host", b"127.0.0.1:8765")]
    assert await raw_status(http_scope("/v1/ready", headers=base + [(b"x-voxflow-token", b"\xff" * 64)])) == 401
    two = base + [(b"x-voxflow-token", TOKEN.encode()), (b"x-voxflow-token", TOKEN.encode())]
    assert await raw_status(http_scope("/v1/ready", headers=two)) == 401

@pytest.mark.parametrize("ctype", [None, "text/plain", "+json", "text/plain;charset=UTF-8"])
def test_post_without_json_content_type_is_415(client, ctype):
    headers = {**AUTH, **({"Content-Type": ctype} if ctype else {})}
    r = client.post("/v1/echo", content=b'{"x": 1}', headers=headers)
    assert r.status_code == 415
    assert r.json() == {"detail": "Content-Type must be application/json"}

@pytest.mark.parametrize("ctype", ["application/json; charset=utf-8", "application/vnd.voxflow+json"])
def test_json_content_types_pass(client, ctype):
    assert client.post("/v1/echo", content=b'{"x": 1}', headers={**AUTH, "Content-Type": ctype}).status_code == 200

@pytest.mark.parametrize("headers", [{}, {"X-VoxFlow-Token": "cd" * 32}, {**AUTH, "Origin": "http://127.0.0.1"}])
def test_websocket_rejections_close_1008(client, headers):
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect("/v1/events", headers=headers) as ws:
            ws.receive_json()
    assert exc.value.code == 1008

def test_websocket_with_token_connects(client):
    with client.websocket_connect("/v1/events", headers=AUTH) as ws:
        assert ws.receive_json() == {"event": "connected"}

async def test_rejected_request_never_reads_body():
    # receive() raises if called: rejection must come from headers alone
    assert await raw_status(http_scope("/v1/echo", method="POST",
        headers=[(b"host", b"127.0.0.1:8765")]), receive=receive_that_fails) == 401

async def test_accepted_request_body_reaches_app_unread():
    # the inner app gets the exact body bytes; the middleware did not consume them
    ...  # assert inner app saw b'{"x": 1}' via a recording receive

def test_resolve_active_token():
    assert resolve_active_token({"VOXFLOW_API_TOKEN": "ab" * 32}) == "ab" * 32
    assert re.fullmatch(r"[0-9a-f]{64}", resolve_active_token({}))
    for bad in ("short", "AB" * 32, "ab" * 31 + "z1", " " * 64):
        with pytest.raises(SystemExit):
            resolve_active_token({"VOXFLOW_API_TOKEN": bad})
```

Write `test_accepted_request_body_reaches_app_unread` concretely: a recording inner ASGI app collects `receive()` messages; assert the joined body equals `b'{"x": 1}'`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.venv/bin/python -m pytest backend/tests/test_trust_boundary.py -q`
Expected: collection error, `ModuleNotFoundError: No module named 'trust'`.

- [ ] **Step 3: Implement `backend/app/trust.py`**

Check order and exact rules are Decision 2 of the spec. Implementation notes the tests do not pin:
- Read `scope["headers"]` as the raw list; count and collect values per lowercased key; never build a dict.
- Token comparison: `hmac.compare_digest(presented_bytes, token.encode("ascii"))` on raw header bytes.
- HTTP rejection: send `http.response.start` + `http.response.body` with `content-type: application/json` without calling `receive`.
- WebSocket rejection: `await receive()` (the `websocket.connect` message), then `await send({"type": "websocket.close", "code": 1008})`.
- Content-type check only when `scope["type"] == "http"` and method in `{"POST", "PUT", "PATCH"}`; media type = value before `;`, stripped, lowercased; pass if `== "application/json"` or matches `^application/[^/\s]+\+json$`.
- `lifespan` scopes pass straight through. Log rejections at debug with method, path, and check name only.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.venv/bin/python -m pytest backend/tests/test_trust_boundary.py -q`
Expected: all pass. Then `./.venv/bin/ruff check backend` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add backend/app/trust.py backend/tests/test_trust_boundary.py
git commit   # "Add the backend trust-boundary middleware"
```

### Task 2: Wire the middleware into the real app and migrate test clients

**Files:**
- Modify: `backend/app/server.py:1-21` (drop `CORSMiddleware` import and docstring mention), `:176-182` (remove `app.add_middleware(CORSMiddleware, ...)`), after the `rate_limit_middleware` definition (`:224`): `app.add_middleware(TrustBoundaryMiddleware)` so it is outermost.
- Modify: `backend/tests/conftest.py` (top of module, before any fixture)
- Create: `backend/tests/api_clients.py`
- Modify: `backend/tests/test_endpoints.py:31-35` (fixture) and `:232-245` (replace `TestCORS`), `backend/tests/test_security_logging.py:38-41`, `backend/tests/test_provider_registry.py:166-168`, `backend/tests/test_smart_actions.py:161,180,278,308,343`, `backend/tests/test_notion_endpoints.py:21`, `backend/tests/test_websocket_timeout.py:26,47`
- Test: `backend/tests/test_trust_boundary.py` (append real-app tests)

**Interfaces:**
- Consumes: `TrustBoundaryMiddleware`, `active_token` (Task 1).
- Produces (in `backend/tests/api_clients.py`): `TEST_API_TOKEN: str`, `TEST_BASE_URL = "http://127.0.0.1:8765"`, `api_client(app) -> TestClient`, `async_api_client(app) -> httpx.AsyncClient` (both default to the token header and base URL).

- [ ] **Step 1: Set test env before any server import**

In `backend/tests/conftest.py`, at module top (after the `sys.path` inserts, before fixtures): set `os.environ["VOXFLOW_API_TOKEN"] = "ab" * 32` and `os.environ["VOXFLOW_TOKEN_DIR"] = tempfile.mkdtemp(prefix="voxflow-token-")`. Unconditional assignment, not `setdefault`, so a developer's shell token never leaks into tests. `api_clients.TEST_API_TOKEN` reads it back from `os.environ`.

- [ ] **Step 2: Write the failing real-app tests**

Append to `test_trust_boundary.py`:

```python
def test_real_app_rejects_typeless_post_that_used_to_succeed():
    import server
    c = TestClient(server.app, base_url=TEST_BASE_URL)
    r = c.post("/v1/cleanup", content=b'{"session_id":"s","mode":"light","input_text":"x"}',
               headers={"X-VoxFlow-Token": TEST_API_TOKEN})
    assert r.status_code == 415

def test_real_app_requires_token_and_keeps_health_open():
    import server
    c = TestClient(server.app, base_url=TEST_BASE_URL)
    assert c.get("/v1/ready").status_code == 401
    assert c.get("/v1/health").status_code == 200
    assert api_client(server.app).get("/v1/ready").status_code == 200

def test_real_app_sends_no_cors_headers():
    import server
    r = api_client(server.app).get("/v1/health")
    assert "access-control-allow-origin" not in r.headers

def test_ollama_pull_streams_through_middleware(monkeypatch):
    import server
    from api import endpoints
    monkeypatch.setattr(endpoints, "probe_ollama_available", lambda force=False: True)
    monkeypatch.setattr(endpoints, "pull_ollama_model_stream", lambda model: iter([b'{"status":"a"}\n', b'{"status":"b"}\n']))
    with api_client(server.app).stream("POST", "/v1/ollama/pull", json={"model": "m"}) as r:
        assert r.status_code == 200
        assert [line for line in r.iter_lines() if line] == ['{"status":"a"}', '{"status":"b"}']
```

Replace `TestCORS` in `test_endpoints.py` with `TestBrowserRequestsRejected.test_origin_preflight_is_403`: `OPTIONS /v1/health` with `Origin: http://127.0.0.1` → 403.

- [ ] **Step 3: Run tests to verify they fail**

Run: `./.venv/bin/python -m pytest backend/tests/test_trust_boundary.py -q -k real_app`
Expected: FAIL (the typeless POST returns 200/422, `/v1/ready` returns 200 without a token, CORS header present).

- [ ] **Step 4: Wire the middleware and migrate every client**

`server.py` changes as listed under Files. Then switch all 8 `TestClient(server.app)` and 3 `httpx.AsyncClient(... base_url="http://testserver")` constructions to `api_client(server.app)` / `async_api_client(server.app)`. `test_websocket_timeout.py` keeps `websocket_connect("/v1/events")` (the helper's default headers carry the token; confirm the Host it sends is `127.0.0.1:8765`).

- [ ] **Step 5: Run the full Python suite**

Run: `./.venv/bin/python -m pytest backend/tests -q -p no:cacheprovider`
Expected: all pass (baseline was 582 passed / 26 skipped, plus Task 1 and Task 2 tests). `./.venv/bin/ruff check backend` → exit 0.

- [ ] **Step 6: Commit**

```bash
git add backend/app/server.py backend/tests/conftest.py backend/tests/api_clients.py backend/tests/test_*.py
git commit   # "Enforce the trust boundary on the backend app"
```

### Task 3: Separate rate-limit bucket for /v1/health

**Files:**
- Modify: `backend/app/server.py:189-224` (`rate_limit_middleware`)
- Test: `backend/tests/test_endpoints.py:220-229` (`TestRateLimiting`)

**Interfaces:**
- Consumes: `_rate_limit_timestamps` (from `context`), the middleware order from Task 2.

- [ ] **Step 1: Write the failing tests**

```python
async def test_health_traffic_cannot_starve_authenticated_budget(self, client):
    for _ in range(120):
        await client.get("/v1/health")
    assert (await client.get("/v1/health")).status_code == 429
    assert (await client.get("/v1/ready")).status_code != 429

async def test_rejected_requests_never_count(self, client):
    for _ in range(130):
        r = await client.get("/v1/ready", headers={"X-VoxFlow-Token": "cd" * 32})
        assert r.status_code == 401
    assert sum(len(v) for v in _rate_limit_timestamps.values()) == 0
```

Keep the existing `test_exceeding_limit_returns_429` (health bucket still limits at 120).

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.venv/bin/python -m pytest backend/tests/test_endpoints.py -q -k RateLimiting`
Expected: `test_health_traffic_cannot_starve_authenticated_budget` FAILS (shared bucket returns 429 on `/v1/ready`). The rejected-requests test may already pass because of Task 2's ordering; that is fine, it pins the ordering.

- [ ] **Step 3: Key the bucket by path**

In `rate_limit_middleware`, use `f"health:{client}"` as the bucket key when `request.url.path == "/v1/health"`, else `client`. Everything else (lock, window, cleanup) unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.venv/bin/python -m pytest backend/tests/test_endpoints.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add backend/app/server.py backend/tests/test_endpoints.py
git commit   # "Give health checks their own rate-limit bucket"
```

### Task 4: Token file written at startup, removed at shutdown

**Files:**
- Create: `backend/app/token_file.py`
- Modify: `backend/app/server.py:164-167` (`app_lifespan`)
- Test: `backend/tests/test_token_file.py`

**Interfaces:**
- Consumes: `active_token()` (Task 1).
- Produces:
  - `token_file_path(env: Mapping[str, str] | None = None) -> Path` — `$VOXFLOW_TOKEN_DIR/backend.token`, else `~/Library/Application Support/VoxFlow/backend.token`.
  - `write_token_file(token: str, path: Path) -> tuple[int, int] | None` — returns `(st_dev, st_ino)` of the written file, or `None` after logging a warning on failure.
  - `remove_token_file(path: Path, identity: tuple[int, int]) -> bool` — unlinks only when the path's current `(st_dev, st_ino)` equals `identity`.

- [ ] **Step 1: Write the failing tests**

```python
def test_written_file_is_0600_with_exact_token(tmp_path):
    p = tmp_path / "backend.token"
    assert write_token_file("ab" * 32, p) is not None
    assert p.read_text() == "ab" * 32
    assert stat.S_IMODE(p.stat().st_mode) == 0o600

def test_missing_directory_is_created_0700(tmp_path):
    p = tmp_path / "VoxFlow" / "backend.token"
    write_token_file("ab" * 32, p)
    assert stat.S_IMODE(p.parent.stat().st_mode) == 0o700

def test_existing_directory_mode_is_untouched(tmp_path):
    tmp_path.chmod(0o755)
    write_token_file("ab" * 32, tmp_path / "backend.token")
    assert stat.S_IMODE(tmp_path.stat().st_mode) == 0o755

def test_remove_only_when_still_ours(tmp_path):
    p = tmp_path / "backend.token"
    mine = write_token_file("ab" * 32, p)
    write_token_file("cd" * 32, p)                 # successor replaced it
    assert remove_token_file(p, mine) is False and p.exists()
    theirs = (p.stat().st_dev, p.stat().st_ino)
    assert remove_token_file(p, theirs) is True and not p.exists()

def test_write_failure_returns_none(tmp_path):
    ro = tmp_path / "ro"; ro.mkdir(); ro.chmod(0o500)
    assert write_token_file("ab" * 32, ro / "backend.token") is None

def test_lifespan_writes_and_removes_token_file(monkeypatch, tmp_path):
    monkeypatch.setenv("VOXFLOW_TOKEN_DIR", str(tmp_path))
    import server
    # the real startup loads the Whisper model under the Python default backend
    monkeypatch.setattr(server, "initialize_runtime_state", lambda: None)
    with TestClient(server.app, base_url=TEST_BASE_URL):   # enters lifespan
        assert (tmp_path / "backend.token").read_text() == os.environ["VOXFLOW_API_TOKEN"]
    assert not (tmp_path / "backend.token").exists()

def test_token_file_path_honours_override():
    assert token_file_path({"VOXFLOW_TOKEN_DIR": "/x"}) == Path("/x/backend.token")
    assert token_file_path({}).parts[-3:] == ("Application Support", "VoxFlow", "backend.token")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.venv/bin/python -m pytest backend/tests/test_token_file.py -q`
Expected: `ModuleNotFoundError: No module named 'token_file'`.

- [ ] **Step 3: Implement `token_file.py` and the lifespan hook**

Write path per spec Decision 5: `os.makedirs(parent, mode=0o700)` only if absent; temp file via `os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)` with a unique name (`f".backend.token.{os.getpid()}.{secrets.token_hex(4)}"`), write, `os.fsync`, `os.replace`, then `os.stat` for the identity. `app_lifespan`: resolve `active_token()`, write before `initialize_runtime_state()`, remove after `yield`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.venv/bin/python -m pytest backend/tests/test_token_file.py backend/tests -q -p no:cacheprovider`
Expected: all pass; nothing is written under the real `~/Library/Application Support/VoxFlow` (conftest points `VOXFLOW_TOKEN_DIR` at a temp dir).

- [ ] **Step 5: Commit**

```bash
git add backend/app/token_file.py backend/app/server.py backend/tests/test_token_file.py
git commit   # "Mirror the active backend token to a 0600 file"
```

### Task 5: Scripts send the token; CLAUDE.md run docs

**Files:**
- Create: `scripts/lib/backend_token.sh`
- Modify: `scripts/doctor.sh:7,41-50`, `scripts/check_runtime_readiness.sh:14`
- Modify: `CLAUDE.md` Build & Run readiness line (`:65`) and the Environment Variables table
- Test: `backend/tests/test_backend_token_script.py`

**Interfaces:**
- Produces: bash function `voxflow_backend_token` (sourced from `scripts/lib/backend_token.sh`): prints the token from `${VOXFLOW_TOKEN_DIR:-$HOME/Library/Application Support/VoxFlow}/backend.token` with all whitespace removed, else `$VOXFLOW_API_TOKEN`, else prints nothing and returns 1. Bash 3.2 compatible (no `mapfile`, no associative arrays).

- [ ] **Step 1: Write the failing tests** (run the function through `/bin/bash`, macOS's 3.2)

```python
def run_lookup(env):
    script = f'source "{ROOT}/scripts/lib/backend_token.sh"; voxflow_backend_token'
    return subprocess.run(["/bin/bash", "-c", script], env={"PATH": "/usr/bin:/bin", **env},
                          capture_output=True, text=True)

def test_token_lookup_reads_file(tmp_path):
    (tmp_path / "backend.token").write_text("ab" * 32)
    assert run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path)}).stdout == "ab" * 32

def test_token_lookup_trims_whitespace(tmp_path):
    (tmp_path / "backend.token").write_text("ab" * 32 + "\n")
    assert run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path)}).stdout == "ab" * 32

def test_token_lookup_falls_back_to_env_then_fails(tmp_path):
    assert run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path), "VOXFLOW_API_TOKEN": "cd" * 32}).stdout == "cd" * 32
    r = run_lookup({"VOXFLOW_TOKEN_DIR": str(tmp_path)})
    assert r.returncode == 1 and r.stdout == ""
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.venv/bin/python -m pytest backend/tests/test_backend_token_script.py -q`
Expected: FAIL (`No such file or directory` for the sourced script).

- [ ] **Step 3: Implement the helper and use it in both scripts**

Both scripts source the helper via `BASH_SOURCE`-relative paths (CLAUDE.md rule), add `-H "X-VoxFlow-Token: ${TOKEN}"` when a token was found, and when none was found print: `[warn] no backend token found; start the app or scripts/run_backend.sh first (looked in <dir>/backend.token)`. Update CLAUDE.md: the readiness example becomes `curl -H "X-VoxFlow-Token: $(cat ~/Library/Application\ Support/VoxFlow/backend.token)" http://127.0.0.1:8765/v1/ready`; add table rows for `VOXFLOW_API_TOKEN` (per-launch token the app passes to the managed backend; a manual backend generates one) and `VOXFLOW_TOKEN_DIR` (token-file directory override, default `~/Library/Application Support/VoxFlow`); amend the `VOXFLOW_BACKEND_URL` row: a non-loopback manual backend now rejects requests.

- [ ] **Step 4: Run tests and syntax checks**

Run: `./.venv/bin/python -m pytest backend/tests/test_backend_token_script.py -q && /bin/bash -n scripts/doctor.sh && /bin/bash -n scripts/check_runtime_readiness.sh`
Expected: tests pass, no syntax errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/backend_token.sh scripts/doctor.sh scripts/check_runtime_readiness.sh CLAUDE.md backend/tests/test_backend_token_script.py
git commit   # "Send the backend token from the doctor and readiness scripts"
```

### Task 6: App token store, request helper, identity probe

**Files:**
- Create: `Sources/VoxFlowApp/Services/BackendAuthToken.swift`
- Modify: `Sources/VoxFlowApp/Services/BackendAPIClient.swift` (`performRequest` `:261`, `performGetRequest` `:279`, `performSmartAction` `:343`, `ollamaPull` `:369-377`, `providerTest` `:599`, `notionSearch` `:611`, `notionAppend` `:623`; add `identityProbe`)
- Test: `Tests/VoxFlowAppTests/BackendAPIClientTests.swift`, `Tests/VoxFlowAppTests/BackendAuthTokenTests.swift`

**Interfaces:**
- Produces:
  - `enum BackendAuthToken` with `static func current() -> String?`, `static func set(_ token: String?)`, `static func generate() -> String` (32 bytes from `SecRandomCopyBytes`, lowercase hex), `static func isWellFormed(_ token: String) -> Bool` (`^[0-9a-f]{64}$`), `static let headerName = "X-VoxFlow-Token"`. Storage: `OSAllocatedUnfairLock<String?>`; all members nonisolated and safe from any thread.
  - `BackendAPIClient.identityProbe(timeoutInterval: TimeInterval = 3) async throws -> String` — GET `v1/health`, returns `instance_stamp` (empty string if absent).
  - Private `BackendAPIClient.makeRequest(path: String, method: String) -> URLRequest` — base URL + token header when `BackendAuthToken.current()` is non-empty.

- [ ] **Step 1: Write the failing tests**

`BackendAuthTokenTests`: `generate()` yields well-formed and distinct values across 100 calls; `isWellFormed` rejects `"AB"*32`, 63 chars, whitespace; `set`/`current` round-trip and `set(nil)` clears.

`BackendAPIClientTests` (save/restore `BackendAuthToken` in `setUp`/`tearDown`; keep using `MockURLProtocol.expectedPath`):

```swift
func testEveryRequestBuilderAttachesToken() async throws {
    let token = String(repeating: "ab", count: 32)
    BackendAuthToken.set(token)
    var seen: [String: String?] = [:]
    func stub(_ path: String, _ body: String) {
        MockURLProtocol.expectedPath = path
        MockURLProtocol.requestHandler = { request in
            seen[path] = request.value(forHTTPHeaderField: "X-VoxFlow-Token")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }
    stub("/v1/health", #"{"instance_stamp":"s"}"#);           _ = try await BackendAPIClient.identityProbe()
    stub("/v1/cleanup", #"{"output_text":"x","mode_applied":"light","guardrail_triggered":false}"#)
    _ = try await BackendAPIClient.cleanup(sessionID: "s", mode: .light, inputText: "x", toneStyle: .neutral)
    // ... same for v1/ready, v1/smart_action, v1/providers/test, v1/notion/search, v1/notion/append, v1/ollama/pull
    XCTAssertEqual(Set(seen.keys).count, 8)
    XCTAssertTrue(seen.values.allSatisfy { $0 == token })
}

func testRequestsOmitTokenHeaderWhenNoneIsSet() async throws { /* BackendAuthToken.set(nil); header is nil on GET and POST */ }

func testIdentityProbeReadsInstanceStampWithoutToken() async throws {
    BackendAuthToken.set(nil)
    MockURLProtocol.expectedPath = "/v1/health"
    MockURLProtocol.requestHandler = { request in
        XCTAssertNil(request.value(forHTTPHeaderField: "X-VoxFlow-Token"))
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"instance_stamp":"previous-launch"}"#.utf8))
    }
    let stamp = try await BackendAPIClient.identityProbe()
    XCTAssertEqual(stamp, "previous-launch")
}

func testOllamaPullSurfacesBackendDetailOnError() async {
    // 401 with {"detail":"Missing or invalid token"} → BackendError.httpError(401, "Missing or invalid token")
}
```

Fill in the remaining stubs in `testEveryRequestBuilderAttachesToken` with minimal valid response bodies for each builder (read each builder's `Response` type for the required keys).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "BackendAPIClientTests|BackendAuthTokenTests"`
Expected: compile error, `cannot find 'BackendAuthToken' in scope`.

- [ ] **Step 3: Implement**

Create `BackendAuthToken.swift`. In `BackendAPIClient`, add `makeRequest(path:method:)` and route all seven builders through it (they keep setting their own `Content-Type` and body); add `identityProbe`; make `ollamaPull` decode the FastAPI `detail` from the error body (reuse `checkHTTPStatus`'s detail parsing) instead of the fixed "Ollama pull failed". Leave `readyProbe` in place; Task 8 removes it with its last caller.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "BackendAPIClientTests|BackendAuthTokenTests"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/BackendAuthToken.swift Sources/VoxFlowApp/Services/BackendAPIClient.swift Tests/VoxFlowAppTests/BackendAPIClientTests.swift Tests/VoxFlowAppTests/BackendAuthTokenTests.swift
git commit   # "Attach the launch token to every backend request"
```

### Task 7: Per-launch token in the process manager; identity-gated port reaping

**Files:**
- Modify: `Sources/VoxFlowApp/Services/BackendProcessManager.swift` (`instanceStamp` area `:114-120`, `init` `:246-249`, `mergedEnvironment` `:583-596`, `ensureBackendPortAvailable` `:701-735`, comment `:739-743`)
- Modify: `CLAUDE.md` "Do Not" entry about SIGTERM by port or PID file (the sentence claiming a live `/v1/health` stamp probe)
- Test: `Tests/VoxFlowAppTests/BackendProcessManagerTests.swift`

**Interfaces:**
- Consumes: `BackendAuthToken.generate()`, `BackendAuthToken.set(_:)` (Task 6).
- Produces:
  - `BackendProcessManager.apiToken: String` (`let`, generated at init, published with `BackendAuthToken.set(apiToken)` in `init`).
  - `nonisolated static func ownedListenerPIDs(_ listening: [pid_t], ownPID: pid_t, commandLine: (pid_t) -> String?) -> [pid_t]` — PIDs equal to `ownPID` whose command line passes `isVoxFlowBackendCommand`.

- [ ] **Step 1: Write the failing tests**

```swift
func testManagerPublishesWellFormedLaunchToken() {
    let manager = BackendProcessManager(runner: BackendProcessRunnerFake())
    XCTAssertTrue(BackendAuthToken.isWellFormed(manager.apiToken))
    XCTAssertEqual(BackendAuthToken.current(), manager.apiToken)
}

func testEachManagerGetsDistinctToken() {
    XCTAssertNotEqual(BackendProcessManager(runner: BackendProcessRunnerFake()).apiToken,
                      BackendProcessManager(runner: BackendProcessRunnerFake()).apiToken)
}

func testSpawnEnvironmentCarriesLaunchTokenAcrossRestart() {
    withSpawnEnvironment(backendURL: "http://127.0.0.1:9000") { runner, manager in
        manager.startIfNeeded(configuration: Self.portParityTestConfig())
        manager.restart(configuration: Self.portParityTestConfig())
        waitForRunCount(runner, 2)
        XCTAssertEqual(runner.ranProcesses.map { $0.environment?["VOXFLOW_API_TOKEN"] },
                       [manager.apiToken, manager.apiToken])
    }
}

func testOwnedListenerPIDsRequireVoxFlowCommand() {
    let chrome = { (_: pid_t) in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }
    let backend = { (_: pid_t) in "/usr/bin/python3 /x/backend/app/server.py" }
    XCTAssertEqual(BackendProcessManager.ownedListenerPIDs([5555, 6666], ownPID: 5555, commandLine: chrome), [])
    XCTAssertEqual(BackendProcessManager.ownedListenerPIDs([5555, 6666], ownPID: 5555, commandLine: backend), [5555])
    XCTAssertEqual(BackendProcessManager.ownedListenerPIDs([5555], ownPID: 5555, commandLine: { _ in nil }), [])
}

func testPortReapingRefusesReusedPIDFileEntry() {
    withSpawnEnvironment(backendURL: "http://127.0.0.1:8765") { runner, manager in
        runner.listeners = [5555]
        runner.pidFile = 5555
        runner.commandLines[5555] = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        manager.startIfNeeded(configuration: Self.portParityTestConfig())
        XCTAssertTrue(runner.terminations.isEmpty, "a reused PID-file PID must never be signalled")
    }
}
```

`lastSpawnedPID` cannot be driven through the fake (an unstarted `Process` reports pid 0), so `testOwnedListenerPIDsRequireVoxFlowCommand` is the proof that the gate is origin-independent. If `testSpawnEnvironmentCarriesLaunchTokenAcrossRestart` needs the `waitForRunCount` helper made non-private or the restart timing adjusted, follow the existing `testCrashRestartRelaunchesThroughRunnerSeamOnly` pattern.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BackendProcessManagerTests`
Expected: compile errors (`apiToken`, `ownedListenerPIDs` undefined).

- [ ] **Step 3: Implement**

Add `let apiToken = BackendAuthToken.generate()` beside `instanceStamp` and publish it in `init`; set `environment["VOXFLOW_API_TOKEN"] = apiToken` beside `VOXFLOW_INSTANCE_STAMP`. In `ensureBackendPortAvailable`, replace `pids.filter { $0 == ownPID }` with `Self.ownedListenerPIDs(pids, ownPID: ownPID, commandLine: runner.commandLine(forPID:))`, log any selected-but-refused PID as foreign, and re-gate `remaining` the same way before SIGKILL. Correct the comment at `:739-743` and the CLAUDE.md "Do Not" sentence to say `killStaleBackend` checks the command line plus the recorded stamp versus the in-process `spawnedSessionStamp` (no `/v1/health` probe).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BackendProcessManagerTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/BackendProcessManager.swift Tests/VoxFlowAppTests/BackendProcessManagerTests.swift CLAUDE.md
git commit   # "Pass a launch token to the backend and gate port reaping on identity"
```

### Task 8: Readiness wiring, token rejection, adopt-mode token file

**Files:**
- Create: `Sources/VoxFlowApp/Services/BackendTokenFile.swift`
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (init before `beginWarmupMonitoring()` `:258`; `adoptForeignBackendOverride` area `:436-438`; `reapStaleIdleListenerIfNeeded` `:446-472`; `refreshBackendReadiness` `:474-550`)
- Modify: `Sources/VoxFlowApp/Services/BackendAPIClient.swift:305-307` (remove `readyProbe`)
- Test: `Tests/VoxFlowAppTests/BackendTrustWiringTests.swift`

**Interfaces:**
- Consumes: `BackendAuthToken` (Task 6), `BackendAPIClient.identityProbe` (Task 6).
- Produces:
  - `protocol BackendTokenFileReading { func readToken() -> String? }`
  - `struct BackendTokenFile: BackendTokenFileReading` with `init(directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment)`; reads `<dir>/backend.token` (dir = `directory` ?? `$VOXFLOW_TOKEN_DIR` ?? `~/Library/Application Support/VoxFlow`), trims whitespace, returns nil if missing or not `BackendAuthToken.isWellFormed`.
  - `enum AdoptedTokenOutcome: Equatable { case notAdopting, loaded, missing }`
  - On `AppCoordinator`: `nonisolated static func explicitAdoptRequested(_ environment: [String: String]) -> Bool` (`== "1"` only, no XCTest clause); `nonisolated static func loadAdoptedBackendToken(explicitAdopt: Bool, reader: BackendTokenFileReading) -> AdoptedTokenOutcome` (sets `BackendAuthToken` to the file token on `.loaded`, to nil on `.missing`, untouched on `.notAdopting`); `nonisolated static func isTokenRejection(_ error: Error) -> Bool` (true only for `BackendError.httpError(statusCode: 401, _)`).

- [ ] **Step 1: Write the failing tests**

```swift
final class ReaderSpy: BackendTokenFileReading {
    var calls = 0; var token: String?
    func readToken() -> String? { calls += 1; return token }
}

func testNotAdoptingNeverReadsTheTokenFile() {
    BackendAuthToken.set("ab" + String(repeating: "0", count: 62))
    let spy = ReaderSpy()
    XCTAssertEqual(AppCoordinator.loadAdoptedBackendToken(explicitAdopt: false, reader: spy), .notAdopting)
    XCTAssertEqual(spy.calls, 0)
    XCTAssertEqual(BackendAuthToken.current(), "ab" + String(repeating: "0", count: 62))
}

func testAdoptLoadsOrClearsToken() {
    let spy = ReaderSpy(); spy.token = String(repeating: "cd", count: 32)
    XCTAssertEqual(AppCoordinator.loadAdoptedBackendToken(explicitAdopt: true, reader: spy), .loaded)
    XCTAssertEqual(BackendAuthToken.current(), spy.token)
    spy.token = nil
    XCTAssertEqual(AppCoordinator.loadAdoptedBackendToken(explicitAdopt: true, reader: spy), .missing)
    XCTAssertNil(BackendAuthToken.current())
}

func testExplicitAdoptIgnoresXCTest() {
    XCTAssertFalse(AppCoordinator.explicitAdoptRequested([:]))
    XCTAssertFalse(AppCoordinator.explicitAdoptRequested(["VOXFLOW_ADOPT_FOREIGN_BACKEND": "true"]))
    XCTAssertTrue(AppCoordinator.explicitAdoptRequested(["VOXFLOW_ADOPT_FOREIGN_BACKEND": "1"]))
}

func testTokenFileTrimsWhitespaceAndRejectsMalformed() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("backend.token")
    let reader = BackendTokenFile(directory: dir)
    XCTAssertNil(reader.readToken())                                   // missing
    try (String(repeating: "ab", count: 32) + "\n").write(to: file, atomically: true, encoding: .utf8)
    XCTAssertEqual(reader.readToken(), String(repeating: "ab", count: 32))
    try "not-a-token".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertNil(reader.readToken())
}

func testTokenRejectionIsRecognizedOnlyFor401() {
    XCTAssertTrue(AppCoordinator.isTokenRejection(BackendError.httpError(statusCode: 401, detail: "Missing or invalid token")))
    XCTAssertFalse(AppCoordinator.isTokenRejection(BackendError.httpError(statusCode: 403, detail: "x")))
    XCTAssertFalse(AppCoordinator.isTokenRejection(URLError(.cannotConnectToHost)))
}
```

Save and restore `BackendAuthToken` in `setUp`/`tearDown`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BackendTrustWiringTests`
Expected: compile errors (types and statics undefined).

- [ ] **Step 3: Implement and wire**

Create `BackendTokenFile.swift` (protocol, struct, outcome enum) and the three statics on `AppCoordinator` (next to `isUserCancellation`). Wiring, per spec Decisions 6 and 8:
- Init, just before `beginWarmupMonitoring()`: if `Self.explicitAdoptRequested(ProcessInfo.processInfo.environment)`, call `loadAdoptedBackendToken(explicitAdopt: true, reader: BackendTokenFile())`; on `.missing` set `state.backendReadiness.statusSummary = "Backend token file not found"`.
- `reapStaleIdleListenerIfNeeded`: take `reportedStamp` from `try await BackendAPIClient.identityProbe()` instead of `readyProbe()`; rest unchanged.
- `refreshBackendReadiness`: before `ready()`, `try? await BackendAPIClient.identityProbe()`; if it returned a stamp and `!Self.adoptForeignBackendOverride && BackendProcessManager.isForeignBackend(reportedStamp:expectedStamp:managerOwnsProcess:)`, run the existing reap block (moved, not changed) and return. Otherwise call `ready()` exactly as today. In its `catch`, first: if `Self.isTokenRejection(error)`, set `readinessIssue` and `statusSummary` to `"Backend rejected the app's token"`, and if explicit adopt is on, re-run `loadAdoptedBackendToken`; then return. Other errors keep the existing branches.
- Remove `BackendAPIClient.readyProbe` (no callers remain).

The wiring inside `AppCoordinator` stays untested by unit tests, consistent with the codebase (tests never construct `AppCoordinator`); the statics and the unchanged pure deciders carry the behaviour.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "BackendTrustWiringTests|BackendAPIClientTests|BackendProcessManagerTests"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/BackendTokenFile.swift Sources/VoxFlowApp/AppCoordinator.swift Sources/VoxFlowApp/Services/BackendAPIClient.swift Tests/VoxFlowAppTests/BackendTrustWiringTests.swift
git commit   # "Probe backend identity via health and handle token rejection"
```

### Task 9: Full verification, changelog, manual acceptance

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]`, add a `### Security` subsection)

- [ ] **Step 1: Changelog entry**

Under `## [Unreleased]`, add `### Security` with one bullet: the backend now accepts only the VoxFlow app (per-launch token) and refuses browser-originated, wrong-host, and non-JSON requests, closing a blind cross-site request path and DNS rebinding; scripts read the token from `~/Library/Application Support/VoxFlow/backend.token`.

- [ ] **Step 2: Run every automated check**

Run: `swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests" | tail -2; ./.venv/bin/python -m pytest backend/tests -q -p no:cacheprovider | tail -1; ./.venv/bin/ruff check backend`
Expected: Swift 0 failures; Python all passed; ruff exit 0.

- [ ] **Step 3: Build and install the app, then run the scripted checks**

Run: `./scripts/install_app_bundle.sh && open ~/Applications/VoxFlow.app`, wait for readiness, then:
- `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8765/v1/ready` → `401`
- `curl -s -o /dev/null -w "%{http_code}" -H "X-VoxFlow-Token: $(cat ~/Library/Application\ Support/VoxFlow/backend.token)" http://127.0.0.1:8765/v1/ready` → `200`
- `curl -s -o /dev/null -w "%{http_code}" -H "Origin: https://example.com" http://127.0.0.1:8765/v1/health` → `403`
- `curl -s -o /dev/null -w "%{http_code}" -H "Sec-Fetch-Mode: no-cors" -H "Sec-Fetch-Site: cross-site" http://127.0.0.1:8765/v1/health` → `403` (what a browser's `no-cors` fetch sends; it carries no `Origin`)
- `curl -s -o /dev/null -w "%{http_code}" -H "Host: evil.example:8765" http://127.0.0.1:8765/v1/health` → `400`
- `./scripts/doctor.sh` → reports the backend reachable

- [ ] **Step 4: Hand the human-only checks to the user**

Ask the user to confirm on the installed app: a dictation inserts text; a cockpit smart action returns; Settings → provider Test responds; an Ollama model pull shows progress. Record the outcome in the PR description, including anything not verified.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md
git commit   # "Record the backend trust boundary in the changelog"
```

# Local backend trust boundary — design spec

Source: the 2026-10-26 multi-model review (Opus lead, Gemini 4 Argon, Sonnet
5.5; triage R-01 and R-18, findings verified against the code). Approach A was
chosen by the user over headers-only (C) and a Unix domain socket (B).
Revision 2 folds in an adversarial Gemini 4 Argon review of revision 1; its
claims were re-checked against the code before inclusion.

## Measured facts driving this work

- The backend on `127.0.0.1:8765` authenticates nothing. `server.py` installs
  `CORSMiddleware` (origins `http://127.0.0.1`, `http://localhost`) and an
  HTTP rate limiter; there is no Host check, no Origin check, no token.
- CORS limits what a browser page can read, not what it can send. Probe
  against FastAPI 0.116.1 in the project venv: a JSON body with
  `Content-Type: text/plain` gets 422, but the same body with no Content-Type
  gets 200. A page can send exactly that with no preflight:
  `fetch(url, {method: "POST", mode: "no-cors", body: new Blob([json])})`.
  So blind cross-site requests run their side effects today.
- Browsers omit `Origin` on `no-cors` GET and HEAD requests (and on `<img>`
  loads), but send `Sec-Fetch-Site` / `Sec-Fetch-Mode` on every request in
  current Chrome, Firefox, and Safari. URLSession and curl send neither.
- DNS rebinding (attacker hostname re-resolving to 127.0.0.1) makes requests
  same-origin, so responses become readable too. `/v1/ready` returns
  `python_executable` and `models_dir`, which contain the home directory.
- Reachable effects without consent: `/v1/smart_action` and `/v1/cleanup` run
  the configured provider chain, so a cloud provider's Keychain-sourced API key
  (passed to the backend as `VOXFLOW_PROVIDER_KEY_*`) can be spent;
  `/v1/ollama/pull` downloads arbitrary models with no size bound.
- The rate limiter keys on client IP, which is always 127.0.0.1, so any local
  caller shares the app's 120 req/min bucket; `@app.middleware("http")` and
  CORS do not run for WebSocket scopes.
- Every app request goes through `BackendAPIClient` (seven `URLRequest`
  builders on one static `URLSession`). All POST bodies are JSON (audio travels
  as base64). Nothing in the app opens the `/v1/events` WebSocket or calls
  `BackendAPIClient.health()`.
- The app's stale/foreign-backend detection reads `instance_stamp` from
  `/v1/ready`, not `/v1/health`: `AppCoordinator.reapStaleIdleListenerIfNeeded`
  (via `BackendAPIClient.readyProbe`) and `refreshBackendReadiness` (via
  `ready()`). A token on `/v1/ready` alone would make a previous launch's
  backend answer 401, which the first path treats as "nothing listening" and
  the second as a generic failure, so the squatter would never be replaced.
- `BackendProcessManager.instanceStamp` is generated once per app launch, not
  per spawn. `AppCoordinator.adoptForeignBackendOverride` is true when
  `VOXFLOW_ADOPT_FOREIGN_BACKEND=1` OR when running under XCTest.
- Both `scripts/doctor.sh` and `scripts/check_runtime_readiness.sh` curl
  `/v1/ready`. Python tests reach the app through 8 `TestClient(...)` and 3
  `httpx.AsyncClient`/`ASGITransport` constructions, all with the default
  `testserver` host; `test_endpoints.py::TestCORS` asserts CORS headers.
- `ensureBackendPortAvailable` (`BackendProcessManager.swift:701-735`) signals
  `lastSpawnedPID ?? readPIDFile()` without the `isVoxFlowBackendCommand`
  identity gate the other two kill paths use. CLAUDE.md and a comment near
  `BackendProcessManager.swift:741` say the stale reaper probes a live
  `/v1/health` stamp; the code compares only the in-process
  `spawnedSessionStamp`.
- On this machine a same-user process could not read another process's
  environment with `ps eww`, so a token passed in the child environment is a
  real barrier against ordinary local processes, not only browsers.

## Goals

1. No web page can cause a backend side effect, read a backend response, or
   exhaust the app's rate-limit budget, with or without DNS rebinding.
2. A local process that does not hold the token cannot call any route except
   `/v1/health`.
3. Rejected and unauthenticated callers cannot consume the app's rate-limit
   budget or ML semaphore.
4. Developer workflows keep working: a manually started backend, the
   adopt-foreign-backend mode, and the doctor/readiness scripts.

## Non-goals

- Defending against same-user code that can read the token file, attach a
  debugger, or read the Keychain. That attacker already has the user's data.
- A Unix-domain-socket transport (approach B).
- Two backends running at once on different ports. The PID file is already a
  single global file; the token file follows it.
- Serving a backend on a non-loopback host. The managed spawn already refuses
  one; a manual non-loopback backend will now reject requests (documented).
- Trimming `/v1/health`. It can include a local model path in
  `active_stt_model` when the Python Whisper backend uses a local folder, but
  after this change only same-machine, non-browser callers can read it, and
  those can read the filesystem directly.
- Backward compatibility with older app builds; the app and backend ship in
  one bundle.

## Decisions

### Backend middleware

1. One pure-ASGI middleware, `TrustBoundaryMiddleware` in a new
   `backend/app/trust.py`, registered last so it is outermost and runs before
   the rate limiter and routing. Pure ASGI (not `@app.middleware("http")` or
   `BaseHTTPMiddleware`) so it covers WebSocket scopes and does not buffer
   streaming responses. `lifespan` scopes pass through. `CORSMiddleware` is
   removed: the app's URLSession never sends `Origin`.
2. Checks, in order, on every `http` and `websocket` scope, reading raw
   `scope["headers"]` (a list of byte pairs, never collapsed into a dict):
   1. Host: exactly one `Host` header, whose value fully matches
      (case-insensitive) `^(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?$`.
      Zero headers (HTTP/1.0), more than one, or any other value: 400
      `{"detail": "Invalid host"}`. The port is not compared, so custom ports
      work; a rebinding request carries the attacker's hostname.
   2. Browser markers: any `Origin`, `Sec-Fetch-Site`, or `Sec-Fetch-Mode`
      header, with any value: 403 `{"detail": "Browser requests are not
      accepted"}`. This catches `no-cors` GETs and image loads, which carry
      no `Origin`.
   3. Token: every path except exactly `/v1/health` must carry exactly one
      `X-VoxFlow-Token` header whose raw bytes equal the active token's ASCII
      bytes under `hmac.compare_digest` (no decoding, so arbitrary bytes cannot
      raise). Missing, duplicated, or wrong: 401 `{"detail": "Missing or
      invalid token"}`. A custom header rather than `Authorization`, because
      Apple lists `Authorization` among headers URLSession may manage itself,
      and browsers cannot attach custom headers to a WebSocket handshake.
   4. Content type (HTTP only; WebSocket scopes have no method): `POST`, `PUT`,
      and `PATCH` must carry exactly one `Content-Type` whose media type (the
      part before any `;`, lowercased, trimmed) is `application/json` or
      `application/<subtype>+json`. Otherwise 415 `{"detail": "Content-Type
      must be application/json"}`. This alone closes the typeless-Blob request
      even if the token ever leaked.
   WebSocket rejections: the middleware awaits the `websocket.connect` message,
   then sends `websocket.close` with code 1008 before accept, which a live
   client sees as an HTTP 403 handshake failure (Starlette's TestClient raises
   `WebSocketDisconnect(1008)`).
3. Rate limiting: requests rejected by the middleware never reach the limiter.
   ~~Requests to `/v1/health` are counted in their own bucket
   (`"health:" + client host`) so even a valid-host, non-browser caller polling
   it cannot starve the app's authenticated budget.~~ SUPERSEDED (final
   re-review N1): `/v1/health` is exempt from the limiter instead.
   /v1/health is exempt from the limiter: the app's per-request identity probe depends on it (final re-review N1).
4. Token resolution, in `trust.py`, lazily on first use and cached:
   - `VOXFLOW_API_TOKEN`, if set, must be exactly 64 lowercase hex characters;
     anything else logs an error and raises `SystemExit` at startup.
   - Otherwise generate `secrets.token_hex(32)`. Never log the token.
5. Token file, written during lifespan startup (so it is never written at
   import time or by tests that skip lifespan):
   - Path: `<dir>/backend.token`, where `<dir>` is `VOXFLOW_TOKEN_DIR` if set,
     else `~/Library/Application Support/VoxFlow`. Create `<dir>` with mode
     0700 only if it does not exist; never change an existing directory.
   - Write: `os.open` a uniquely named temp file in `<dir>` with
     `O_WRONLY | O_CREAT | O_EXCL` and mode 0600, write, fsync, `os.replace`
     onto `backend.token`. Record the resulting `(st_dev, st_ino)`.
   - Shutdown: unlink only if the path's current `(st_dev, st_ino)` matches
     the recorded pair, so a successor's file is never removed. A SIGKILLed
     backend's leftover is overwritten by the next start.
   - A write failure logs a warning and does not stop the backend (the managed
     app already holds the token; only scripts and adopt mode lose access).

### Identity probe

6. `/v1/health` stays token-free and becomes the app's identity probe (it
   already echoes `instance_stamp`). A new
   `BackendAPIClient.identityProbe(timeoutInterval:)` reads it. Existing
   decision logic is unchanged; only the stamp's source moves:
   - `reapStaleIdleListenerIfNeeded` takes the stamp from `identityProbe`
     instead of `readyProbe`, then applies `shouldTerminateIdleListener`
     exactly as today.
   - `refreshBackendReadiness` calls `identityProbe` first. If
     `!adoptForeignBackendOverride` and `isForeignBackend(reportedStamp:,
     expectedStamp:, managerOwnsProcess:)` (unchanged, including its
     `managerOwnsProcess` short-circuit) says foreign, it reaps as today.
     Otherwise, including adopt mode, it calls `ready()` for readiness.
   - `readyProbe` is removed if it has no other caller.

### App token lifecycle

7. One token per app launch, matching `instanceStamp`'s lifetime:
   `BackendProcessManager` generates it at init with `SecRandomCopyBytes`
   (32 bytes, lowercase hex) and publishes it to a new `BackendAuthToken`
   (an `OSAllocatedUnfairLock`-guarded value readable from the nonisolated
   `BackendAPIClient` statics) before any spawn or request can happen. Every
   spawn in that launch, including crash restarts, passes it as
   `VOXFLOW_API_TOKEN` next to `VOXFLOW_INSTANCE_STAMP`. A previous launch's
   backend holds a different token and a different stamp, and is reaped by
   the identity probe.
8. Adopt mode keys on the explicit environment variable only
   (`VOXFLOW_ADOPT_FOREIGN_BACKEND == "1"`), never on the XCTest half of
   `adoptForeignBackendOverride`, so `swift test` can never read a developer's
   live token file. In adopt mode the app reads `backend.token` through an
   injected `BackendTokenFileReading` seam: at startup, and again after any
   401 (a restarted manual backend rotates its token). If the file is missing
   or unreadable, readiness reports "Backend token file not found" and
   requests carry no token header.
9. `BackendAPIClient` builds every request through one helper,
   `makeRequest(path:method:)`, which sets the base URL and attaches
   `X-VoxFlow-Token` when `BackendAuthToken` holds a value (omitted when it is
   empty). The seven current builders switch to it: `performRequest`,
   `performGetRequest`, `performSmartAction`, `ollamaPull`, providers test,
   Notion search, Notion append. `ollamaPull` also decodes FastAPI's `detail`
   on a non-2xx status instead of the fixed "Ollama pull failed".

### Related hardening (R-18)

10. `ensureBackendPortAvailable` gates the PID it selects
    (`lastSpawnedPID ?? readPIDFile()`) on `isVoxFlowBackendCommand` via the
    existing `BackendProcessRunning.commandLine` seam, before the SIGTERM and
    again before the SIGKILL follow-up. A PID that fails the gate is logged
    and treated as foreign, like the other two kill paths.
11. CLAUDE.md's "Do Not" entry and the comment near
    `BackendProcessManager.swift:741` are corrected to describe what
    `killStaleBackend` actually checks (command line, plus the recorded stamp
    versus the in-process `spawnedSessionStamp`), not a `/v1/health` probe.

### Scripts and docs

12. `doctor.sh` and `check_runtime_readiness.sh` send `X-VoxFlow-Token` read
    from `${VOXFLOW_TOKEN_DIR:-$HOME/Library/Application Support/VoxFlow}/backend.token`,
    falling back to `$VOXFLOW_API_TOKEN`, and print a clear hint when neither
    exists. CLAUDE.md's readiness `curl` line shows the header. The
    environment table gains `VOXFLOW_API_TOKEN` and `VOXFLOW_TOKEN_DIR`, and
    notes that a non-loopback manual backend is unsupported.

## Error handling

- A 401 seen by the app normally means a previous launch's backend is still
  on the port. The identity probe (Decision 6) reaps it by stamp before
  token-protected calls matter; if a 401 still reaches readiness polling, it
  reports "Backend rejected the app's token" and, in adopt mode, re-reads the
  token file (Decision 8), rather than showing a generic failure.
- Middleware rejections are logged at debug level with method, path, and the
  failed check, never the presented token.

## Testing

Python, new `backend/tests/test_trust_boundary.py`, against the real app:
- Host: `evil.example:8765`, `localhost.` (trailing dot), `127.0.0.2`,
  unbracketed `::1:8765`, a missing Host, and two Host headers all get 400 on
  an authenticated route and on `/v1/health`; `LOCALHOST:8765`, `[::1]`, and
  `[::1]:8765` pass.
- `Origin` (including `null`), `Sec-Fetch-Site`, or `Sec-Fetch-Mode` present:
  403, even with a valid token, on GET and POST.
- Token: missing, wrong, non-ASCII bytes (`\xff`), and duplicated headers get
  401 (never 500); the correct token gets 200; `/v1/health` needs none, and
  `/v1/health/x` is not exempt.
- Content type: none, `text/plain`, and bare `+json` get 415 with a valid
  token; `application/json; charset=utf-8` and `application/vnd.x+json` pass.
- WebSocket `/v1/events`: no token, wrong token, or an `Origin` header raise
  `WebSocketDisconnect(1008)`; a valid token connects.
- Rejected requests add nothing to `_rate_limit_timestamps`; `/v1/health`
  traffic does not reduce the authenticated bucket.
- Token resolution: a valid env token is used; a malformed one raises
  `SystemExit`; an absent one yields 64 hex characters.
- Token file (in `tmp_path` via `VOXFLOW_TOKEN_DIR`): written 0600 with the
  active token during lifespan; an existing directory's mode is untouched;
  removed on shutdown; left in place when another process replaced it.
- Migration: `backend/tests/conftest.py` sets `VOXFLOW_API_TOKEN` and
  `VOXFLOW_TOKEN_DIR` at module import (before any `import server`) and
  provides `api_client()` / `async_api_client()` helpers using
  `base_url="http://127.0.0.1:8765"` and the token header. All 8 `TestClient`
  and 3 `AsyncClient` sites (`test_endpoints.py`, `test_provider_registry.py`, `test_security_logging.py`) switch to them. `TestCORS` is replaced by the
  Origin-rejection tests (CORS is removed by design). The full suite then
  passes.

Swift (fakes only, no real processes or network):
- `BackendAPIClient` attaches `X-VoxFlow-Token` on GET, JSON POST, the
  streaming Ollama pull, and the Notion/provider builders when a token is set,
  and omits it when empty (MockURLProtocol asserts both).
- `BackendProcessManager` publishes a 64-hex token at init, passes the same
  value as `VOXFLOW_API_TOKEN` on every spawn including a restart (fake runner
  captures the environment), and a second manager instance gets a different
  token.
- `identityProbe` reads `instance_stamp` from `/v1/health` without a token;
  the idle and running decision paths take their stamp from it (pure deciders
  unchanged), and adopt mode still calls `ready()`.
- Adopt mode: reads the token file through the fake `BackendTokenFileReading`
  only when the explicit env flag is set; re-reads after a 401; a missing file
  yields the documented status. Under XCTest without the env flag, the reader
  is never called.
- `ensureBackendPortAvailable` refuses to signal a selected PID whose command
  line is not a VoxFlow backend, for both `lastSpawnedPID` and PID-file
  origins, mirroring `testKillStaleBackendRefusesReusedNonVoxFlowPID`.

Manual acceptance (installed app): dictation, a cockpit smart action, the
Settings provider test, and an Ollama model pull all work; `doctor.sh`
reports the backend reachable; `curl` to `/v1/ready` without the header gets
401 and with the token file's value gets 200; a browser page fetching
`http://127.0.0.1:8765/v1/health` in `no-cors` mode is refused (403).

## Acceptance criteria

- All four checks enforced on HTTP and WebSocket, verified by the tests above.
- Full Swift and Python suites green; ruff clean.
- The manual acceptance list passes on the installed app.
- CLAUDE.md, both scripts, the comment near `BackendProcessManager.swift:741`,
  and the environment table match the code.

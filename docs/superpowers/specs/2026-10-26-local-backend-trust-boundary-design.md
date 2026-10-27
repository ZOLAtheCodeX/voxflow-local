# Local backend trust boundary — design spec

Source: the 2026-10-26 multi-model review (Opus lead, Gemini 4 Argon, Sonnet
5.5; triage R-01 and R-18, findings verified against the code). Approach A was
chosen by the user over headers-only (C) and a Unix domain socket (B).

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
  as base64). Nothing in the app opens the `/v1/events` WebSocket.
- `ensureBackendPortAvailable` (`BackendProcessManager.swift:701-735`) is the
  one kill path that signals a PID-file PID without the
  `isVoxFlowBackendCommand` identity gate. CLAUDE.md says `killStaleBackend`
  probes a live `/v1/health` stamp; the code compares only the in-process
  `spawnedSessionStamp`.
- The app's stale/foreign-backend detection reads `instance_stamp` from
  `/v1/ready`, not `/v1/health`: `AppCoordinator.reapStaleIdleListenerIfNeeded`
  (via `BackendAPIClient.readyProbe`) and `refreshBackendReadiness` (via
  `ready()`). A token on `/v1/ready` would make a previous launch's backend
  answer 401, which the first path treats as "nothing listening" and the
  second as a generic failure, so the squatter would never be replaced.
- On this machine a same-user process could not read another process's
  environment with `ps eww`, so a token passed in the child environment is a
  real barrier against ordinary local processes, not only browsers.

## Goals

1. No web page can cause a backend side effect or read a backend response,
   with or without DNS rebinding.
2. A local process that does not hold the per-launch token cannot call any
   route except `/v1/health`.
3. Rejected callers cannot consume the app's rate-limit budget or ML semaphore.
4. Developer workflows keep working: a manually started backend, the
   adopt-foreign-backend mode, and the doctor/readiness scripts.

## Non-goals

- Defending against same-user code that can read the token file, attach a
  debugger, or read the Keychain. That attacker already has the user's data.
- A Unix-domain-socket transport (approach B). Revisit if the TCP surface
  causes further issues.
- Changing what `/v1/ready` returns; it is token-protected after this change.
- Backward compatibility with older app builds; the app and backend ship in
  one bundle.

## Decisions

1. One pure-ASGI middleware, `TrustBoundaryMiddleware` in a new
   `backend/app/trust.py`, registered last so it is outermost and runs before
   the rate limiter and routing. Pure ASGI (not `@app.middleware("http")`) so
   it also covers WebSocket scopes. `CORSMiddleware` is removed: the app's
   URLSession never sends `Origin`, so no CORS response is needed.
2. Checks, in order, for every `http` and `websocket` scope:
   1. Host: the hostname part of the `Host` header (port stripped, brackets
      removed) must be `127.0.0.1`, `localhost`, or `::1`. Otherwise 400
      `{"detail": "Invalid host"}`. The port is not checked, so custom ports
      keep working; a rebinding request carries the attacker's hostname.
   2. Origin: any request carrying an `Origin` header, including `null`, gets
      403 `{"detail": "Browser requests are not accepted"}`.
   3. Token: every path except `/v1/health` must carry `X-VoxFlow-Token`
      equal to the active token, compared with `hmac.compare_digest` on bytes.
      Missing or wrong: 401 `{"detail": "Missing or invalid token"}`. A custom
      header rather than `Authorization`, because Apple lists `Authorization`
      among headers URLSession may manage itself, and browsers cannot attach
      custom headers to a WebSocket handshake.
   4. Content type: `POST`, `PUT`, and `PATCH` must send `Content-Type` whose
      media type is `application/json` or ends in `+json`. Otherwise 415
      `{"detail": "Content-Type must be application/json"}`. This alone closes
      the typeless-Blob request even if a token ever leaked.
   WebSocket rejections close before accept (ASGI `websocket.close`, code
   1008), which clients see as an HTTP 403 handshake failure.
3. `/v1/health` stays token-free and becomes the app's identity probe. It
   already echoes `instance_stamp`, still passes the Host and Origin checks,
   and returns no filesystem paths (true today). A new
   `BackendAPIClient.identityProbe(timeoutInterval:)` reads it, and both
   identity checks switch to it: `reapStaleIdleListenerIfNeeded` (replacing
   `readyProbe`) and the R4.7 foreign check in `refreshBackendReadiness`,
   which now probes identity first and calls `ready()` only for a backend it
   owns. The pure deciders `shouldTerminateIdleListener` and
   `isForeignBackend` are unchanged. `readyProbe` is removed if it has no
   other caller.
4. Token lifecycle (backend):
   - If `VOXFLOW_API_TOKEN` is set, use it. Refuse to start (`SystemExit`,
     logged) if it is shorter than 32 characters.
   - Otherwise generate `secrets.token_hex(32)` and log that a generated token
     was written to the token file (never log the token).
   - In both cases write the active token to
     `~/Library/Application Support/VoxFlow/backend-<port>.token`: directory
     created with mode 0700 if missing, file written to a temp name with mode
     0600 then `os.replace`d. `VOXFLOW_TOKEN_DIR` overrides the directory for
     tests. On lifespan shutdown, delete the file only if it still holds this
     process's token.
5. Token lifecycle (app):
   - A new `BackendAuthToken` holds the current token behind an
     `OSAllocatedUnfairLock` (read from nonisolated `BackendAPIClient` statics).
   - Managed spawn: `BackendProcessManager` generates 32 random bytes with
     `SecRandomCopyBytes`, hex-encodes them, sets `VOXFLOW_API_TOKEN` in the
     child environment alongside `VOXFLOW_INSTANCE_STAMP`, and stores the
     value in `BackendAuthToken` before the first request. A new token per
     spawn, including crash restarts.
   - Adopt-foreign-backend mode (`VOXFLOW_ADOPT_FOREIGN_BACKEND=1`): read the
     token file for the resolved port; if absent or unreadable, surface
     "Backend token file not found" in the readiness status instead of
     retrying silently.
6. `BackendAPIClient` builds every request through one helper,
   `makeRequest(path:method:)`, which sets the base URL and the
   `X-VoxFlow-Token` header from `BackendAuthToken`. The seven current
   builders (`performRequest`, `performGetRequest`, `performSmartAction`,
   `ollamaPull`, providers test, Notion search, Notion append) switch to it.
7. Related hardening (same process boundary, R-18):
   - `ensureBackendPortAvailable` gates its SIGTERM/SIGKILL of the PID-file
     PID on `isVoxFlowBackendCommand` via the existing
     `BackendProcessRunning.commandLine` seam, like the other two kill paths.
   - CLAUDE.md's "Do Not" entry is corrected to describe what
     `killStaleBackend` actually checks (command line plus the recorded stamp
     versus the in-process `spawnedSessionStamp`), not a `/v1/health` probe.
8. Scripts and docs: `check_runtime_readiness.sh` and CLAUDE.md's readiness
   `curl` line read the token file and send `X-VoxFlow-Token`. `doctor.sh`
   keeps using `/v1/health` unchanged. CLAUDE.md's environment table gains
   `VOXFLOW_API_TOKEN` and `VOXFLOW_TOKEN_DIR`.

## Error handling

- A 401 seen by the app means it is talking to a backend that is not the one
  it spawned (normally a previous launch's backend still on the port). The
  identity probe on `/v1/health` (Decision 3) detects and reaps that case by
  stamp before any token-protected call; if a 401 still reaches readiness
  polling, it reports "Backend rejected the app's token" and re-runs the
  identity probe, rather than showing a generic failure.
- Token file write failure at backend startup is logged as a warning and does
  not stop the backend (the managed app already holds the token); only the
  scripts and adopt mode lose access.
- Middleware rejections are logged at debug level with method, path, and the
  failed check, never the presented token.

## Testing

Python (new `backend/tests/test_trust_boundary.py`, TestClient against the
real app with `VOXFLOW_API_TOKEN` and `VOXFLOW_TOKEN_DIR` set by fixture):
- Host `evil.example:8765` gets 400 on an authenticated route and on `/v1/health`.
- Any `Origin` header (including `null`) gets 403, with a valid token.
- Missing token and wrong token get 401; correct token gets 200.
- `/v1/health` without a token gets 200 with a valid host.
- A POST with no Content-Type and a POST with `text/plain` get 415 even with a
  valid token; `application/json` passes.
- WebSocket `/v1/events`: no token, wrong token, or an `Origin` header are
  refused before accept; a valid token connects.
- Rejected requests do not add entries to `_rate_limit_timestamps`.
- Token file: written with mode 0600 in a 0700 directory, contains the active
  token, removed on shutdown, left alone if another token overwrote it.
- A `VOXFLOW_API_TOKEN` shorter than 32 characters refuses to start.
- Existing suites: the 8 `TestClient(...)` constructions (3 files) move to a
  shared conftest helper that sets `base_url="http://127.0.0.1:8765"` and the
  token header, so the full suite keeps passing unchanged in behaviour.

Swift (fakes only, no real processes or network):
- `BackendAPIClient` attaches `X-VoxFlow-Token` on GET, JSON POST, the
  streaming Ollama pull, and the Notion/provider builders (MockURLProtocol
  asserts the header).
- `BackendProcessManager` passes a 64-hex-character `VOXFLOW_API_TOKEN` in the
  spawn environment (fake runner captures it), stores the same value in
  `BackendAuthToken`, and generates a different one on the next spawn.
- Adopt mode reads the token file for the configured port; a missing file
  yields the documented status.
- `identityProbe` reads `instance_stamp` from `/v1/health` and succeeds
  without a token; a previous launch's backend (different stamp, 401 on
  `/v1/ready`) is classified foreign through the identity probe in both idle
  and running modes, and a 401 from `ready()` triggers a fresh identity probe.
- `ensureBackendPortAvailable` refuses to signal a PID whose command line is
  not a VoxFlow backend (fake runner), mirroring
  `testKillStaleBackendRefusesReusedNonVoxFlowPID`.

Manual acceptance (installed app): dictation, cockpit smart action, Settings
provider test, and Ollama model pull all work; `curl` to `/v1/ready` without
the header gets 401; with the token file's value gets 200.

## Acceptance criteria

- All four checks enforced on HTTP and WebSocket, verified by the tests above.
- Full Swift and Python suites green; ruff clean.
- The manual acceptance list passes on the installed app.
- CLAUDE.md, the readiness script, and the environment table match the code.

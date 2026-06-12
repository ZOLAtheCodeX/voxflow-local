# Stale-backend hardening (pre-R6 cleanup)

Date: 2026-06-12. Status: approved by user (approach options chosen via Q&A); implementation same day.

## Incident that motivated this

Port 8765 was found served by an orphaned backend (ppid 1) running code from the
deleted `.claude/worktrees/r4-gui` checkout: started 10:04, the app launched 11:15,
found a healthy port, and adopted it. The squatter had no instance stamp, predated
R5.2 (still served `/v1/tts`), and answered cockpit smart-action traffic with stale
code. It also pinned polish to `gemma4:e4b-mlx` where this 16 GB machine should
auto-select `e2b-mlx`. Third stale-backend incident in this project's history.

## Two defects

**A. The R4.7 foreign-stamp check never runs in the app's default mode.**
`isForeignBackend` (the verdict) is correct and unit-tested, but it executes only
inside `refreshBackendReadiness()` after the `/v1/ready` fetch, and that branch is
gated: in WhisperKit dictation/prompt mode `backendShouldRun` is false, so the idle
early-return fires first and the app never probes the port. Identity checking was
coupled to health polling; health polling is legitimately skipped when the backend
is "optional". Meanwhile smart actions still POST to whatever listens on 8765.

**B. Cockpit smart actions depend on the backend, but nothing ensures one runs.**
`workflowNeedsBackend` covers meeting/translation only. In dictation mode the app
spawns no backend at launch (verified live: kill the squatter, relaunch, port stays
empty), so on a clean machine every cockpit chip fails with a connection error.
The squatter was silently masking this.

## Approved design

### A. Launch-time identity probe (chosen over continuous polling / per-request checks)

Hoist an identity-only probe into the idle branch of `refreshBackendReadiness()`,
before the early return. That branch runs exactly once per warmup, including the
app-start warmup that loads WhisperKit, so this IS the launch-time probe with no
new entry points.

- Probe `/v1/ready` with the client's existing short timeout.
  - No listener (connection refused / timeout): keep today's "Backend idle" path.
  - Listener answers with this instance's stamp: healthy, fall through unchanged.
  - Listener answers with a missing or mismatched stamp: log a warning, surface
    "Stale backend on port 8765 removed" in `statusSummary`, and call
    `terminateForeignListenerAsync()`. Do not spawn a replacement unless
    `backendShouldRun` is true (mirrors the existing R4.7 branch).
- Decision logic lives in a pure static function next to `isForeignBackend`
  (probe outcome + expected stamp + manager ownership + escape hatch -> verdict),
  so the truth table is unit-testable without a network seam on the singleton.
- Dev escape hatch: `VOXFLOW_ADOPT_FOREIGN_BACKEND=1` in the app's environment
  skips termination (for intentionally running `run_backend.sh` against a dev app).
  Default is kill-on-sight: an unstamped listener on our port is presumed stale.
- This also reaps the app's OWN orphans from previous runs (a fresh launch has a
  fresh stamp, so yesterday's child fails the check). Both prior incidents were
  exactly this class.

### B. Cockpit counts as backend-needing (chosen over start-on-failure / fail-loudly)

- `AppState.backendShouldRun` gains `|| cockpitVisible`.
- `CockpitCoordinator` fires a new `onCockpitOpened` callback (same pattern as
  `onProtocolTriggered` / `onHandoffRequested`); `AppCoordinator` wires it to
  `scheduleRuntimeWarmupIfNeeded()`, which now passes its guard because
  `backendShouldRun` is true, spawning + warmup-polling via the existing machinery.
- While the cockpit is open, the existing in-poll foreign check is active again,
  so a mid-session squatter is caught exactly when traffic flows to it.
- After cockpit close the backend lingers. Accepted: it is our stamped child;
  the next launch probe reaps it if orphaned. No new stop path.

## Test plan (TDD, red first)

1. `AppState.backendShouldRun` truth table including `cockpitVisible`.
2. `CockpitCoordinator` open path fires `onCockpitOpened` (close does not).
3. Static idle-probe verdict truth table: {no listener, ours, foreign-missing,
   foreign-mismatched} x {escape hatch on/off} -> {idle, healthy, terminate}.
4. Full Swift + Python suites stay green.

Live verification gates (after rebuild + reinstall + relaunch):
- Fresh launch in dictation mode: port empty, no spawn (unchanged behavior).
- Open cockpit: backend spawns, `/v1/ready` echoes the instance stamp, polish
  auto-selects `gemma4:e2b-mlx` on this machine, smart action round-trips.
- Plant a stamp-less listener on 8765, relaunch app: listener is terminated at
  startup and the status line reports it.

## Out of scope

- Killing the backend child on app quit (orphan prevention at the source): the
  launch probe makes orphans self-healing; revisit only if lingering processes
  bother in practice.
- Point-of-use stamp verification on every API request (rejected as heavier than
  the failure class warrants).
- `/v1/health` build-hash comparison from the old incident notes: the per-launch
  instance stamp supersedes it.

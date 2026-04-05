#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_APP="${HOME}/Applications/VoxFlow.app"
APP_BIN="${DEST_APP}/Contents/MacOS/VoxFlowLocal"
BACKEND_PATTERN='server.py|uvicorn|backend/app/server.py|Resources/backend/app/server.py|VoxFlow.app/Contents/Resources/venv/bin/python'
WINDOW_CHECK=1
REINSTALL=0

usage() {
  cat <<EOF
Usage: $0 [--reinstall] [--skip-window-check]

Runs a live runtime smoke test against the installed VoxFlow app using the
automation URL scheme.

Options:
  --reinstall          Rebuild and reinstall the app before running the smoke test.
  --skip-window-check  Skip the setup-window verification step.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reinstall)
      REINSTALL=1
      shift
      ;;
    --skip-window-check)
      WINDOW_CHECK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[smoke] unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

log() {
  echo "[smoke] $*"
}

app_running() {
  pgrep -fl VoxFlowLocal >/dev/null 2>&1
}

backend_running() {
  pgrep -fl "${BACKEND_PATTERN}" >/dev/null 2>&1
}

wait_until() {
  local description="$1"
  local timeout_seconds="$2"
  shift 2
  local started_at
  started_at="$(date +%s)"

  while true; do
    if "$@"; then
      return 0
    fi

    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      log "timed out waiting for ${description}"
      return 1
    fi

    sleep 1
  done
}

open_location() {
  local location="$1"
  osascript -e "open location \"${location}\"" >/dev/null
}

setup_window_present() {
  local windows
  windows="$(osascript -e 'tell application "System Events" to tell process "VoxFlowLocal" to get name of every window' 2>/dev/null || true)"
  grep -Fq "VoxFlow Setup" <<<"${windows}"
}

cleanup() {
  osascript -e 'tell application "VoxFlow" to quit' >/dev/null 2>&1 || true
  "${ROOT_DIR}/scripts/stop_voxflow.sh" >/dev/null 2>&1 || true
}

trap cleanup EXIT

if [[ ${REINSTALL} -eq 1 ]]; then
  log "reinstalling latest bundle"
  "${ROOT_DIR}/scripts/build_app_bundle.sh"
  "${ROOT_DIR}/scripts/install_app_bundle.sh"
fi

if [[ ! -x "${APP_BIN}" ]]; then
  log "installed app missing: ${APP_BIN}"
  log "run ${ROOT_DIR}/scripts/install_app_bundle.sh first, or pass --reinstall"
  exit 1
fi

log "stopping any existing VoxFlow processes"
cleanup

log "launching installed app"
open "${DEST_APP}"

wait_until "app launch" 10 app_running
log "app launched"

sleep 2
if backend_running; then
  log "backend should be idle after cold launch, but a backend process is running"
  pgrep -fl "${BACKEND_PATTERN}" || true
  exit 1
fi
log "cold launch kept backend idle"

log "switching to meeting workflow via automation URL"
open_location "voxflow://workflow/meeting?enable=1"

wait_until "backend start" 20 backend_running
wait_until "backend readiness" 30 "${ROOT_DIR}/scripts/check_runtime_readiness.sh" >/dev/null 2>&1 || {
  log "backend never became ready"
  "${ROOT_DIR}/scripts/check_runtime_readiness.sh" || true
  exit 1
}
log "meeting workflow started backend successfully"

log "switching back to dictation workflow"
open_location "voxflow://workflow/dictation"

wait_until "backend stop" 20 bash -lc "! pgrep -fl '${BACKEND_PATTERN}' >/dev/null 2>&1"
log "dictation workflow returned backend to idle"

if [[ ${WINDOW_CHECK} -eq 1 ]]; then
  log "opening setup window via automation URL"
  open_location "voxflow://window/setup"
  wait_until "setup window" 10 setup_window_present
  log "setup window opened successfully"
else
  log "window check skipped"
fi

log "quitting app"
osascript -e 'tell application "VoxFlow" to quit' >/dev/null

wait_until "app shutdown" 10 bash -lc "! pgrep -fl VoxFlowLocal >/dev/null 2>&1"
wait_until "backend shutdown" 10 bash -lc "! pgrep -fl '${BACKEND_PATTERN}' >/dev/null 2>&1"
log "runtime smoke test passed"

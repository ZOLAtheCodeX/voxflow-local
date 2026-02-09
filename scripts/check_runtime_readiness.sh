#!/usr/bin/env bash
set -euo pipefail

BACKEND_URL="${VOXFLOW_BACKEND_URL:-http://127.0.0.1:8765}"
HEALTH_URL="${BACKEND_URL%/}/v1/health"

if ! command -v curl >/dev/null 2>&1; then
  echo "[readiness] curl is required"
  exit 1
fi

echo "[readiness] checking ${HEALTH_URL}"
HEALTH_JSON="$(curl -fsS "${HEALTH_URL}" || true)"
if [[ -z "${HEALTH_JSON}" ]]; then
  echo "[readiness] backend not reachable. start it with:"
  echo "  ./scripts/run_backend.sh"
  exit 1
fi

echo "[readiness] health payload: ${HEALTH_JSON}"

if ! grep -q '"service_status":"ok"' <<<"${HEALTH_JSON}"; then
  echo "[readiness] service_status is not ok"
  exit 1
fi

if grep -q '"model_loaded":"true"' <<<"${HEALTH_JSON}"; then
  echo "[readiness] active STT model is loaded"
else
  echo "[readiness] active STT model is NOT loaded"
  echo "[readiness] install/download models and verify VOXFLOW_MODELS_DIR / backend env"
  exit 2
fi

ACTIVE_MODEL="$(sed -n 's/.*"active_stt_model":"\([^"]*\)".*/\1/p' <<<"${HEALTH_JSON}")"
if [[ -n "${ACTIVE_MODEL}" ]]; then
  echo "[readiness] active STT model: ${ACTIVE_MODEL}"
fi

if grep -q '"stt_fallback_active":"true"' <<<"${HEALTH_JSON}"; then
  echo "[readiness] Voxtral fallback is active (using fallback STT model)"
fi

if grep -q '"voxtral_primary_skipped":"true"' <<<"${HEALTH_JSON}"; then
  echo "[readiness] Voxtral primary model load is skipped (safe mode)"
fi

if grep -q '"offline_mode":"true"' <<<"${HEALTH_JSON}"; then
  echo "[readiness] offline mode: enabled"
else
  echo "[readiness] offline mode: disabled"
fi

echo "[readiness] backend ready"

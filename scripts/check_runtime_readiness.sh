#!/usr/bin/env bash
set -euo pipefail

BACKEND_URL="${VOXFLOW_BACKEND_URL:-http://127.0.0.1:8765}"
READINESS_URL="${BACKEND_URL%/}/v1/ready"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/backend_token.sh
source "${ROOT_DIR}/scripts/lib/backend_token.sh"

if ! command -v curl >/dev/null 2>&1; then
  echo "[readiness] curl is required"
  exit 1
fi

echo "[readiness] checking ${READINESS_URL}"
AUTH_HEADER=""
if BACKEND_TOKEN="$(voxflow_backend_token)"; then
  AUTH_HEADER="X-VoxFlow-Token: ${BACKEND_TOKEN}"
else
  echo "[warn] no backend token found; start the app or scripts/run_backend.sh first (looked in $(voxflow_token_dir)/backend.token)"
fi
TMP_BODY="$(mktemp)"
# The header goes in over stdin (-H @-) so the token never appears in argv,
# and only when a token was found.
if [[ -n "${AUTH_HEADER}" ]]; then
  HTTP_CODE="$(printf '%s\n' "${AUTH_HEADER}" | curl -sS -H @- -o "${TMP_BODY}" -w "%{http_code}" "${READINESS_URL}" || true)"
else
  HTTP_CODE="$(curl -sS -o "${TMP_BODY}" -w "%{http_code}" "${READINESS_URL}" || true)"
fi
READINESS_JSON="$(cat "${TMP_BODY}" 2>/dev/null || true)"
rm -f "${TMP_BODY}"

if [[ -z "${HTTP_CODE}" || "${HTTP_CODE}" == "000" ]]; then
  echo "[readiness] backend not reachable. start it with:"
  echo "  ./scripts/run_backend.sh"
  exit 1
fi

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "[readiness] readiness endpoint returned HTTP ${HTTP_CODE}"
  if [[ "${HTTP_CODE}" == "404" ]]; then
    echo "[readiness] stale or wrong backend may be bound to :8765 (missing /v1/ready)"
  fi
  if [[ -n "${READINESS_JSON}" ]]; then
    echo "[readiness] response body: ${READINESS_JSON}"
  fi
  exit 1
fi

echo "[readiness] readiness payload: ${READINESS_JSON}"

if ! grep -q '"service_status":"ok"' <<<"${READINESS_JSON}"; then
  echo "[readiness] service_status is not ok"
  exit 1
fi

if grep -q '"active_stt_model_loaded":true' <<<"${READINESS_JSON}"; then
  echo "[readiness] active STT model is loaded"
else
  echo "[readiness] active STT model is NOT loaded"
  echo "[readiness] install/download models and verify VOXFLOW_MODELS_DIR / backend env"
  exit 2
fi

ACTIVE_MODEL="$(sed -n 's/.*"active_stt_model":"\([^"]*\)".*/\1/p' <<<"${READINESS_JSON}")"
if [[ -n "${ACTIVE_MODEL}" ]]; then
  echo "[readiness] active STT model: ${ACTIVE_MODEL}"
fi

if grep -q '"stt_fallback_active":true' <<<"${READINESS_JSON}"; then
  echo "[readiness] STT fallback is active (using fallback STT model)"
fi

if grep -q '"offline_mode":true' <<<"${READINESS_JSON}"; then
  echo "[readiness] offline mode: enabled"
else
  echo "[readiness] offline mode: disabled"
fi

if grep -q '"issues":\[[^]]\+\]' <<<"${READINESS_JSON}"; then
  echo "[readiness] issues were reported by /v1/ready"
fi

echo "[readiness] backend ready"

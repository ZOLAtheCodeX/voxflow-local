#!/usr/bin/env bash
# Sourced helper: locate the VoxFlow backend token. Bash 3.2 compatible.
# Never prints diagnostics and never aborts the caller under `set -e`/`set -u`;
# callers handle the "not found" return code themselves.

# Directory holding backend.token (the backend mirrors its active token there).
voxflow_token_dir() {
  printf '%s' "${VOXFLOW_TOKEN_DIR:-${HOME:-}/Library/Application Support/VoxFlow}"
}

# Prints the token (all whitespace removed) and returns 0.
# Order: <token dir>/backend.token, then $VOXFLOW_API_TOKEN.
# Prints nothing and returns 1 when neither yields a non-empty value.
voxflow_backend_token() {
  local token_file token=""
  token_file="$(voxflow_token_dir)/backend.token"
  if [[ -f "${token_file}" && -r "${token_file}" ]]; then
    token="$(tr -d '[:space:]' < "${token_file}" 2>/dev/null || true)"
  fi
  if [[ -z "${token}" ]]; then
    token="$(printf '%s' "${VOXFLOW_API_TOKEN:-}" | tr -d '[:space:]')"
  fi
  if [[ -z "${token}" ]]; then
    return 1
  fi
  printf '%s' "${token}"
}

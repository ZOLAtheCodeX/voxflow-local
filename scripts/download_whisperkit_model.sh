#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="${VOXFLOW_MODELS_DIR:-$PROJECT_ROOT/models}"

MODEL_REPO="argmaxinc/whisperkit-coreml"
MODEL_NAME="${1:-openai_whisper-small.en}"
TARGET_DIR="$MODELS_DIR/whisperkit-coreml__${MODEL_NAME}"

echo "=== WhisperKit Model Download ==="
echo "Model:  $MODEL_NAME"
echo "Repo:   $MODEL_REPO"
echo "Target: $TARGET_DIR"
echo ""

if [[ -d "$TARGET_DIR" ]] && [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
    echo "Model already exists at $TARGET_DIR"
    echo "To re-download, remove the directory first:"
    echo "  rm -rf \"$TARGET_DIR\""
    exit 0
fi

mkdir -p "$TARGET_DIR"

# Resolve a working huggingface-cli (needs 'download' subcommand)
HF_CLI=""
if [[ -x "$PROJECT_ROOT/.venv/bin/huggingface-cli" ]]; then
    HF_CLI="$PROJECT_ROOT/.venv/bin/huggingface-cli"
elif command -v huggingface-cli &>/dev/null; then
    HF_CLI="huggingface-cli"
fi

if [[ -z "$HF_CLI" ]]; then
    echo "ERROR: huggingface-cli not found."
    echo "Install it: pip install huggingface-hub"
    echo "Or bootstrap the backend: ./scripts/bootstrap_backend.sh"
    exit 1
fi

# Verify it supports 'download'
if ! "$HF_CLI" download --help &>/dev/null; then
    echo "ERROR: huggingface-cli found but too old (no 'download' subcommand)."
    echo "Upgrade: pip install --upgrade huggingface-hub"
    exit 1
fi

echo "Using: $HF_CLI"
"$HF_CLI" download "$MODEL_REPO" \
    --include "${MODEL_NAME}/*" \
    --local-dir "$MODELS_DIR/whisperkit-coreml-download" \
    --local-dir-use-symlinks False

# Move the model subfolder to target
if [[ -d "$MODELS_DIR/whisperkit-coreml-download/${MODEL_NAME}" ]]; then
    mv "$MODELS_DIR/whisperkit-coreml-download/${MODEL_NAME}"/* "$TARGET_DIR/"
    rm -rf "$MODELS_DIR/whisperkit-coreml-download"
    echo ""
    echo "Download complete: $TARGET_DIR"
    echo "Contents:"
    ls -lh "$TARGET_DIR"
else
    echo "ERROR: Expected model directory not found after download"
    rm -rf "$MODELS_DIR/whisperkit-coreml-download"
    exit 1
fi

echo ""
echo "Done. Set VOXFLOW_STT_BACKEND=whisperKit and restart VoxFlow."

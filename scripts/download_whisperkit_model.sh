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

# Try huggingface-cli first (fastest, handles LFS correctly)
if command -v huggingface-cli &>/dev/null; then
    echo "Using huggingface-cli..."
    huggingface-cli download "$MODEL_REPO" \
        --include "${MODEL_NAME}/*" \
        --local-dir "$MODELS_DIR/whisperkit-coreml-download" \
        --local-dir-use-symlinks false

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

# Fallback: try venv's huggingface-cli
elif [[ -x "$PROJECT_ROOT/.venv/bin/huggingface-cli" ]]; then
    echo "Using venv huggingface-cli..."
    "$PROJECT_ROOT/.venv/bin/huggingface-cli" download "$MODEL_REPO" \
        --include "${MODEL_NAME}/*" \
        --local-dir "$MODELS_DIR/whisperkit-coreml-download" \
        --local-dir-use-symlinks false

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

else
    echo "ERROR: huggingface-cli not found."
    echo "Install it: pip install huggingface-hub"
    echo "Or bootstrap the backend: ./scripts/bootstrap_backend.sh"
    exit 1
fi

echo ""
echo "Done. Set VOXFLOW_STT_BACKEND=whisperKit and restart VoxFlow."

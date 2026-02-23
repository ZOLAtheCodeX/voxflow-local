#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path

from huggingface_hub import snapshot_download


def main() -> None:
    parser = argparse.ArgumentParser(description="Download local models for VoxFlow.")
    parser.add_argument("--cache-dir", default="./models", help="Local cache directory for model snapshots")
    parser.add_argument("--stt-model", default="openai/whisper-small")
    parser.add_argument("--whisper-model", default="openai/whisper-small")
    parser.add_argument("--polish-model", default="google/flan-t5-small")
    parser.add_argument("--translate-model", default="google/translategemma-4b-it")
    parser.add_argument(
        "--skip-translate",
        action="store_true",
        help="Skip TranslateGemma download (useful if access is gated or for faster setup).",
    )
    args = parser.parse_args()

    cache_dir = Path(args.cache_dir).resolve()
    cache_dir.mkdir(parents=True, exist_ok=True)

    model_ids = [args.stt_model, args.whisper_model, args.polish_model]
    if not args.skip_translate:
        model_ids.append(args.translate_model)

    for model_id in model_ids:
        local_dir = cache_dir / model_id.replace("/", "__")
        if local_dir.is_dir() and any(local_dir.iterdir()):
            print(f"Skipping {model_id} (already present)")
            continue
        print(f"Downloading {model_id}...")
        snapshot_download(repo_id=model_id, local_dir=str(local_dir))

    print("Done.")
    print("Set these env vars before running app/backend:")
    print(f"VOXFLOW_MODELS_DIR={cache_dir}")


if __name__ == "__main__":
    main()

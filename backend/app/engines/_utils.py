"""Shared engine helpers: model path resolution and torch device selection.

Private to the engines/ package. Other layers should import via the public
``engines`` re-exports if they need these.
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger("voxflow")


def resolve_model_ref(model_id: str) -> str:
    models_dir = os.environ.get("VOXFLOW_MODELS_DIR")
    if not models_dir:
        return model_id

    candidate = os.path.join(models_dir, model_id.replace("/", "__"))
    return candidate if os.path.isdir(candidate) else model_id


def preferred_torch_device() -> str | int:
    try:
        import torch

        if bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available()):
            return "mps"
    except Exception as exc:
        logger.debug("MPS detection failed: %s", exc)
    return -1

"""ML / heuristic engines used by VoxFlow.

Each engine wraps a single model or technique and exposes a small, stable
surface to the routing layer. Engines never import from routing/ or api/
to keep the dependency graph acyclic.
"""

from ._utils import preferred_torch_device, resolve_model_ref
from .polish import PolishEngine
from .prompt_framing import PromptFramingEngine
from .results import STTExecutionResult
from .translate import TranslateEngine
from .whisper import OpenAIAudioClient, WhisperEngine

__all__ = [
    "OpenAIAudioClient",
    "PolishEngine",
    "PromptFramingEngine",
    "STTExecutionResult",
    "TranslateEngine",
    "WhisperEngine",
    "preferred_torch_device",
    "resolve_model_ref",
]

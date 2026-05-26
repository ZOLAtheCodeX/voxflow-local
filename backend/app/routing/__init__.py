"""Provider routing — selects between local engines and the private cloud API,
and gates private-API operations through the consent token + privacy policy.

The ProviderRouter is the orchestration hub; PrivateAPIClient wraps the cloud
chat endpoint with the same operation surface (cleanup / translate /
meeting_summary) as the local engines so the router can swap them
transparently.
"""

from .private_api import PrivateAPIClient, PrivateAPIPolicy
from .provider import ProviderRouter, ResolvedProviderInput
from .utils import (
    coerce_string_list,
    extract_json_object,
    is_placeholder_text,
    normalize_provider_mode,
    normalize_stt_backend,
)

__all__ = [
    "PrivateAPIClient",
    "PrivateAPIPolicy",
    "ProviderRouter",
    "ResolvedProviderInput",
    "coerce_string_list",
    "extract_json_object",
    "is_placeholder_text",
    "normalize_provider_mode",
    "normalize_stt_backend",
]

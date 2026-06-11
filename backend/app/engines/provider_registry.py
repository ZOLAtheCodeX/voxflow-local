"""BYOM provider registry: specs, config loading, and chain resolution (R3).

``providers.json`` (app-managed, written by the Swift Settings UI; env var
``VOXFLOW_PROVIDERS_CONFIG`` overrides the path for dev) declares the
available text-LLM providers and the per-task fallback chains:

    {
      "version": 1,
      "providers": [
        {"id": "ollama", "kind": "ollama"},
        {"id": "lmstudio", "kind": "openai_compat",
         "base_url": "http://localhost:1234", "model": "qwen3:8b"},
        {"id": "claude", "kind": "anthropic",
         "model": "claude-haiku-4-5-20251001",
         "api_key_env": "VOXFLOW_PROVIDER_KEY_CLAUDE"}
      ],
      "chains": {"polish": ["lmstudio", "ollama"], "smart_action": ["claude", "ollama"]}
    }

API keys never live in this file: ``api_key_env`` names an environment
variable the Swift app populates at backend launch from the Keychain
(same transient pattern as the Notion PAT).

Config loading FAILS SOFT: unknown kinds are skipped (forward
compatibility), malformed files fall back to the builtin default
(Ollama-only), and chain entries referencing dropped providers are pruned.
The regex cleanup floor is NOT part of any chain — PolishEngine appends it
unconditionally; a chain can only ever degrade to local regex, never to
nothing.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

logger = logging.getLogger("voxflow")

KNOWN_KINDS = ("ollama", "openai_compat", "openai", "anthropic")
DEFAULT_TASKS = ("polish", "smart_action")

_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]"}


def is_local_url(base_url: str | None) -> bool:
    """True when the provider endpoint stays on this machine.

    None (e.g. the Anthropic default endpoint) is treated as cloud — the
    redaction gate fails toward privacy.
    """
    if not base_url:
        return False
    try:
        host = urlparse(base_url).hostname or ""
    except ValueError:
        return False
    return host in _LOCAL_HOSTS


@dataclass(frozen=True)
class ProviderSpec:
    id: str
    kind: str
    base_url: str | None = None
    model: str | None = None
    api_key_env: str | None = None
    timeout: float = 30.0

    @property
    def api_key(self) -> str:
        if not self.api_key_env:
            return ""
        return os.environ.get(self.api_key_env, "").strip()

    @property
    def is_cloud(self) -> bool:
        if self.kind == "ollama":
            # Default Ollama endpoint is localhost; explicit base_url decides.
            return not is_local_url(self.base_url or "http://localhost:11434")
        if self.kind == "openai_compat":
            return not is_local_url(self.base_url)
        # openai / anthropic default to their cloud endpoints.
        return not is_local_url(self.base_url)


@dataclass
class ProviderConfig:
    providers: list[ProviderSpec] = field(default_factory=list)
    chains: dict[str, list[str]] = field(default_factory=dict)


def _default_config() -> ProviderConfig:
    return ProviderConfig(
        providers=[ProviderSpec(id="ollama", kind="ollama")],
        chains={task: ["ollama"] for task in DEFAULT_TASKS},
    )


def default_config_path() -> Path:
    override = os.environ.get("VOXFLOW_PROVIDERS_CONFIG", "").strip()
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "VoxFlow" / "providers.json"


def load_provider_config(path: Path | None = None) -> ProviderConfig:
    """Load providers.json, failing soft to the builtin Ollama-only default."""
    path = path or default_config_path()
    default = _default_config()
    if not path.exists():
        return default

    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        logger.warning("providers.json unreadable (%s) — using builtin default", exc)
        return default

    specs: list[ProviderSpec] = []
    for entry in raw.get("providers", []):
        if not isinstance(entry, dict):
            continue
        kind = str(entry.get("kind", "")).strip().lower()
        provider_id = str(entry.get("id", "")).strip()
        if not provider_id:
            continue
        if kind not in KNOWN_KINDS:
            logger.warning("providers.json: unknown kind %r for id %r — skipped", kind, provider_id)
            continue
        timeout_raw = entry.get("timeout", 30.0)
        try:
            timeout = max(1.0, float(timeout_raw))
        except (TypeError, ValueError):
            timeout = 30.0
        specs.append(ProviderSpec(
            id=provider_id,
            kind=kind,
            base_url=(str(entry["base_url"]).strip() or None) if entry.get("base_url") else None,
            model=(str(entry["model"]).strip() or None) if entry.get("model") else None,
            api_key_env=(str(entry["api_key_env"]).strip() or None) if entry.get("api_key_env") else None,
            timeout=timeout,
        ))

    if not specs:
        logger.warning("providers.json declared no usable providers — using builtin default")
        return default

    known_ids = {s.id for s in specs}
    chains: dict[str, list[str]] = {}
    raw_chains = raw.get("chains", {}) if isinstance(raw.get("chains", {}), dict) else {}
    for task in DEFAULT_TASKS:
        entries = raw_chains.get(task, [])
        pruned = [str(e) for e in entries if str(e) in known_ids] if isinstance(entries, list) else []
        if not pruned:
            # Sensible default: ollama if declared, else the first provider.
            pruned = ["ollama"] if "ollama" in known_ids else [specs[0].id]
        chains[task] = pruned

    return ProviderConfig(providers=specs, chains=chains)


class ProviderRegistry:
    """Maps provider ids to constructed (cached) TextLLMBackend instances."""

    def __init__(self, config: ProviderConfig) -> None:
        self._config = config
        self._specs = {s.id: s for s in config.providers}
        self._backends: dict[str, object] = {}

    @property
    def config(self) -> ProviderConfig:
        return self._config

    def spec(self, provider_id: str) -> ProviderSpec:
        return self._specs[provider_id]

    def is_cloud(self, provider_id: str) -> bool:
        return self._specs[provider_id].is_cloud

    def backend(self, provider_id: str):
        if provider_id in self._backends:
            return self._backends[provider_id]
        spec = self._specs[provider_id]  # KeyError on unknown id is intentional
        backend = self._construct(spec)
        self._backends[provider_id] = backend
        return backend

    def chain(self, task: str) -> list[tuple[ProviderSpec, object]]:
        """Resolved (spec, backend) pairs for a task, in fallback order."""
        ids = self._config.chains.get(task) or self._config.chains.get("polish") or []
        if not ids and self._config.providers:
            ids = [self._config.providers[0].id]
        return [(self.spec(pid), self.backend(pid)) for pid in ids]

    def _construct(self, spec: ProviderSpec):
        from .llm_backend import (
            AnthropicBackend,
            OllamaBackend,
            OpenAIBackend,
            OpenAICompatBackend,
        )

        if spec.kind == "ollama":
            return OllamaBackend(
                base_url=spec.base_url,
                model=spec.model,
                timeout=spec.timeout,
            )
        if spec.kind == "openai_compat":
            return OpenAICompatBackend(
                base_url=spec.base_url or "http://localhost:1234",
                model=spec.model or "",
                api_key=spec.api_key,
                timeout=spec.timeout,
            )
        if spec.kind == "openai":
            return OpenAIBackend(
                model=spec.model or "gpt-4o-mini",
                api_key=spec.api_key,
                base_url=spec.base_url,
                timeout=spec.timeout,
            )
        if spec.kind == "anthropic":
            return AnthropicBackend(
                model=spec.model or "claude-haiku-4-5-20251001",
                api_key=spec.api_key,
                base_url=spec.base_url,
                timeout=spec.timeout,
            )
        raise KeyError(f"Unknown provider kind: {spec.kind}")

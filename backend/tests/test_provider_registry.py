"""Tests for the BYOM provider registry, specs, and config loading (R3.1/R3.6)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from engines.provider_registry import (  # noqa: E402
    ProviderConfig,
    ProviderRegistry,
    ProviderSpec,
    is_local_url,
    load_provider_config,
)


class TestIsLocalUrl:
    def test_localhost_variants_are_local(self):
        assert is_local_url("http://localhost:11434") is True
        assert is_local_url("http://127.0.0.1:1234") is True
        assert is_local_url("http://[::1]:8080") is True

    def test_remote_hosts_are_not_local(self):
        assert is_local_url("https://api.openai.com") is False
        assert is_local_url("https://api.anthropic.com") is False
        assert is_local_url("http://192.168.1.50:11434") is False

    def test_none_is_treated_as_cloud(self):
        # No base_url (e.g. the anthropic default) -> assume cloud.
        assert is_local_url(None) is False


class TestLoadProviderConfig:
    def test_missing_file_yields_builtin_default(self, tmp_path):
        config = load_provider_config(tmp_path / "nope.json")
        assert [s.id for s in config.providers] == ["ollama"]
        assert config.chains["polish"] == ["ollama"]
        assert config.chains["smart_action"] == ["ollama"]

    def test_valid_file_parses_providers_and_chains(self, tmp_path):
        path = tmp_path / "providers.json"
        path.write_text(json.dumps({
            "version": 1,
            "providers": [
                {"id": "ollama", "kind": "ollama"},
                {"id": "lmstudio", "kind": "openai_compat", "base_url": "http://localhost:1234", "model": "qwen"},
                {"id": "claude", "kind": "anthropic", "model": "claude-haiku-4-5-20251001", "api_key_env": "VOXFLOW_PROVIDER_KEY_CLAUDE"},
            ],
            "chains": {"polish": ["lmstudio", "ollama"], "smart_action": ["claude", "ollama"]},
        }))
        config = load_provider_config(path)
        assert [s.id for s in config.providers] == ["ollama", "lmstudio", "claude"]
        assert config.chains["polish"] == ["lmstudio", "ollama"]
        assert config.chains["smart_action"] == ["claude", "ollama"]

    def test_unknown_kind_skipped_with_remaining_kept(self, tmp_path):
        path = tmp_path / "providers.json"
        path.write_text(json.dumps({
            "version": 1,
            "providers": [
                {"id": "future", "kind": "quantum"},
                {"id": "ollama", "kind": "ollama"},
            ],
            "chains": {"polish": ["future", "ollama"]},
        }))
        config = load_provider_config(path)
        assert [s.id for s in config.providers] == ["ollama"]
        # Chain references to dropped providers are pruned.
        assert config.chains["polish"] == ["ollama"]

    def test_malformed_json_falls_back_to_default(self, tmp_path):
        path = tmp_path / "providers.json"
        path.write_text("{not json")
        config = load_provider_config(path)
        assert [s.id for s in config.providers] == ["ollama"]

    def test_empty_chain_falls_back_to_default_chain(self, tmp_path):
        path = tmp_path / "providers.json"
        path.write_text(json.dumps({
            "version": 1,
            "providers": [{"id": "ollama", "kind": "ollama"}],
            "chains": {"polish": []},
        }))
        config = load_provider_config(path)
        assert config.chains["polish"] == ["ollama"]


class TestProviderRegistry:
    def _config(self) -> ProviderConfig:
        return ProviderConfig(
            providers=[
                ProviderSpec(id="ollama", kind="ollama"),
                ProviderSpec(id="lmstudio", kind="openai_compat", base_url="http://localhost:1234", model="qwen"),
                ProviderSpec(id="claude", kind="anthropic", model="claude-haiku-4-5-20251001"),
            ],
            chains={"polish": ["lmstudio", "ollama"], "smart_action": ["claude", "ollama"]},
        )

    def test_backend_construction_by_kind(self):
        registry = ProviderRegistry(self._config())
        assert registry.backend("ollama").name == "ollama"
        assert registry.backend("lmstudio").name == "openai_compat"
        assert registry.backend("claude").name == "anthropic"

    def test_backend_instances_are_cached(self):
        registry = ProviderRegistry(self._config())
        assert registry.backend("ollama") is registry.backend("ollama")

    def test_unknown_provider_id_raises(self):
        registry = ProviderRegistry(self._config())
        with pytest.raises(KeyError):
            registry.backend("nope")

    def test_chain_resolution_with_specs(self):
        registry = ProviderRegistry(self._config())
        chain = registry.chain("polish")
        assert [spec.id for spec, _backend in chain] == ["lmstudio", "ollama"]

    def test_unknown_task_falls_back_to_polish_chain(self):
        registry = ProviderRegistry(self._config())
        chain = registry.chain("never_heard_of_it")
        assert [spec.id for spec, _ in chain] == ["lmstudio", "ollama"]

    def test_cloud_detection(self):
        registry = ProviderRegistry(self._config())
        assert registry.is_cloud("ollama") is False        # default localhost
        assert registry.is_cloud("lmstudio") is False      # localhost base_url
        assert registry.is_cloud("claude") is True         # cloud API

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


SCHEMA_VERSION_CURRENT = 1
SCHEMA_VERSION_MIN = 0


@dataclass(frozen=True)
class Settings:
    host: str = os.getenv("ORANGE_SIDECAR_HOST", "127.0.0.1")
    port: int = int(os.getenv("ORANGE_SIDECAR_PORT", "7789"))
    provider: str = os.getenv("ORANGE_PROVIDER", "anthropic")
    model_simple: str = os.getenv("ORANGE_MODEL_SIMPLE", "claude-3-5-haiku-latest")
    model_complex: str = os.getenv("ORANGE_MODEL_COMPLEX", "claude-3-5-sonnet-latest")
    enable_remote_llm: bool = os.getenv("ORANGE_ENABLE_REMOTE_LLM", "1") == "1"
    anthropic_api_base: str = os.getenv("ANTHROPIC_API_BASE", "https://api.anthropic.com")
    anthropic_validate_timeout_seconds: float = float(os.getenv("ORANGE_ANTHROPIC_VALIDATE_TIMEOUT_SECONDS", "20"))
    anthropic_plan_timeout_seconds: float = float(os.getenv("ORANGE_ANTHROPIC_PLAN_TIMEOUT_SECONDS", "60"))
    safety_strictness: str = os.getenv("ORANGE_SAFETY_STRICTNESS", "strict")
    model_overrides_raw: str = os.getenv("ORANGE_MODEL_OVERRIDES", "")

    @property
    def repo_root(self) -> Path:
        return Path(__file__).resolve().parents[2]

    @property
    def vendor_macos_use(self) -> Path:
        return self.repo_root / "vendor" / "macos-use"

    @property
    def model_overrides(self) -> dict[str, str]:
        """
        Parse per-app model overrides from ORANGE_MODEL_OVERRIDES.
        """
        result: dict[str, str] = {}
        for part in self.model_overrides_raw.split(","):
            item = part.strip()
            if not item or ":" not in item:
                continue
            app, model = item.split(":", 1)
            app_key = app.strip().lower()
            model_value = model.strip()
            if app_key and model_value:
                result[app_key] = model_value
        return result

    @property
    def provider_api_key_env(self) -> str:
        return "ANTHROPIC_API_KEY"

    def provider_api_key(self) -> str | None:
        value = os.getenv(self.provider_api_key_env, "").strip()
        return value or None


settings = Settings()

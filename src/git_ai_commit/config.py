"""Ghost-text commit assistant: configuration.

Precedence (ADR-0010): environment variable > TOML config file >
built-in default. Env prefix ``GIT_AI_``.

The daemon reads full config; the worker reads only what it needs
(socket path, timeout); the Zsh plugin reads a few shell-side values.
The worker intentionally favors stdlib-only so it stays lightweight and
fast inside the pty.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:  # Python 3.10 backport
    import tomli as tomllib  # type: ignore[no-redef]

DEFAULT_CONFIG_PATH = Path("~/.config/git-ai-commit/config.toml").expanduser()
ENV_PREFIX = "GIT_AI_"
# XDG_RUNTIME_DIR is per-user and permissions-restricted; fall back to /tmp
# with a uid suffix so the socket path is not guessable/collidable.
_default_socket = os.environ.get(
    "XDG_RUNTIME_DIR", f"/tmp/git-ai-commit-{os.getuid()}"
)
DEFAULT_SOCKET_PATH = str(Path(_default_socket) / "daemon.sock")


def _to_bool(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on")


def _to_int(value: str) -> int:
    return int(value)


@dataclass
class Config:
    # Backend / model (ADR-0004)
    model_path: str = ""
    llama_url: str = "http://127.0.0.1:8080/v1/completions"
    context_size: int = 4096
    parallel_slots: int = 4
    threads: int = 0  # 0 => auto (nproc)

    # Inference tuning
    max_tokens: int = 48
    temperature: float = 0.2
    stop: list[str] = field(default_factory=lambda: ["\n"])
    diff_max_chars: int = 4000
    diff_cache_ttl: float = 300.0

    # IPC / transport (ADR-0002, ADR-0005)
    socket_path: str = DEFAULT_SOCKET_PATH
    timeout_seconds: float = 15.0

    # Behavior (ADR-0006, ADR-0010)
    debounce_ms: int = 250
    trigger: str = "space"  # "space" (default) | "keystroke" | "manual"

    # Zsh-side display
    highlight_style: str = "fg=244"

    def http_timeout(self) -> float:
        return self.timeout_seconds

    def debounce_seconds(self) -> float:
        return self.debounce_ms / 1000.0


def load_config(
    env: dict[str, str] | None = None,
    config_path: Path | None = None,
) -> Config:
    """Load config with env > TOML > defaults precedence (ADR-0010).

    ``env`` is injectable for tests; defaults to ``os.environ``.
    """
    env = os.environ if env is None else env
    cfg = Config()

    # 1. defaults loaded, then TOML file overlays
    path = config_path if config_path is not None else DEFAULT_CONFIG_PATH
    if path and path.exists():
        try:
            with open(path, "rb") as fh:
                data = tomllib.load(fh)
            cfg = _apply_toml(cfg, data)
        except (tomllib.TOMLDecodeError, OSError):
            # A malformed config file should not crash the daemon; warn
            # and fall back to defaults + env.
            print(
                f"git-ai-commit: could not parse config {path}; using defaults",
                file=sys.stderr,
            )

    # 2. env vars override everything
    cfg = _apply_env(cfg, env)
    return cfg


def _apply_toml(cfg: Config, data: dict) -> Config:
    main = data.get("git-ai-commit", data)  # allow optional [tool.git-ai-commit]
    base = data.get("daemon", {})
    for src in (base, main):
        for key, value in src.items():
            if not hasattr(cfg, key):
                continue
            if key == "stop":
                cfg.stop = [str(v) for v in value]
            else:
                current = getattr(cfg, key)
                if isinstance(current, bool):
                    setattr(cfg, key, bool(value))
                elif isinstance(current, int):
                    setattr(cfg, key, int(value))
                elif isinstance(current, float):
                    setattr(cfg, key, float(value))
                else:
                    setattr(cfg, key, value)
    return cfg


# Mapping of canonical config keys to their env-var leaf names.
_ENV_KEYS = {
    "model_path": "MODEL_PATH",
    "llama_url": "LLAMA_URL",
    "context_size": "CTX_SIZE",
    "parallel_slots": "PARALLEL",
    "threads": "THREADS",
    "max_tokens": "MAX_TOKENS",
    "temperature": "TEMPERATURE",
    "diff_max_chars": "DIFF_MAX_CHARS",
    "diff_cache_ttl": "DIFF_CACHE_TTL",
    "socket_path": "SOCKET_PATH",
    "debounce_ms": "DEBOUNCE_MS",
    "trigger": "TRIGGER",
    "highlight_style": "HIGHLIGHT_STYLE",
}


def _apply_env(cfg: Config, env: dict[str, str]) -> Config:
    for field_name, leaf in _ENV_KEYS.items():
        var = ENV_PREFIX + leaf
        if var not in env:
            continue
        raw = env[var]
        current = getattr(cfg, field_name)
        if isinstance(current, bool):
            setattr(cfg, field_name, _to_bool(raw))
        elif isinstance(current, int):
            setattr(cfg, field_name, _to_int(raw))
        elif isinstance(current, float):
            setattr(cfg, field_name, float(raw))
        else:
            setattr(cfg, field_name, raw)
    return cfg

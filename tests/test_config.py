"""Config precedence tests (ADR-0010): env > TOML file > defaults."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from git_ai_commit.config import load_config


def test_defaults():
    cfg = load_config(env={})
    assert cfg.debounce_ms == 250
    assert cfg.trigger == "space"
    assert cfg.llama_url == "http://127.0.0.1:8080/v1/completions"
    assert cfg.highlight_style == "fg=244"
    assert cfg.max_tokens == 48


def test_env_overrides_defaults(tmp_path, monkeypatch):
    # XDG_RUNTIME_DIR not set so socket path uses the uid fallback.
    monkeypatch.delenv("XDG_RUNTIME_DIR", raising=False)
    cfg = load_config(env={"GIT_AI_DEBOUNCE_MS": "400", "GIT_AI_TRIGGER": "keystroke"})
    assert cfg.debounce_ms == 400
    assert cfg.trigger == "keystroke"


def test_env_beats_file(tmp_path):
    file = tmp_path / "config.toml"
    file.write_text("[daemon]\nmax_tokens = 10\n")
    cfg = load_config(env={"GIT_AI_MAX_TOKENS": "99"}, config_path=file)
    assert cfg.max_tokens == 99  # env wins


def test_file_loaded(tmp_path):
    file = tmp_path / "config.toml"
    file.write_text("[daemon]\ndiff_max_chars = 1234\ndiff_cache_ttl = 10.0\n")
    cfg = load_config(env={}, config_path=file)
    assert cfg.diff_max_chars == 1234
    assert cfg.diff_cache_ttl == 10.0


def test_malformed_file_does_not_crash(tmp_path):
    file = tmp_path / "config.toml"
    file.write_text("not [ valid toml")
    cfg = load_config(env={}, config_path=file)  # should not raise
    assert cfg.debounce_ms == 250

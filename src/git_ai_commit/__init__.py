"""git-ai-commit: ghost-text commit-message completion for Zsh.

Components are documented in ``docs/`` (see docs/README.md and the
ADRs in docs/adr/). See AGENTS.md for the non-negotiable rules.
"""

__version__ = "0.1.0"

from .config import Config, load_config  # noqa: F401
from .peer import verify_peer_uid  # noqa: F401

"""Settings, read from environment variables and secret files, never from the code.

Variable                      Default / meaning
WELBANK_DSN                   localhost:1521/welbank (host:port/service of the PDB)
WELBANK_APP_USER              wb_app, the proxy account
WELBANK_APP_PASSWORD_FILE     <repo>/secrets/wb_app_pwd.txt, WB_APP's password
WELBANK_SECURE_COOKIES        false; true behind HTTPS (production)
WELBANK_SESSION_IDLE_MINUTES  30: log out after this much inactivity
WELBANK_SESSION_MAX_HOURS     10: log out after this long, whatever happens
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _read_secret(env_name: str, default_file: str) -> str:
    """Return a secret from the file named by ``env_name``, else from ``secrets/<default_file>``."""
    path = Path(os.environ.get(env_name, str(REPO_ROOT / "secrets" / default_file)))
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError as exc:
        raise RuntimeError(f"secret file {path} is missing: run ./scripts/init-secrets.sh") from exc


@dataclass(frozen=True)
class Settings:
    """Everything the API needs to know about its environment."""

    dsn: str
    app_user: str
    app_password: str
    secure_cookies: bool
    session_idle_minutes: int
    session_max_hours: int


@lru_cache
def get_settings() -> Settings:
    """Read the settings once."""
    return Settings(
        dsn=os.environ.get("WELBANK_DSN", "localhost:1521/welbank"),
        app_user=os.environ.get("WELBANK_APP_USER", "wb_app"),
        app_password=_read_secret("WELBANK_APP_PASSWORD_FILE", "wb_app_pwd.txt"),
        secure_cookies=os.environ.get("WELBANK_SECURE_COOKIES", "false").lower() == "true",
        session_idle_minutes=int(os.environ.get("WELBANK_SESSION_IDLE_MINUTES", "30")),
        session_max_hours=int(os.environ.get("WELBANK_SESSION_MAX_HOURS", "10")),
    )

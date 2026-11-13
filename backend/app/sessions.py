"""Server-side sessions.

The browser keeps only a random session id in an HttpOnly, SameSite=Strict
cookie: scripts cannot read it, other sites cannot send it, and logging out
really ends the session because the server forgets the id. Sessions live in
memory, so restarting the API logs everyone out; with several API processes a
shared store (Redis, or a table) would replace this class.
"""

from __future__ import annotations

import secrets
import threading
import time
from dataclasses import dataclass

from pydantic import BaseModel


class Employee(BaseModel):
    """The logged-in employee, as read from Oracle at login."""

    username: str
    employee_id: int
    full_name: str
    job_title: str
    department_name: str
    branch_id: int | None
    branch_code: str | None
    branch_name: str | None
    roles: list[str]


@dataclass
class _Session:
    employee: Employee
    created: float
    last_seen: float


class SessionStore:
    """Sessions by id, with an idle timeout and a maximum length."""

    def __init__(self, idle_seconds: int, max_seconds: int) -> None:
        """Start empty."""
        self._idle = idle_seconds
        self._max = max_seconds
        self._sessions: dict[str, _Session] = {}
        self._lock = threading.Lock()

    def create(self, employee: Employee) -> str:
        """Open a session and return its new random id (256 bits)."""
        session_id = secrets.token_urlsafe(32)
        now = time.monotonic()
        with self._lock:
            self._sessions[session_id] = _Session(employee, now, now)
        return session_id

    def get(self, session_id: str) -> Employee | None:
        """Return the session's employee and note the activity; None once it has expired."""
        now = time.monotonic()
        with self._lock:
            session = self._sessions.get(session_id)
            if session is None:
                return None
            if now - session.last_seen > self._idle or now - session.created > self._max:
                del self._sessions[session_id]
                return None
            session.last_seen = now
            return session.employee

    def delete(self, session_id: str) -> Employee | None:
        """End a session; return whose it was."""
        with self._lock:
            session = self._sessions.pop(session_id, None)
        return session.employee if session else None

    def delete_user(self, username: str) -> None:
        """End every session of one employee (after a password change)."""
        with self._lock:
            for session_id in [
                sid for sid, s in self._sessions.items() if s.employee.username == username
            ]:
                del self._sessions[session_id]

    def count(self) -> int:
        """Return the number of open sessions."""
        with self._lock:
            return len(self._sessions)

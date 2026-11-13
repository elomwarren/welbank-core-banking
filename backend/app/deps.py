"""FastAPI dependencies: who is calling, a database connection as that person, role checks."""

from __future__ import annotations

from collections.abc import Callable, Iterator
from typing import Annotated, Any

import oracledb
from fastapi import Depends, Request

from .errors import ApiError
from .sessions import Employee

SESSION_COOKIE = "wb_session"


def current_employee(request: Request) -> Employee:
    """Return the logged-in employee, or answer 401."""
    session_id = request.cookies.get(SESSION_COOKIE)
    employee = request.app.state.sessions.get(session_id) if session_id else None
    if employee is None:
        raise ApiError(401, "NOT_LOGGED_IN", "Please log in.")
    return employee


CurrentEmployee = Annotated[Employee, Depends(current_employee)]


def client_address(request: Request) -> str:
    """Return the browser's address (uvicorn applies X-Forwarded-For from the trusted proxy)."""
    return request.client.host if request.client else "unknown"


def database(request: Request, employee: CurrentEmployee) -> Iterator[oracledb.Connection]:
    """Lend a connection that runs as the logged-in employee for this request."""
    route = request.scope.get("route")
    action = getattr(route, "name", None) or request.url.path
    registry = request.app.state.pools
    with registry.connection(employee.username, client_address(request), action) as connection:
        yield connection


Db = Annotated[oracledb.Connection, Depends(database)]


def require_role(*roles: str) -> Any:
    """Return a dependency that lets in only employees holding one of ``roles``.

    The database enforces the same rule through its grants; checking here as
    well gives a clear message and keeps the user interface honest.
    """

    def check(employee: CurrentEmployee) -> Employee:
        if not set(roles) & set(employee.roles):
            readable = ", ".join(
                role.removeprefix("WB_").replace("_", " ").lower() for role in roles
            )
            raise ApiError(403, "ROLE_REQUIRED", f"This needs the role: {readable}.")
        return employee

    checker: Callable[[Employee], Employee] = check
    return Depends(checker)

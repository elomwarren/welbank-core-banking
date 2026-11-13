"""Login, logout, the current employee, and password changes.

Oracle checks every password (profile WB_EMPLOYEE), so lockouts, expiry and
complexity rules are the database's own. The API never stores a password.
"""

from typing import Any

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel, Field

from ..db import USERNAME_PATTERN, change_password, check_username, row, rows, verify_login
from ..deps import SESSION_COOKIE, CurrentEmployee, client_address
from ..errors import ApiError
from ..sessions import Employee

router = APIRouter(prefix="/api/auth", tags=["auth"])

_PROFILE_SQL = """
SELECT employee_id, full_name, job_title, department_name, branch_id, branch_code, branch_name
  FROM v_staff_directory
 WHERE db_username = SYS_CONTEXT('USERENV', 'SESSION_USER')"""

_ROLES_SQL = "SELECT role FROM session_roles WHERE role LIKE 'WB\\_%' ESCAPE '\\' ORDER BY role"


class LoginIn(BaseModel):
    """An employee's Oracle user name and password."""

    username: str = Field(pattern=USERNAME_PATTERN, max_length=30)
    password: str = Field(min_length=1, max_length=128)


class PasswordChangeIn(BaseModel):
    """A password change; works also when the old password has expired."""

    username: str = Field(pattern=USERNAME_PATTERN, max_length=30)
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


@router.post("/login")
def login(body: LoginIn, request: Request, response: Response) -> dict[str, Any]:
    """Log in: Oracle checks the password, then the session runs as this employee."""
    settings = request.app.state.settings
    username = check_username(body.username)
    warning = verify_login(settings, username, body.password)
    with request.app.state.pools.connection(username, client_address(request), "login") as conn:
        profile = row(conn, _PROFILE_SQL)
        roles = [r["role"] for r in rows(conn, _ROLES_SQL)]
    if profile is None:
        raise ApiError(403, "NOT_AN_EMPLOYEE", "This account does not belong to an employee.")
    employee = Employee(username=username, roles=roles, **profile)
    session_id = request.app.state.sessions.create(employee)
    response.set_cookie(
        SESSION_COOKIE,
        session_id,
        httponly=True,
        samesite="strict",
        secure=settings.secure_cookies,
        path="/",
        max_age=settings.session_max_hours * 3600,
    )
    return {"employee": employee.model_dump(), "password_warning": warning}


@router.post("/logout")
def logout(request: Request, response: Response) -> dict[str, bool]:
    """End the session: the server forgets it, the browser drops the cookie."""
    session_id = request.cookies.get(SESSION_COOKIE)
    if session_id:
        request.app.state.sessions.delete(session_id)
    response.delete_cookie(SESSION_COOKIE, path="/")
    return {"ok": True}


@router.get("/me")
def me(employee: CurrentEmployee) -> Employee:
    """Return the logged-in employee, their branch and roles."""
    return employee


@router.post("/password")
def password(body: PasswordChangeIn, request: Request) -> dict[str, Any]:
    """Change a password with Oracle's rules; every session of that employee then ends."""
    username = check_username(body.username)
    change_password(request.app.state.settings, username, body.current_password, body.new_password)
    request.app.state.sessions.delete_user(username)
    request.app.state.pools.drop(username)
    return {"ok": True, "message": "Password changed. Log in with the new password."}

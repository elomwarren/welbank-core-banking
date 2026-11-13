"""Oracle errors turned into HTTP answers the user interface can show.

The packages raise business errors with RAISE_APPLICATION_ERROR (ORA-20001 to
ORA-20999, listed in pkg_errors). Their messages are written for the bank's
staff, so they are passed on as they are; only the HTTP status is chosen here.
Anything unexpected is logged in full and answered with a short message, so
no stack trace or SQL ever reaches the browser.
"""

from __future__ import annotations

import logging
import re

import oracledb

log = logging.getLogger("welbank.errors")

# Business errors (pkg_errors) by HTTP status.
_NOT_FOUND = {20002, 20011, 20016, 20018, 20025, 20030}
_FORBIDDEN = {20001, 20013, 20014}
_CONFLICT = {20003, 20004, 20012, 20015, 20022}

# Oracle refusing data: NOT NULL, check, foreign key, too long, bad number or date, SQL assertion.
_BAD_DATA = {
    1400, 1407, 1438, 1722, 1830, 1840, 1841, 1843, 1847, 1858, 1861,
    2290, 2291, 2292, 8601, 12899,
}  # fmt: skip
# The employee's roles do not reach the object (no grant), or the account may not be proxied.
_NO_PRIVILEGE = {942, 1031, 28150}
# The database is down, starting or unreachable.
_UNAVAILABLE = {1033, 1034, 1089, 3113, 3114, 3135, 12514, 12528, 12537, 12541}

_PREFIX = re.compile(r"^(ORA|DPY|PLS)-\d{4,5}: ")


class ApiError(Exception):
    """An error with an HTTP status, a stable code for programs and a message for people."""

    def __init__(self, status_code: int, code: str, message: str) -> None:
        """Keep the three parts of the error."""
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def oracle_code(exc: oracledb.Error) -> int:
    """Return the ORA- number of an error (0 for driver errors such as DPY-6005)."""
    error = exc.args[0] if exc.args else None
    return int(getattr(error, "code", 0) or 0)


def oracle_text(exc: oracledb.Error) -> str:
    """Return the first line of an Oracle error message, without its ORA-nnnnn prefix."""
    error = exc.args[0] if exc.args else exc
    first_line = str(getattr(error, "message", error)).split("\n", 1)[0]
    return _PREFIX.sub("", first_line).strip()


def from_oracle(exc: oracledb.Error) -> ApiError:
    """Choose the HTTP status for an Oracle error and keep its message."""
    error = exc.args[0] if exc.args else None
    code = oracle_code(exc)
    full_code = str(getattr(error, "full_code", "") or "ERROR")
    full_message = str(getattr(error, "message", exc))
    text = oracle_text(exc)

    if 20000 <= code <= 20999:
        if code in _NOT_FOUND:
            status = 404
        elif code in _FORBIDDEN:
            status = 403
        elif code in _CONFLICT:
            status = 409
        elif code == 20999:
            status = 500
        else:
            status = 422
        return ApiError(status, full_code, text)
    if code in _NO_PRIVILEGE or (code == 6550 and "PLS-00201" in full_message):
        return ApiError(403, "ROLE_REQUIRED", "Your roles do not allow this action.")
    if code == 1:
        return ApiError(409, full_code, "This record already exists.")
    if code in _BAD_DATA:
        return ApiError(422, full_code, f"The database refused the data: {text}")
    if code in _UNAVAILABLE or full_code.startswith("DPY-6"):
        return ApiError(503, "DB_UNAVAILABLE", "The database cannot be reached. Try again shortly.")
    log.error("unexpected Oracle error %s: %s", full_code, full_message)
    return ApiError(500, full_code, "Unexpected database error. It has been logged.")

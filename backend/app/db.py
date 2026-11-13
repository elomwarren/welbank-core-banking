"""Connections to Oracle: always as the logged-in employee, through WB_APP.

WB_APP may log in and do nothing else. Each employee's requests use a small
pool of proxy sessions, ``wb_app[EMPLOYEE]``: Oracle runs them as that
employee, with that employee's roles, so the grants decide what is possible,
and pkg_session, the audit trail and Unified Auditing all record who did what.
Passwords are checked by Oracle itself, so the WB_EMPLOYEE profile (lockout
after five failures, 90-day expiry, complexity) applies to the web app too.
"""

from __future__ import annotations

import re
import threading
from collections import OrderedDict
from collections.abc import Iterator
from contextlib import contextmanager
from decimal import Decimal
from typing import Any

import oracledb

from .config import Settings
from .errors import ApiError, from_oracle, oracle_code, oracle_text

oracledb.defaults.fetch_decimals = True  # money stays exact: Decimal, never float
oracledb.defaults.fetch_lobs = False  # photos and signatures come back as bytes

USERNAME_PATTERN = r"^[A-Za-z][A-Za-z0-9_]{0,29}$"
_USERNAME = re.compile(USERNAME_PATTERN)


def check_username(username: str) -> str:
    """Return the user name in upper case; refuse anything but a plain identifier.

    The name is placed inside ``wb_app[NAME]``, so brackets, quotes or spaces must
    never get through.
    """
    if not _USERNAME.fullmatch(username):
        raise ApiError(400, "BAD_USERNAME", "A user name is letters, digits and underscores.")
    return username.upper()


def _init_session(connection: oracledb.Connection, _requested_tag: str | None) -> None:
    """Prepare a new session: unqualified table and package names mean the WELBANK schema."""
    with connection.cursor() as cursor:
        cursor.execute("ALTER SESSION SET CURRENT_SCHEMA = welbank")


class PoolRegistry:
    """One small pool of proxy sessions per employee; the least recently used is closed first."""

    def __init__(self, settings: Settings, max_pools: int = 64) -> None:
        """Start with no pools; they are created at each employee's first request."""
        self._settings = settings
        self._max_pools = max_pools
        self._pools: OrderedDict[str, oracledb.ConnectionPool] = OrderedDict()
        self._lock = threading.Lock()

    def _pool_for(self, username: str) -> oracledb.ConnectionPool:
        with self._lock:
            pool = self._pools.get(username)
            if pool is not None:
                self._pools.move_to_end(username)
                return pool
            pool = oracledb.create_pool(
                user=f"{self._settings.app_user}[{username}]",
                password=self._settings.app_password,
                dsn=self._settings.dsn,
                min=0,
                max=4,
                increment=1,
                timeout=300,  # idle sessions are closed after five minutes
                getmode=oracledb.POOL_GETMODE_TIMEDWAIT,
                wait_timeout=10_000,
                session_callback=_init_session,
            )
            self._pools[username] = pool
            while len(self._pools) > self._max_pools:
                _, oldest = self._pools.popitem(last=False)
                oldest.close(force=True)
            return pool

    def drop(self, username: str) -> None:
        """Close an employee's sessions (after logout or a password change)."""
        with self._lock:
            pool = self._pools.pop(username, None)
        if pool is not None:
            pool.close(force=True)

    def close_all(self) -> None:
        """Close every pool (application shutdown)."""
        with self._lock:
            pools = list(self._pools.values())
            self._pools.clear()
        for pool in pools:
            pool.close(force=True)

    @contextmanager
    def connection(self, username: str, client: str, action: str) -> Iterator[oracledb.Connection]:
        """Lend a connection that runs as the employee.

        What the request did not commit is rolled back: on an error here, and by
        the pool when the connection is returned.
        """
        try:
            pooled = self._pool_for(username).acquire()
        except oracledb.Error as exc:
            raise from_oracle(exc) from exc
        with pooled as connection:
            # End-to-end tracing: visible in V$SESSION, the audit trail and Unified Auditing.
            connection.module = "welbank-web"
            connection.action = action[:32]
            connection.client_identifier = f"{username}@{client}"[:64]
            try:
                yield connection
            except BaseException:
                connection.rollback()
                raise


def verify_login(settings: Settings, username: str, password: str) -> str | None:
    """Check a password with Oracle itself. Return Oracle's password warning, if any."""
    try:
        connection = oracledb.connect(user=username, password=password, dsn=settings.dsn)
    except oracledb.Error as exc:
        raise login_error(exc) from exc
    with connection:
        warning = getattr(connection, "warning", None)
    return oracle_text(warning) if warning else None


def change_password(settings: Settings, username: str, current: str, new: str) -> None:
    """Change an employee's password with Oracle's own rules (also works once it has expired)."""
    try:
        connection = oracledb.connect(
            user=username, password=current, newpassword=new, dsn=settings.dsn
        )
    except oracledb.Error as exc:
        code = oracle_code(exc)
        if code in (28003, 28007, 28221, 988):
            raise ApiError(422, f"ORA-{code:05d}", oracle_text(exc)) from exc
        raise login_error(exc) from exc
    connection.close()


def login_error(exc: oracledb.Error) -> ApiError:
    """Explain a failed login without saying whether the user name exists."""
    code = oracle_code(exc)
    if code == 1017:
        return ApiError(401, "WRONG_CREDENTIALS", "Wrong user name or password.")
    if code == 28000:
        return ApiError(
            423,
            "ACCOUNT_LOCKED",
            "This account is locked: after five wrong passwords it unlocks by itself "
            "in 15 minutes; otherwise ask the bank's administrator.",
        )
    if code == 28001:
        return ApiError(403, "PASSWORD_EXPIRED", "Your password has expired. Choose a new one.")
    if code == 1045:
        return ApiError(403, "NO_ACCESS", "This account may not log in.")
    return from_oracle(exc)


def _json_number(value: Any) -> Any:
    """Make Oracle NUMBERs JSON numbers: whole values become int, others float.

    Oracle hands NUMBER over as Decimal (exact). Money in this bank has at most
    two decimals and 15 digits, which a float holds exactly enough to display and
    to send back (its shortest repr is the original decimal).
    """
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    return value


def rows(connection: oracledb.Connection, sql: str, **binds: Any) -> list[dict[str, Any]]:
    """Run a query and return every row as a dict with lower-case column names."""
    with connection.cursor() as cursor:
        cursor.execute(sql, binds)
        names = [column[0].lower() for column in cursor.description]
        return [
            dict(zip(names, (_json_number(v) for v in values), strict=True)) for values in cursor
        ]


def row(connection: oracledb.Connection, sql: str, **binds: Any) -> dict[str, Any] | None:
    """Run a query and return its first row as a dict, or None."""
    found = rows(connection, sql, **binds)
    return found[0] if found else None


def scalar(connection: oracledb.Connection, sql: str, **binds: Any) -> Any:
    """Run a query and return the first column of its first row, or None."""
    with connection.cursor() as cursor:
        cursor.execute(sql, binds)
        first = cursor.fetchone()
        return first[0] if first else None

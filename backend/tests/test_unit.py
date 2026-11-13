"""Unit tests: no database needed."""

from decimal import Decimal
from types import SimpleNamespace

import oracledb
import pytest
from app import db as db_module
from app import sessions as sessions_module
from app.db import _json_number, check_username, login_error
from app.errors import ApiError, from_oracle
from app.sessions import Employee, SessionStore


def oracle_error(code: int, message: str) -> oracledb.DatabaseError:
    """Build an error shaped like python-oracledb's (code, full_code, message)."""
    detail = SimpleNamespace(code=code, full_code=f"ORA-{code:05d}", message=message)
    return oracledb.DatabaseError(detail)


@pytest.mark.parametrize(
    ("code", "status"),
    [(20002, 404), (20005, 422), (20013, 403), (20014, 403), (20022, 409), (20999, 500)],
)
def test_business_errors_choose_the_status(code, status):
    error = from_oracle(oracle_error(code, f"ORA-{code}: Something the teller can read"))
    assert error.status_code == status
    assert error.message == "Something the teller can read"


def test_business_message_drops_the_plsql_stack():
    error = from_oracle(
        oracle_error(20005, "ORA-20005: Insufficient funds\nORA-06512: at WELBANK.PKG_POSTING")
    )
    assert error.message == "Insufficient funds"
    assert error.code == "ORA-20005"


@pytest.mark.parametrize(
    ("code", "message"),
    [
        (942, "ORA-00942: table or view does not exist"),
        (1031, "ORA-01031: insufficient privileges"),
        (6550, "ORA-06550: line 1\nPLS-00201: identifier 'PKG_CUSTOMER' must be declared"),
    ],
)
def test_missing_grants_are_403(code, message):
    error = from_oracle(oracle_error(code, message))
    assert (error.status_code, error.code) == (403, "ROLE_REQUIRED")


def test_constraint_violation_is_422():
    error = from_oracle(oracle_error(2290, "ORA-02290: check constraint (X) violated"))
    assert error.status_code == 422
    assert error.message.startswith("The database refused the data")


def test_database_down_is_503():
    assert from_oracle(oracle_error(12541, "ORA-12541: no listener")).status_code == 503


def test_unexpected_errors_hide_internals():
    error = from_oracle(oracle_error(600, "ORA-00600: internal error code [kxyz]"))
    assert error.status_code == 500
    assert "kxyz" not in error.message


@pytest.mark.parametrize(
    ("code", "status", "api_code"),
    [
        (1017, 401, "WRONG_CREDENTIALS"),
        (28000, 423, "ACCOUNT_LOCKED"),
        (28001, 403, "PASSWORD_EXPIRED"),
    ],
)
def test_login_errors(code, status, api_code):
    error = login_error(oracle_error(code, f"ORA-{code:05d}: x"))
    assert (error.status_code, error.code) == (status, api_code)


def test_usernames_are_plain_identifiers():
    assert check_username("aadongo") == "AADONGO"
    for bad in ["x[y]", "a b", "1abc", "", "a" * 31, "SCOTT;DROP"]:
        with pytest.raises(ApiError):
            check_username(bad)


def test_oracle_numbers_become_json_numbers():
    assert _json_number(Decimal("120")) == 120
    assert isinstance(_json_number(Decimal("120")), int)
    assert _json_number(Decimal("12.50")) == 12.5
    assert _json_number("text") == "text"


def _employee() -> Employee:
    return Employee(
        username="AADONGO",
        employee_id=1,
        full_name="A Teller",
        job_title="Bank teller",
        department_name="Operations",
        branch_id=1,
        branch_code="ACC-CEN",
        branch_name="Accra Central",
        roles=["WB_STAFF", "WB_TELLER"],
    )


def test_sessions_expire_when_idle(monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(sessions_module.time, "monotonic", lambda: clock[0])
    store = SessionStore(idle_seconds=60, max_seconds=3600)
    session_id = store.create(_employee())
    clock[0] += 30
    assert store.get(session_id) is not None
    clock[0] += 61
    assert store.get(session_id) is None


def test_sessions_end_after_their_maximum(monkeypatch):
    clock = [0.0]
    monkeypatch.setattr(sessions_module.time, "monotonic", lambda: clock[0])
    store = SessionStore(idle_seconds=60, max_seconds=100)
    session_id = store.create(_employee())
    for _ in range(3):
        clock[0] += 40
        store.get(session_id)
    assert store.get(session_id) is None


def test_logout_and_password_change_end_sessions():
    store = SessionStore(idle_seconds=60, max_seconds=3600)
    first, second = store.create(_employee()), store.create(_employee())
    assert store.delete(first).username == "AADONGO"
    store.delete_user("AADONGO")
    assert store.get(second) is None
    assert store.count() == 0


def test_session_ids_are_unpredictable():
    store = SessionStore(idle_seconds=60, max_seconds=3600)
    ids = {store.create(_employee()) for _ in range(50)}
    assert len(ids) == 50
    assert all(len(session_id) >= 40 for session_id in ids)


def test_module_defaults_keep_money_exact():
    assert db_module.oracledb.defaults.fetch_decimals is True

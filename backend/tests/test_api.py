"""Integration tests against the development database (read-only: nothing is written).

They log in as seeded employees with the development password from
secrets/staff_demo_pwd.txt, and are skipped when the file or the database is
missing. Run: cd backend && uv run pytest
"""

from pathlib import Path

import pytest
from app.main import app
from fastapi.testclient import TestClient

PASSWORD_FILE = Path(__file__).resolve().parents[2] / "secrets" / "staff_demo_pwd.txt"


@pytest.fixture(scope="session", autouse=True)
def running_app():
    """Start the application once (lifespan: pools, sessions) for every test client."""
    if not PASSWORD_FILE.exists():
        pytest.skip("no development password (run ./scripts/init-secrets.sh and db-security.sh)")
    with TestClient(app) as client:
        yield client


def _client(username: str) -> TestClient:
    """A client with its own cookie, logged in as ``username`` (shares the running app)."""
    client = TestClient(app)
    response = client.post(
        "/api/auth/login",
        json={"username": username, "password": PASSWORD_FILE.read_text().strip()},
    )
    if response.status_code == 503:
        pytest.skip("database not reachable")
    assert response.status_code == 200, response.text
    return client


@pytest.fixture(scope="module")
def teller():
    return _client("AADONGO")


@pytest.fixture(scope="module")
def cfo():
    return _client("DAKUFFO")


@pytest.fixture(scope="module")
def customer_service():
    return _client("VASHITEY")


def test_not_logged_in_is_401():
    response = TestClient(app).get("/api/auth/me")
    assert response.status_code == 401
    assert response.json()["code"] == "NOT_LOGGED_IN"


def test_teller_has_teller_roles_only(teller):
    me = teller.get("/api/auth/me").json()
    assert "WB_TELLER" in me["roles"]
    assert "WB_REPORTS" not in me["roles"]
    assert me["branch_code"] == "ACC-CEN"


def test_roles_are_enforced(teller):
    response = teller.get("/api/reports/summary")
    assert response.status_code == 403
    assert response.json()["code"] == "ROLE_REQUIRED"


def test_identity_data_needs_its_role(teller, customer_service):
    number = teller.get("/api/customers", params={"take": 1}).json()[0]["customer_no"]
    assert teller.get(f"/api/customers/{number}").json()["identity"] is None
    assert customer_service.get(f"/api/customers/{number}").json()["identity"] is not None


def test_ledger_balances(cfo):
    report = cfo.get("/api/reports/summary").json()
    check = report["ledger_check"]
    assert check["accounts_out_of_balance"] == 0
    assert check["total_debits"] == check["total_credits"]


def test_business_error_from_package(teller):
    response = teller.post(
        "/api/transactions/deposits", json={"account_no": "9999999999", "amount": "10.00"}
    )
    assert response.status_code == 404
    assert response.json()["code"] == "ORA-20002"


def test_invalid_input_is_explained(teller):
    response = teller.post(
        "/api/transactions/deposits", json={"account_no": "1000000000001", "amount": "-5"}
    )
    assert response.status_code == 422
    assert response.json()["code"] == "INVALID_INPUT"


def test_search_respects_take(teller):
    assert len(teller.get("/api/customers", params={"take": 3}).json()) <= 3


def test_reference_lists_every_enum(teller):
    reference = teller.get("/api/reference").json()
    assert len(reference["regions"]) == 16
    assert "GHANA_CARD" in reference["enums"]["doc_type"]


def test_logout_ends_the_session():
    client = _client("CNARTEY")
    assert client.post("/api/auth/logout").status_code == 200
    assert client.get("/api/auth/me").status_code == 401

import pytest
from fastapi.testclient import TestClient

from main import create_app


@pytest.fixture
def client():
    return TestClient(create_app())


def test_summary_is_zeroed_for_empty_store(client):
    response = client.get("/stats/summary")
    assert response.status_code == 200
    assert response.json() == {"total": 0, "completed": 0, "pending": 0}


def test_summary_counts_completed_and_pending(client):
    payloads = [
        {"title": "done one"},
        {"title": "done two"},
        {"title": "still pending"},
    ]
    created = [client.post("/todos", json=payload).json() for payload in payloads]
    client.patch(f"/todos/{created[0]['id']}", json={"completed": True})

    response = client.get("/stats/summary")
    assert response.status_code == 200
    assert response.json() == {"total": 3, "completed": 1, "pending": 2}

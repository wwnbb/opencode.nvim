import pytest
from fastapi.testclient import TestClient

from main import create_app


@pytest.fixture
def client():
    return TestClient(create_app())


def test_create_list_get_update_delete_todo(client):
    create_response = client.post("/todos", json={"title": "Write tests"})
    assert create_response.status_code == 201
    assert create_response.json() == {"id": 1, "title": "Write tests", "completed": False}

    list_response = client.get("/todos")
    assert list_response.status_code == 200
    assert list_response.json() == [{"id": 1, "title": "Write tests", "completed": False}]

    get_response = client.get("/todos/1")
    assert get_response.status_code == 200
    assert get_response.json() == {"id": 1, "title": "Write tests", "completed": False}

    update_response = client.patch("/todos/1", json={"title": "Ship app", "completed": True})
    assert update_response.status_code == 200
    assert update_response.json() == {"id": 1, "title": "Ship app", "completed": True}

    delete_response = client.delete("/todos/1")
    assert delete_response.status_code == 204
    assert delete_response.content == b""

    missing_response = client.get("/todos/1")
    assert missing_response.status_code == 404
    assert missing_response.json() == {"detail": "Todo not found"}


def test_todo_not_found_cases(client):
    get_response = client.get("/todos/999")
    assert get_response.status_code == 404
    assert get_response.json() == {"detail": "Todo not found"}

    update_response = client.patch("/todos/999", json={"completed": True})
    assert update_response.status_code == 404
    assert update_response.json() == {"detail": "Todo not found"}

    delete_response = client.delete("/todos/999")
    assert delete_response.status_code == 404
    assert delete_response.json() == {"detail": "Todo not found"}

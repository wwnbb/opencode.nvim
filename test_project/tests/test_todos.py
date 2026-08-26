import pytest
from fastapi.testclient import TestClient

from main import create_app


@pytest.fixture
def client():
    return TestClient(create_app())


def test_root_message(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"message": "Todo List API"}


def test_create_returns_201_with_defaults(client):
    response = client.post("/todos", json={"title": "Write docs"})
    assert response.status_code == 201
    assert response.json() == {
        "id": 1,
        "title": "Write docs",
        "completed": False,
        "finished": True,
    }


def test_create_ignores_extra_finished_field(client):
    response = client.post("/todos", json={"title": "Legacy client", "finished": False})
    assert response.status_code == 201
    assert response.json()["finished"] is True


def test_list_is_empty_initially_and_preserves_order(client):
    empty_response = client.get("/todos")
    assert empty_response.status_code == 200
    assert empty_response.json() == []

    client.post("/todos", json={"title": "First"})
    client.post("/todos", json={"title": "Second"})
    client.post("/todos", json={"title": "Third"})

    listed = client.get("/todos")
    assert listed.status_code == 200
    assert [todo["title"] for todo in listed.json()] == ["First", "Second", "Third"]


def test_patch_completed_leaves_title_untouched(client):
    created = client.post("/todos", json={"title": "Original"}).json()

    patched = client.patch(f"/todos/{created['id']}", json={"completed": True})

    assert patched.status_code == 200
    body = patched.json()
    assert body["title"] == "Original"
    assert body["completed"] is True


def test_get_missing_todo_returns_404(client):
    response = client.get("/todos/99")
    assert response.status_code == 404
    assert response.json() == {"detail": "Todo not found"}


def test_patch_missing_todo_returns_404(client):
    response = client.patch("/todos/99", json={"completed": True})
    assert response.status_code == 404
    assert response.json() == {"detail": "Todo not found"}


def test_delete_missing_todo_returns_404(client):
    response = client.delete("/todos/99")
    assert response.status_code == 404
    assert response.json() == {"detail": "Todo not found"}


def test_delete_then_get_returns_404(client):
    created = client.post("/todos", json={"title": "Doomed"}).json()

    deleted = client.delete(f"/todos/{created['id']}")
    assert deleted.status_code == 204

    follow_up = client.get(f"/todos/{created['id']}")
    assert follow_up.status_code == 404
    assert follow_up.json() == {"detail": "Todo not found"}


def test_ids_increment_after_delete(client):
    first = client.post("/todos", json={"title": "one"}).json()
    second = client.post("/todos", json={"title": "two"}).json()
    assert (first["id"], second["id"]) == (1, 2)

    assert client.delete("/todos/1").status_code == 204

    third = client.post("/todos", json={"title": "three"}).json()
    assert third["id"] == 3

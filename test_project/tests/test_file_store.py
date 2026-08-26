import pytest

from models import Todo
from store import FileStore


@pytest.mark.skip(reason="Scenario S3: implement FileStore — see SCENARIOS.md")
def test_roundtrip_save_and_load(tmp_path):
    path = tmp_path / "todos.json"
    store = FileStore(path)
    stored = store.add(Todo(id=1, title="Roundtrip"))

    loaded = FileStore(path).list()

    assert [todo.id for todo in loaded] == [stored.id]


@pytest.mark.skip(reason="Scenario S3: implement FileStore — see SCENARIOS.md")
def test_persistence_across_two_instances(tmp_path):
    path = tmp_path / "todos.json"
    FileStore(path).add(Todo(id=7, title="Persistent"))

    reopened = FileStore(path)

    assert reopened.get(7) is not None


@pytest.mark.skip(reason="Scenario S3: implement FileStore — see SCENARIOS.md")
def test_delete_missing_returns_false(tmp_path):
    store = FileStore(tmp_path / "todos.json")

    assert store.delete(999) is False

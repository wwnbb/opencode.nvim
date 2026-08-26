"""Todo stores.

`MemoryStore` backs the running application with per-instance in-memory state.
`FileStore` is intentionally unimplemented: it is the target of Scenario S3,
used to exercise coding-agent workflows. See SCENARIOS.md.
"""

from pathlib import Path

from models import Todo


class MemoryStore:
    """In-memory todo store preserving insertion order, one instance per app."""

    def __init__(self) -> None:
        self._todos: dict[int, Todo] = {}

    def add(self, todo: Todo) -> Todo:
        self._todos[todo.id] = todo
        return todo

    def get(self, todo_id: int) -> Todo | None:
        return self._todos.get(todo_id)

    def list(self) -> list[Todo]:
        return list(self._todos.values())

    def update(self, todo_id: int, data: dict[str, object]) -> Todo | None:
        todo = self._todos.get(todo_id)
        if todo is None:
            return None
        merged = todo.model_dump()
        merged.update(data)
        updated = Todo(**merged)
        self._todos[todo_id] = updated
        return updated

    def delete(self, todo_id: int) -> bool:
        if todo_id not in self._todos:
            return False
        del self._todos[todo_id]
        return True


class FileStore:
    """Scenario target (S3): JSON-file-backed store sharing the MemoryStore API."""

    def __init__(self, path: str | Path) -> None:
        self.path = path

    def add(self, todo: Todo) -> Todo:
        raise NotImplementedError("Scenario S3: implement FileStore — see SCENARIOS.md")

    def get(self, todo_id: int) -> Todo | None:
        raise NotImplementedError("Scenario S3: implement FileStore — see SCENARIOS.md")

    def list(self) -> list[Todo]:
        raise NotImplementedError("Scenario S3: implement FileStore — see SCENARIOS.md")

    def update(self, todo_id: int, data: dict[str, object]) -> Todo | None:
        raise NotImplementedError("Scenario S3: implement FileStore — see SCENARIOS.md")

    def delete(self, todo_id: int) -> bool:
        raise NotImplementedError("Scenario S3: implement FileStore — see SCENARIOS.md")


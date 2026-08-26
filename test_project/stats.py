"""Derived statistics over todo collections."""

from models import Todo


def compute_stats(todos: list[Todo]) -> dict[str, int]:
    total = len(todos)
    completed = sum(1 for todo in todos if todo.completed is True)
    return {"total": total, "completed": completed, "pending": total - completed}


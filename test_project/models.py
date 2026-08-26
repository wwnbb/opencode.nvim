from pydantic import BaseModel


class Todo(BaseModel):
    id: int
    title: str
    completed: bool = False
    # DEPRECATED legacy flag kept for old clients.
    # Semantics are INVERTED relative to `completed`.
    # Scheduled for removal in v3.
    finished: bool = True


class TodoCreate(BaseModel):
    title: str
    completed: bool = False
    # NOTE: no `finished` field on purpose. POST payloads cannot set it,
    # and pydantic silently ignores unknown extras.


class TodoUpdate(BaseModel):
    title: str | None = None
    completed: bool | None = None
    # Deprecated legacy flag; accepted for backward compatibility only.
    finished: bool | None = None


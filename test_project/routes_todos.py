from fastapi import APIRouter, HTTPException, Response, status

from models import Todo, TodoCreate, TodoUpdate


def build_todos_router(store) -> APIRouter:
    """Build the todo CRUD router bound to ``store``.

    The sequential id counter lives in this closure, so ids start at 1 per app
    instance and are never reused, even after deletes.
    """
    router = APIRouter()
    next_id = 1

    @router.get("/")
    def read_root() -> dict[str, str]:
        return {"message": "Todo List API"}

    @router.get("/todos", response_model=list[Todo])
    def list_todos() -> list[Todo]:
        return store.list()

    @router.post("/todos", response_model=Todo, status_code=status.HTTP_201_CREATED)
    def create_todo(payload: TodoCreate) -> Todo:
        nonlocal next_id
        # New todos always keep the default finished=True; payload extras are ignored.
        todo = Todo(id=next_id, title=payload.title, completed=payload.completed)
        next_id += 1
        return store.add(todo)

    @router.get("/todos/{todo_id}", response_model=Todo)
    def read_todo(todo_id: int) -> Todo:
        todo = store.get(todo_id)
        if todo is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Todo not found")
        return todo

    @router.patch("/todos/{todo_id}", response_model=Todo)
    def update_todo(todo_id: int, payload: TodoUpdate) -> Todo:
        data = payload.model_dump(exclude_unset=True)
        updated = store.update(todo_id, data)
        if updated is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Todo not found")
        return updated

    @router.delete("/todos/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_todo(todo_id: int) -> Response:
        if not store.delete(todo_id):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Todo not found")
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router


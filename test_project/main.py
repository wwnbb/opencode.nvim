from fastapi import FastAPI, HTTPException, Response, status
from pydantic import BaseModel


class Todo(BaseModel):
    id: int
    title: str
    completed: bool = False
    finished: bool = False


class TodoCreate(BaseModel):
    title: str
    completed: bool = False
    finished: bool = False


class TodoUpdate(BaseModel):
    title: str | None = None
    completed: bool | None = None
    finished: bool | None = None


def _model_dump(model: BaseModel, **kwargs) -> dict[str, object]:
    if hasattr(model, "model_dump"):
        return model.model_dump(**kwargs)
    return model.dict(**kwargs)


def create_app() -> FastAPI:
    app = FastAPI(title="Todo List API")
    # Store todos in memory so each app instance stays isolated.
    todos: dict[int, Todo] = {}
    next_id = 1

    def get_existing_todo(todo_id: int) -> Todo:
        todo = todos.get(todo_id)
        if todo is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Todo not found")
        return todo

    @app.get("/")
    def read_root() -> dict[str, str]:
        return {"message": "Todo List API"}

    @app.get("/todos", response_model=list[Todo])
    def list_todos() -> list[Todo]:
        return list(todos.values())

    @app.post("/todos", response_model=Todo, status_code=status.HTTP_201_CREATED)
    def create_todo(payload: TodoCreate) -> Todo:
        nonlocal next_id
        todo = Todo(id=next_id, title=payload.title, completed=payload.completed, finished=payload.finished)
        todos[next_id] = todo
        next_id += 1
        return todo

    @app.get("/todos/{todo_id}", response_model=Todo)
    def read_todo(todo_id: int) -> Todo:
        return get_existing_todo(todo_id)

    @app.patch("/todos/{todo_id}", response_model=Todo)
    def update_todo(todo_id: int, payload: TodoUpdate) -> Todo:
        todo = get_existing_todo(todo_id)
        todo_data = _model_dump(todo)
        todo_data.update(_model_dump(payload, exclude_unset=True))
        updated = Todo(**todo_data)
        todos[todo_id] = updated
        return updated

    @app.delete("/todos/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_todo(todo_id: int) -> Response:
        get_existing_todo(todo_id)
        del todos[todo_id]
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return app


app = create_app()


def main():
    import uvicorn

    uvicorn.run("main:app", host="127.0.0.1", port=8000)


if __name__ == "__main__":
    main()

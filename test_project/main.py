from fastapi import FastAPI

from routes_stats import build_stats_router
from routes_todos import build_todos_router
from store import MemoryStore


def create_app() -> FastAPI:
    """Build the Todo app with its own isolated in-memory store."""
    app = FastAPI(title="Todo List API v3")
    store = MemoryStore()
    app.include_router(build_todos_router(store))
    app.include_router(build_stats_router(store))
    return app


app = create_app()


def main() -> None:
    """Run the API with uvicorn when executed as a script."""
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000)


if __name__ == "__main__":
    main()

from fastapi import FastAPI
from routes_stats import build_stats_router
from routes_todos import build_todos_router
from store import MemoryStore


def create_app() -> FastAPI:
    app = FastAPI(title="Todo List API v3")
    # Each app instance gets its own isolated in-memory store.
    store = MemoryStore()
    app.include_router(build_todos_router(store))
    app.include_router(build_stats_router(store))
    return app


app = create_app()


def main():
    import uvicorn

    uvicorn.run("main:app", host="127.0.0.1", port=8000)


if __name__ == "__main__":
    main()

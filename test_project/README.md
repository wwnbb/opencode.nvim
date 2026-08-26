# Todo List API — agent-testing playground

A small multi-module FastAPI Todo service that exists purely as a fixture for manually exercising coding agents: it provides realistic hooks for multi-file edits, ambiguous requirements, bash and permission workflows, ripgrep searches, todo planning, and subagent fan-out. The app itself is deliberately ordinary so the interesting part is how an agent works, not what the code does. Guided exercises live in [SCENARIOS.md](SCENARIOS.md).

## Install

```sh
python -m venv .venv
source .venv/bin/activate
python -m pip install -e ".[test]"
```

## Run

```sh
python main.py
# or
python -m uvicorn main:app --reload
```

Seed a running server with sample todos:

```sh
python scripts/seed.py --url http://127.0.0.1:8000
```

## Test

```sh
python -m pytest tests -q
```

Note: tests in `tests/test_file_store.py` are skipped by design (Scenario S3).

## Endpoints

| Method | Path             | Description                          |
|--------|------------------|--------------------------------------|
| GET    | `/`              | Service banner message               |
| GET    | `/todos`         | List todos (insertion order)         |
| POST   | `/todos`         | Create a todo (201)                  |
| GET    | `/todos/{id}`    | Fetch one todo                       |
| PATCH  | `/todos/{id}`    | Partial update                       |
| DELETE | `/todos/{id}`    | Delete a todo (204)                  |
| GET    | `/stats/summary` | `{total, completed, pending}` counts |

## Layout

| File                       | Purpose                                                         |
|----------------------------|-----------------------------------------------------------------|
| `main.py`                  | App factory (`create_app()`), module-level `app`, uvicorn entry  |
| `models.py`                | Pydantic models: `Todo`, `TodoCreate`, `TodoUpdate`              |
| `store.py`                 | `MemoryStore` plus the unimplemented `FileStore` scenario target |
| `stats.py`                 | `compute_stats()` derived totals                                 |
| `routes_todos.py`          | CRUD router built via `build_todos_router(store)`                |
| `routes_stats.py`          | Stats router built via `build_stats_router(store)`               |
| `scripts/seed.py`          | Seeds a running server with sample todos                         |
| `tests/test_todos.py`      | CRUD behavior tests                                              |
| `tests/test_stats.py`      | `/stats/summary` tests                                           |
| `tests/test_file_store.py` | Skipped specs for future `FileStore` work                        |
| `SCENARIOS.md`             | Agent-exercise scenarios (S1–S11)                                |

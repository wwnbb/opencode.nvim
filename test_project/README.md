# Todo List API

A small FastAPI todo-list application with in-memory storage.

## Install

```sh
python -m venv .venv
source .venv/bin/activate
python -m pip install -e ".[test]"
```

## Run

```sh
python -m uvicorn main:app --reload
```

You can also run:

```sh
python main.py
```

## Test

```sh
python -m pytest tests -q
```

## Endpoints

```sh
curl http://127.0.0.1:8000/
curl http://127.0.0.1:8000/todos
curl -X POST http://127.0.0.1:8000/todos \
  -H 'Content-Type: application/json' \
  -d '{"title":"Buy milk"}'
curl http://127.0.0.1:8000/todos/1
curl -X PATCH http://127.0.0.1:8000/todos/1 \
  -H 'Content-Type: application/json' \
  -d '{"completed":true}'
curl -X DELETE http://127.0.0.1:8000/todos/1
```

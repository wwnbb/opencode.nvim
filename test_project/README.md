# Guessing Game API

A small FastAPI guessing game application with in-memory game state.

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

curl -X POST http://127.0.0.1:8000/game/start \
  -H 'Content-Type: application/json' \
  -d '{"min_number":1,"max_number":100,"max_attempts":10}'

curl http://127.0.0.1:8000/game

curl -X POST http://127.0.0.1:8000/game/guess \
  -H 'Content-Type: application/json' \
  -d '{"guess":42}'
```

Starting a game accepts optional `min_number`, `max_number`, `max_attempts`, and `secret_number` fields. The secret number is never returned by the API.

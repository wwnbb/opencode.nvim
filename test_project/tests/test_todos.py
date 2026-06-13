import pytest
from fastapi.testclient import TestClient

from main import create_app


@pytest.fixture
def client():
    return TestClient(create_app())


def assert_secret_hidden(payload):
    assert "secret_number" not in payload


def test_root_and_missing_game(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"message": "Guessing Game API"}

    game_response = client.get("/game")
    assert game_response.status_code == 404
    assert game_response.json() == {"detail": "Game has not started"}

    guess_response = client.post("/game/guess", json={"guess": 50})
    assert guess_response.status_code == 404
    assert guess_response.json() == {"detail": "Game has not started"}


def test_start_game_returns_public_state(client):
    response = client.post("/game/start", json={"min_number": 1, "max_number": 10, "max_attempts": 3, "secret_number": 5})
    assert response.status_code == 201
    assert response.json() == {
        "min_number": 1,
        "max_number": 10,
        "max_attempts": 3,
        "attempts_used": 0,
        "remaining_attempts": 3,
        "status": "in_progress",
    }
    assert_secret_hidden(response.json())

    game_response = client.get("/game")
    assert game_response.status_code == 200
    assert game_response.json() == response.json()
    assert_secret_hidden(game_response.json())


def test_start_game_defaults_do_not_expose_secret(client):
    response = client.post("/game/start", json={})
    assert response.status_code == 201
    assert response.json() == {
        "min_number": 1,
        "max_number": 100,
        "max_attempts": 10,
        "attempts_used": 0,
        "remaining_attempts": 10,
        "status": "in_progress",
    }
    assert_secret_hidden(response.json())


def test_guess_too_low_too_high_and_correct(client):
    client.post("/game/start", json={"min_number": 1, "max_number": 10, "max_attempts": 3, "secret_number": 5})

    low_response = client.post("/game/guess", json={"guess": 3})
    assert low_response.status_code == 200
    assert low_response.json() == {
        "guess": 3,
        "result": "too_low",
        "attempts_used": 1,
        "remaining_attempts": 2,
        "status": "in_progress",
        "message": "Too low. Try again.",
    }
    assert_secret_hidden(low_response.json())

    high_response = client.post("/game/guess", json={"guess": 7})
    assert high_response.status_code == 200
    assert high_response.json() == {
        "guess": 7,
        "result": "too_high",
        "attempts_used": 2,
        "remaining_attempts": 1,
        "status": "in_progress",
        "message": "Too high. Try again.",
    }

    correct_response = client.post("/game/guess", json={"guess": 5})
    assert correct_response.status_code == 200
    assert correct_response.json() == {
        "guess": 5,
        "result": "correct",
        "attempts_used": 3,
        "remaining_attempts": 0,
        "status": "won",
        "message": "Correct! You won the game.",
    }

    after_game_response = client.post("/game/guess", json={"guess": 5})
    assert after_game_response.status_code == 400
    assert after_game_response.json() == {"detail": "Game is already over"}


def test_out_of_range_guess_does_not_use_attempt(client):
    client.post("/game/start", json={"min_number": 1, "max_number": 10, "max_attempts": 2, "secret_number": 5})

    response = client.post("/game/guess", json={"guess": 11})
    assert response.status_code == 400
    assert response.json() == {"detail": "Guess must be between 1 and 10"}

    game_response = client.get("/game")
    assert game_response.json() == {
        "min_number": 1,
        "max_number": 10,
        "max_attempts": 2,
        "attempts_used": 0,
        "remaining_attempts": 2,
        "status": "in_progress",
    }


def test_loses_on_last_wrong_attempt(client):
    client.post("/game/start", json={"min_number": 1, "max_number": 10, "max_attempts": 2, "secret_number": 5})

    first_response = client.post("/game/guess", json={"guess": 1})
    assert first_response.status_code == 200
    assert first_response.json()["status"] == "in_progress"
    assert first_response.json()["remaining_attempts"] == 1

    last_response = client.post("/game/guess", json={"guess": 2})
    assert last_response.status_code == 200
    assert last_response.json() == {
        "guess": 2,
        "result": "too_low",
        "attempts_used": 2,
        "remaining_attempts": 0,
        "status": "lost",
        "message": "Too low. No attempts remaining. You lost.",
    }

    after_game_response = client.post("/game/guess", json={"guess": 5})
    assert after_game_response.status_code == 400
    assert after_game_response.json() == {"detail": "Game is already over"}


def test_start_game_validation(client):
    range_response = client.post("/game/start", json={"min_number": 10, "max_number": 10})
    assert range_response.status_code == 400
    assert range_response.json() == {"detail": "min_number must be less than max_number"}

    attempts_response = client.post("/game/start", json={"max_attempts": 0})
    assert attempts_response.status_code == 400
    assert attempts_response.json() == {"detail": "max_attempts must be greater than 0"}

    secret_response = client.post("/game/start", json={"min_number": 1, "max_number": 5, "secret_number": 6})
    assert secret_response.status_code == 400
    assert secret_response.json() == {"detail": "secret_number must be between 1 and 5"}

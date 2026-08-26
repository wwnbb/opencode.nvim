#!/usr/bin/env python3
"""Seed a running Todo List API instance with sample todos."""

import argparse
import sys

import httpx

SAMPLE_TODOS = [
    {"title": "Write project README", "completed": True},
    {"title": "Set up test harness", "completed": True},
    {"title": "Implement FileStore", "completed": False},
    {"title": "Add due dates", "completed": False},
    {"title": "Review open diffs", "completed": False},
]


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:8000",
        help="Base URL of the running API (default: %(default)s)",
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        created_ids = []
        with httpx.Client(base_url=args.url) as client:
            for todo in SAMPLE_TODOS:
                response = client.post("/todos", json=todo)
                response.raise_for_status()
                created_ids.append(response.json()["id"])
    except httpx.ConnectError:
        print(
            f"Could not connect to {args.url}. Is the server running? Try: python main.py",
            file=sys.stderr,
        )
        return 1
    print(f"Created {len(created_ids)} todos with ids: {created_ids}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

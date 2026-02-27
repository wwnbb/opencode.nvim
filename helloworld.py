#!/usr/bin/env python3
"""Simple greeting utility for the repo."""

import argparse


GREETING_TEMPLATE = "Hi, {name}! Great to see you in OpenCode.nvim."


def format_greeting(name: str = "User", shout: bool = False) -> str:
    """Return a greeting for ``name``."""
    greeting = GREETING_TEMPLATE.format(name=name)
    return greeting.upper() if shout else greeting


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Print a friendly greeting.")
    parser.add_argument("name", nargs="?", default="User", help="Name to greet")
    parser.add_argument("-s", "--shout", action="store_true", help="Uppercase the greeting")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    print(format_greeting(args.name, args.shout))


if __name__ == "__main__":
    main()


#!/usr/bin/env python3
"""helloworld.py — simple greeting utility for the repo."""

import argparse


def main():
    parser = argparse.ArgumentParser(description="Print a friendly greeting.")
    parser.add_argument("name", nargs="?", default="User", help="Name to greet")
    parser.add_argument("-s", "--shout", action="store_true", help="Uppercase the greeting")
    args = parser.parse_args()
    greeting = f"Hello, {args.name}!"
    if args.shout:
        greeting = greeting.upper()
    print(greeting)


if __name__ == "__main__":
    main()

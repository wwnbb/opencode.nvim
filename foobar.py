"""Simple foobar utility.

Provides a `foobar` function that wraps a value with 'foo' and 'bar'.

Examples:
>>> foobar('x')
'fooxbar'
>>> foobar()
'foobar'
"""

def foobar(value: str = "") -> str:
    """Return a string wrapping `value` with 'foo' and 'bar'."""
    return f"foo{value}bar"


if __name__ == "__main__":
    import sys

    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    print(foobar(arg))

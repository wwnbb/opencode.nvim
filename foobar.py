"""Simple foobar utility.

Provides `foobar` and `foobaz` functions that wrap values with 'foo' and
'bar'/'baz', separating parts with colons.

Examples:
>>> foobar('x')
'foo:x:bar'
>>> foobar()
'foo::bar'
>>> foobaz('x')
'foo:x:baz'
"""

def foobar(value: str = "") -> str:
	"""Return a string wrapping `value` with 'foo' and 'bar', using colons.

	This makes the separators explicit for clearer output in logs/tests.
	Edited by opencode edit tool!
	"""
	return f"foo:{value}:bar"


def foobaz(value: str = "") -> str:
    """Return a string wrapping `value` with 'foo' and 'baz', using colons.

    Similar to foobar but uses 'baz' suffix for variety.
    """
    return f"foo:{value}:baz"


if __name__ == "__main__":
    import sys

    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    print(foobar(arg))





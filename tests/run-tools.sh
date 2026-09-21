#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_TEST_BUN="${OPENCODE_NVIM_BUN:-bun}"
if ! command -v "$TOOL_TEST_BUN" >/dev/null 2>&1; then
	if [ -z "${OPENCODE_NVIM_BUN:-}" ] && [ -x "$HOME/.bun/bin/bun" ]; then
		TOOL_TEST_BUN="$HOME/.bun/bin/bun"
	else
		echo "Error: Bun is required for tool tests (or set OPENCODE_NVIM_BUN)." >&2
		exit 2
	fi
fi

cd "$(dirname "$SCRIPT_DIR")"
"$TOOL_TEST_BUN" test ./tests/tools

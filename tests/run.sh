#!/usr/bin/env bash
# Run opencode.nvim Plenary/Busted tests with real Neovim plugin dependencies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/nvim-test-deps.sh"
resolve_nvim_test_deps

cd "$PLUGIN_ROOT"

TARGET="${1:-all}"
TIMEOUT="${OPENCODE_NVIM_TEST_TIMEOUT:-180000}"

export PLENARY_PATH
export NUI_PATH
export OPENCODE_NVIM_TEST_INIT="$SCRIPT_DIR/minimal_init.lua"
export OPENCODE_NVIM_TEST_TIMEOUT="$TIMEOUT"

echo "Using plenary.nvim from: $PLENARY_PATH"
echo "Using nui.nvim from: $NUI_PATH"

run_file() {
	local file="$1"
	if [ ! -f "$file" ]; then
		echo "Error: test file not found: $file" >&2
		exit 2
	fi
	echo "==> $file"
	export OPENCODE_NVIM_TEST_FILE="$file"
	nvim --headless --noplugin -u "$SCRIPT_DIR/minimal_init.lua" \
		-c "lua require('plenary.busted').run(vim.env.OPENCODE_NVIM_TEST_FILE)"
}

run_directory() {
	local directory="$1"
	if [ ! -d "$directory" ]; then
		echo "Error: test directory not found: $directory" >&2
		exit 2
	fi
	echo "==> $directory"
	export OPENCODE_NVIM_TEST_TARGET="$directory"
	nvim --headless --clean \
		--cmd "set rtp+=$PLUGIN_ROOT" \
		--cmd "set rtp+=$PLENARY_PATH" \
		--cmd "set rtp+=$NUI_PATH" \
		-c "lua require('plenary.test_harness').test_directory(vim.env.OPENCODE_NVIM_TEST_TARGET, { minimal_init = vim.env.OPENCODE_NVIM_TEST_INIT, sequential = true, timeout = tonumber(vim.env.OPENCODE_NVIM_TEST_TIMEOUT) })"
}

case "$TARGET" in
	all)
		run_directory "tests/unit"
		run_directory "tests/checks"
		run_directory "tests/integration"
		run_directory "tests/smoke"
		;;
	unit | checks | integration | smoke)
		run_directory "tests/$TARGET"
		;;
	*)
		if [ -f "$TARGET" ]; then
			run_file "$TARGET"
		elif [ -d "$TARGET" ]; then
			run_directory "$TARGET"
		else
			echo "Error: unknown test target: $TARGET" >&2
			exit 2
		fi
		;;
esac

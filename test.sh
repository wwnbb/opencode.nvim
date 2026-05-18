#!/bin/bash
# test.sh - Test opencode.nvim with dependencies
#
# Usage:
#   ./test.sh                    # Use test.lua config (leader=, ,ot to toggle)
#   ./test.sh --minimal          # Use minimal setup (no config, leader=\)
#   ./test.sh --help             # Show help

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$SCRIPT_DIR"
source "$SCRIPT_DIR/scripts/nvim-test-deps.sh"
resolve_nvim_test_deps

# Parse arguments
USE_MINIMAL=false
SHOW_HELP=false

for arg in "$@"; do
	case $arg in
	--minimal)
		USE_MINIMAL=true
		shift
		;;
	--help | -h)
		SHOW_HELP=true
		shift
		;;
	esac
done

if [ "$SHOW_HELP" = true ]; then
	echo "Usage: ./test.sh [OPTIONS]"
	echo ""
	echo "Test opencode.nvim plugin"
	echo ""
	echo "Options:"
	echo "  --minimal    Use minimal setup (no config file, default leader=\\)"
	echo "  --help, -h   Show this help message"
	echo ""
	echo "Examples:"
	echo "  ./test.sh              # Use test.lua (leader='comma', ,ot to toggle)"
	echo "  ./test.sh --minimal    # Minimal setup"
	echo "  ./test.sh somefile.lua # Open file with test config"
	exit 0
fi

if [ "$USE_MINIMAL" = true ]; then
	echo "Using minimal setup (no config)"
	echo "Using plenary.nvim from: $PLENARY_PATH"
	echo "Using nui.nvim from: $NUI_PATH"
	nvim -u NONE \
		--cmd "set rtp+=$PLUGIN_ROOT" \
		--cmd "set rtp+=$PLENARY_PATH" \
		--cmd "set rtp+=$NUI_PATH" \
		--cmd "runtime plugin/opencode.lua" \
		--cmd "lua require('opencode').setup()" \
		"$@"
else
	echo "Using test.lua config (leader=comma, ,ot to toggle)"
	echo "Using plenary.nvim from: $PLENARY_PATH"
	echo "Using nui.nvim from: $NUI_PATH"
	nvim -u "$PLUGIN_ROOT/test.lua" \
		--cmd "set rtp+=$PLUGIN_ROOT" \
		--cmd "set rtp+=$PLENARY_PATH" \
		--cmd "set rtp+=$NUI_PATH" \
		"$@"
fi

#!/bin/bash
# test.sh - Test opencode.nvim with dependencies
#
# Usage:
#   ./test.sh                    # Use test.lua config (leader=, ,ot to toggle)
#   ./test.sh --minimal          # Use minimal setup (no config, leader=\)
#   ./test.sh --help             # Show help

set -e

# Find plenary.nvim (common locations)
PLENARY_PATH=""
for path in "$HOME/.local/share/nvim/lazy/plenary.nvim" \
	"$HOME/.local/share/nvim/store/plenary.nvim" \
	"$HOME/.config/nvim/plugged/plenary.nvim" \
	"/usr/share/nvim/site/pack/packer/start/plenary.nvim"; do
	if [ -d "$path" ]; then
		PLENARY_PATH="$path"
		break
	fi
done

if [ -z "$PLENARY_PATH" ]; then
	echo "Error: plenary.nvim not found!"
	echo "Please install plenary.nvim first:"
	echo "  - With lazy.nvim: 'nvim-lua/plenary.nvim'"
	echo "  - With packer: 'nvim-lua/plenary.nvim'"
	exit 1
fi

# Find nui.nvim (common locations)
NUI_PATH=""
for path in "$HOME/.local/share/nvim/lazy/nui.nvim" \
	"$HOME/.local/share/nvim/store/nui.nvim" \
	"$HOME/.config/nvim/plugged/nui.nvim" \
	"/usr/share/nvim/site/pack/packer/start/nui.nvim"; do
	if [ -d "$path" ]; then
		NUI_PATH="$path"
		break
	fi
done

if [ -z "$NUI_PATH" ]; then
	echo "Error: nui.nvim not found!"
	echo "Please install nui.nvim first:"
	echo "  - With lazy.nvim: 'MunifTanjim/nui.nvim'"
	echo "  - With packer: 'MunifTanjim/nui.nvim'"
	exit 1
fi

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
		--cmd "set rtp+=$(pwd)" \
		--cmd "set rtp+=$PLENARY_PATH" \
		--cmd "set rtp+=$NUI_PATH" \
		--cmd "runtime plugin/opencode.lua" \
		--cmd "lua require('opencode').setup()" \
		"$@"
else
	echo "Using test.lua config (leader=comma, ,ot to toggle)"
	echo "Using plenary.nvim from: $PLENARY_PATH"
	echo "Using nui.nvim from: $NUI_PATH"
	nvim -u test.lua \
		--cmd "set rtp+=$(pwd)" \
		--cmd "set rtp+=$PLENARY_PATH" \
		--cmd "set rtp+=$NUI_PATH" \
		"$@"
fi

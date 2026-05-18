#!/usr/bin/env bash
# Install pinned Neovim test dependencies under .deps/nvim.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
DEPS_ROOT="${OPENCODE_NVIM_TEST_DEPS:-$PLUGIN_ROOT/.deps/nvim}"

install_dep() {
	local name="$1"
	local repo="$2"
	local ref="$3"
	local path="$DEPS_ROOT/$name"

	mkdir -p "$DEPS_ROOT"
	if [ ! -d "$path/.git" ]; then
		rm -rf "$path"
		git clone --filter=blob:none "$repo" "$path"
	else
		git -C "$path" remote set-url origin "$repo"
	fi

	git -C "$path" fetch --tags origin
	git -C "$path" checkout --detach "$ref"
}

install_dep \
	"plenary.nvim" \
	"https://github.com/nvim-lua/plenary.nvim.git" \
	"${PLENARY_REF:-50012918b2fc8357b87cff2a7f7f0446e47da174}"

install_dep \
	"nui.nvim" \
	"https://github.com/MunifTanjim/nui.nvim.git" \
	"${NUI_REF:-de740991c12411b663994b2860f1a4fd0937c130}"

echo "Neovim test dependencies installed in $DEPS_ROOT"

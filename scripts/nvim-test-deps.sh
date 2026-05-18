#!/usr/bin/env bash
# Shared dependency lookup for opencode.nvim Neovim tests.

find_nvim_test_dep() {
	local name="$1"
	shift
	local path
	for path in "$@"; do
		if [ -n "$path" ] && [ -d "$path" ]; then
			printf '%s\n' "$path"
			return 0
		fi
	done
	return 1
}

resolve_nvim_test_deps() {
	local deps_root="${OPENCODE_NVIM_TEST_DEPS:-$PLUGIN_ROOT/.deps/nvim}"

	PLENARY_PATH="$(find_nvim_test_dep "plenary.nvim" \
		"${OPENCODE_NVIM_PLENARY_PATH:-}" \
		"$deps_root/plenary.nvim" \
		"$HOME/.local/share/nvim/lazy/plenary.nvim" \
		"$HOME/.local/share/nvim/store/plenary.nvim" \
		"$HOME/.config/nvim/plugged/plenary.nvim" \
		"/usr/share/nvim/site/pack/packer/start/plenary.nvim")" || {
		echo "Error: plenary.nvim not found!"
		echo "Run: ./scripts/bootstrap-test-deps.sh"
		return 1
	}

	NUI_PATH="$(find_nvim_test_dep "nui.nvim" \
		"${OPENCODE_NVIM_NUI_PATH:-}" \
		"$deps_root/nui.nvim" \
		"$HOME/.local/share/nvim/lazy/nui.nvim" \
		"$HOME/.local/share/nvim/store/nui.nvim" \
		"$HOME/.config/nvim/plugged/nui.nvim" \
		"/usr/share/nvim/site/pack/packer/start/nui.nvim")" || {
		echo "Error: nui.nvim not found!"
		echo "Run: ./scripts/bootstrap-test-deps.sh"
		return 1
	}

	export PLENARY_PATH
	export NUI_PATH
}

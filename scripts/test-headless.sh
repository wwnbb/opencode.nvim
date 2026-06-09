#!/usr/bin/env bash
# Run deterministic headless checks with real Neovim plugin dependencies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/nvim-test-deps.sh"
resolve_nvim_test_deps

cd "$PLUGIN_ROOT"

if [ "$#" -eq 0 ]; then
	TEST_SCRIPTS=(
		"scripts/check-architecture.lua"
		"scripts/check-state-ownership.lua"
		"scripts/check-send-flow.lua"
		"scripts/check-transport.lua"
		"scripts/test-input-history.lua"
		"scripts/test-input-mentions.lua"
		"scripts/test-input-slash-commands.lua"
		"scripts/smoke-require.lua"
		"scripts/integration-chat-tabs.lua"
		"scripts/integration-chat-render-freshness.lua"
	)
else
	TEST_SCRIPTS=("$@")
fi

echo "Using plenary.nvim from: $PLENARY_PATH"
echo "Using nui.nvim from: $NUI_PATH"

for script in "${TEST_SCRIPTS[@]}"; do
	echo "==> $script"
	nvim --headless --clean \
		--cmd "set rtp+=$PLUGIN_ROOT" \
		--cmd "set rtp+=$PLENARY_PATH" \
		--cmd "set rtp+=$NUI_PATH" \
		-l "$script"
done

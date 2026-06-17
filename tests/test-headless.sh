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
		"tests/check-architecture.lua"
		"tests/check-state-ownership.lua"
		"tests/check-send-flow.lua"
		"tests/check-transport.lua"
		"tests/test-input-history.lua"
		"tests/test-input-mentions.lua"
		"tests/test-input-slash-commands.lua"
		"tests/test-input-autocomplete.lua"
		"tests/smoke-require.lua"
		"tests/smoke-chat-new-session-skill-render.lua"
		"tests/integration-chat-tabs.lua"
		"tests/integration-chat-render-freshness.lua"
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

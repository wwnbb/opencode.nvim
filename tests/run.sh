#!/usr/bin/env bash
# Run opencode.nvim Plenary/Busted tests with real Neovim plugin dependencies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/nvim-test-deps.sh"
resolve_nvim_test_deps

# Resolve installed dependencies first, then isolate preferences, logs and caches
# from the user's Neovim profile. Each test process gets its own data directory.
TEST_PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/opencode-nvim-tests.XXXXXX")"
trap 'rm -rf "$TEST_PROFILE"' EXIT
export OPENCODE_NVIM_TEST_PROFILE="$TEST_PROFILE"
export XDG_CONFIG_HOME="$TEST_PROFILE/config"
export XDG_DATA_HOME="$TEST_PROFILE/data"
export XDG_STATE_HOME="$TEST_PROFILE/state"
export XDG_CACHE_HOME="$TEST_PROFILE/cache"
export NVIM_LOG_FILE="$TEST_PROFILE/nvim.log"

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
	hot-paths)
		export OPENCODE_NVIM_HOT_PATH_PREFLIGHT="$SCRIPT_DIR/hot_path_preflight.lua"
		nvim --headless --noplugin -u "$SCRIPT_DIR/minimal_init.lua" \
			-c "lua local ok, err = pcall(dofile, vim.env.OPENCODE_NVIM_HOT_PATH_PREFLIGHT); if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 1') end" \
			-c "qa!"
		# Keep work counts and output equivalence deterministic; no timing gate.
		for file in \
			tests/unit/render_scope_merge_spec.lua \
			tests/integration/render_scheduling_spec.lua \
			tests/unit/activity_leaf_cache_spec.lua \
			tests/unit/markdown_memo_spec.lua \
			tests/unit/syntax_cache_status_spec.lua \
			tests/unit/syntax_query_cache_spec.lua \
			tests/unit/highlight_cache_equivalence_spec.lua \
			tests/integration/hot_path_frame_equivalence_spec.lua \
			tests/integration/input_syntax_reuse_spec.lua \
			tests/integration/input_syntax_native_query_spec.lua \
			tests/unit/sync_delta_equivalence_spec.lua \
			tests/unit/sync_accessors_spec.lua \
			tests/unit/sync_indexes_spec.lua \
			tests/unit/sync_memo_spec.lua \
			tests/unit/history_metadata_spec.lua \
			tests/unit/completion_context_spec.lua \
			tests/unit/context_budget_equivalence_spec.lua \
			tests/unit/explanation_context_spec.lua \
			tests/unit/memo_spec.lua \
			tests/unit/render_memo_budget_spec.lua \
			tests/unit/memo_teardown_spec.lua \
			tests/unit/input_work_counts_spec.lua \
			tests/integration/input_resize_spec.lua; do
			run_file "$file"
		done
		;;
	all)
		run_directory "tests/unit"
		run_directory "tests/checks"
		run_directory "tests/integration"
		run_directory "tests/smoke"
		bash "$SCRIPT_DIR/run-tools.sh"
		;;
	tools)
		bash "$SCRIPT_DIR/run-tools.sh"
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

#!/usr/bin/env bash
# Run LuaLS diagnostics over lua/ and print the unique warning count by code.
# Informational only: this is not part of CI or tests/run.sh.
#
# Usage: scripts/luals-check.sh [--list]
#   --list  also print every unique warning as file:line:col code message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

LIST=false
case "${1:-}" in
	"") ;;
	--list) LIST=true ;;
	*) echo "Usage: $0 [--list]" >&2; exit 2 ;;
esac

if ! command -v lua-language-server >/dev/null 2>&1; then
	echo "luals-check: skipped (lua-language-server is not installed)"
	exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "luals-check: skipped (python3 is required to summarize the report)"
	exit 0
fi

if [ -z "${VIMRUNTIME:-}" ]; then
	if ! command -v nvim >/dev/null 2>&1; then
		echo "luals-check: skipped (VIMRUNTIME is unset and nvim is not installed)"
		exit 0
	fi
	# Plugins may print banners on stdout; the runtime path is the last path-like token.
	VIMRUNTIME="$(nvim --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q 2>/dev/null \
		| tr -s '[:space:]' '\n' | grep '^/' | tail -n 1 || true)"
	if [ -z "$VIMRUNTIME" ] || [ ! -d "$VIMRUNTIME" ]; then
		echo "luals-check: skipped (could not determine VIMRUNTIME from nvim)"
		exit 0
	fi
fi
export VIMRUNTIME

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-luals.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT

# LuaLS silently ignores a relative --configpath, and in --check mode it resolves
# relative workspace.library entries against the checked directory (lua/) instead
# of the plugin root an editor would use. Rewrite them as absolute paths.
CONFIG="$LOG_DIR/luarc.json"
python3 - "$PLUGIN_ROOT/.luarc.json" "$PLUGIN_ROOT" "$CONFIG" <<'PY'
import json
import os
import sys

source, root, target = sys.argv[1:4]
with open(source, encoding="utf-8") as handle:
	config = json.load(handle)
workspace = config.setdefault("workspace", {})
workspace["library"] = [
	entry if entry.startswith(("/", "$")) else os.path.join(root, entry)
	for entry in workspace.get("library", [])
]
with open(target, "w", encoding="utf-8") as handle:
	json.dump(config, handle)
PY

lua-language-server \
	--check="$PLUGIN_ROOT/lua" \
	--checklevel=Warning \
	--configpath="$CONFIG" \
	--logpath="$LOG_DIR" \
	--check_format=json >/dev/null 2>&1 || true

REPORT="$LOG_DIR/check.json"
if [ ! -f "$REPORT" ]; then
	echo "luals-check: no warnings (no report written)"
	exit 0
fi

python3 - "$REPORT" "$PLUGIN_ROOT" "$LIST" <<'PY'
import collections
import json
import sys
from urllib.parse import unquote, urlparse

report, root, show_list = sys.argv[1], sys.argv[2].rstrip("/") + "/", sys.argv[3] == "true"
with open(report, encoding="utf-8") as handle:
	data = json.load(handle)

unique = set()
for uri, diagnostics in data.items():
	path = unquote(urlparse(uri).path)
	if path.startswith(root):
		path = path[len(root):]
	for diagnostic in diagnostics:
		start = diagnostic.get("range", {}).get("start", {})
		unique.add((path, start.get("line", 0) + 1, start.get("character", 0) + 1,
			diagnostic.get("code", "?"), diagnostic.get("message", "").replace("\n", " ")))

by_code = collections.Counter(entry[3] for entry in unique)
print(f"luals-check: {len(unique)} unique warnings")
for code, count in sorted(by_code.items(), key=lambda item: (-item[1], item[0])):
	print(f"  {code:<28} {count}")
if show_list:
	for path, line, col, code, message in sorted(unique):
		print(f"{path}:{line}:{col}: {code}: {message}")
PY

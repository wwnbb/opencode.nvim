#!/usr/bin/env bash
# Install opencode.nvim custom tools into the opencode config directory
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
TOOLS_SRC="$PLUGIN_ROOT/tools"
TOOLS_DST="$HOME/.config/opencode/tools"

mkdir -p "$TOOLS_DST"

for f in opencode_edit.ts opencode_edit.txt opencode_apply_patch.ts opencode_apply_patch.txt; do
  if [ -f "$TOOLS_SRC/$f" ]; then
    cp "$TOOLS_SRC/$f" "$TOOLS_DST/$f"
  fi
done

echo "opencode.nvim: tools installed to $TOOLS_DST"

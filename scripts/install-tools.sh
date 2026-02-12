#!/usr/bin/env bash
# Install opencode.nvim default configuration to Neovim config directory
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="$PLUGIN_ROOT/opencode_default_config"
CONFIG_DIR="${1:-${XDG_CONFIG_HOME:-$HOME/.config}/nvim/opencode}"

mkdir -p "$CONFIG_DIR"
cp -r "$SOURCE_DIR"/* "$CONFIG_DIR/"

echo "opencode.nvim: Config installed to $CONFIG_DIR"

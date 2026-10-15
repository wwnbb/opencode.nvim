#!/usr/bin/env python3
"""Exercise copy-only installation without a JavaScript toolchain."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
profile = Path(tempfile.mkdtemp(prefix="opencode-nvim-install-test-"))
blocked_bin = profile / "blocked-bin"
blocked_bin.mkdir()
toolchain_log = profile / "unexpected-toolchain"
for command in ("node", "npm", "npx", "bun"):
    executable = blocked_bin / command
    executable.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$OPENCODE_INSTALL_TOOLCHAIN_LOG"\nexit 99\n')
    executable.chmod(0o755)
environment = dict(os.environ, PATH=str(blocked_bin) + os.pathsep + os.environ.get("PATH", ""),
                   OPENCODE_INSTALL_TOOLCHAIN_LOG=str(toolchain_log))
config = profile / "opencode"
config.mkdir()
original = '''{
  // Keep this user's comment.
  /* Strings are not comments: https://example.com/a//b */
  "plugins": ["example-user-plugin"],
  "permissions": [
    { "action": "neovim_edit", "resource": "*.lua", "effect": "ask" },
    { "action": "neovim_patch", "resource": "*.md", "effect": "ask" }
  ],
  "commands": { "mine": { "description": "User command", "template": "Keep me" } },
  "mcp": {},
}
'''
config_file = config / "opencode.jsonc"
config_file.write_text(original)
(config / "commands").mkdir()
(config / "commands/custom.md").write_text("User's command\n")
(config / "tool").mkdir()
(config / "tool/custom.ts").write_text("User's custom tool\n")


def install(directory, success=True, reason=None):
    result = subprocess.run([str(repo / "scripts/install-tools.sh"), str(directory)],
                            env=environment, capture_output=True, text=True)
    if success:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0, result.stdout + result.stderr
        assert reason in result.stderr, result.stderr
    return result


def snapshot(directory):
    result = {}
    for path in directory.rglob("*"):
        relative = str(path.relative_to(directory))
        if path.is_symlink():
            result[relative] = "link:" + os.readlink(path)
        elif path.is_dir():
            result[relative] = "dir"
        else:
            result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


for run in range(2):
    install(config)
    installed = config / "plugins/opencode-nvim"
    assert not (installed / "node_modules").exists()
    assert not (installed / "package-lock.json").exists()
    assert (installed / "index.js").is_file()
    assert json.loads((installed / "package.json").read_text())["exports"] == "./index.js"
    assert config_file.read_bytes() == original.encode()
    assert (config / "commands/custom.md").read_text() == "User's command\n"
    assert (config / "tool/custom.ts").read_text() == "User's custom tool\n"
assert len(list((config / "opencode-nvim-backups").glob("*/opencode-nvim/package.json"))) == 1

# Each rejection must preserve both the installed plugin and every config byte.
for marker, contents in [
    ("permission", '{"permission":{"rg":"deny"}}'),
    ("permission", '{"permission":null}'),
    ("theme: opencode", '{"theme":"opencode"}'),
    ("old $schema", '{"$schema":"https://opencode.ai/config.json"}'),
    ("neovim_apply_patch", '{"permissions":[{"action":"neovim_apply_patch","resource":"*","effect":"ask"}]}'),
    ("neovim_apply_patch", '{"agents":{"build":{"permissions":[{"action":"neovim_apply_patch","resource":"*","effect":"ask"}]}}}'),
    ("index.ts", '{"plugins":["./plugins/opencode-nvim/index.ts"]}'),
    ("index.ts", json.dumps({"plugins": [str(config / "plugins/opencode-nvim/index.ts")]})),
    ("plugins must be an array", '{"plugins":{}}'),
    ("plugins must be an array", '{"plugins":null}'),
    ("permissions must be an array", '{"permissions":{}}'),
    ("Invalid JSONC", '{"unterminated":'),
    ("Invalid JSONC", '{/* unterminated'),
    ("Invalid JSONC", '{,}'),
    ("Invalid JSONC", '{"plugins":[,]}'),
    ("Invalid JSONC", '[]'),
    ("Invalid JSONC", 'null'),
]:
    config_file.write_text(contents)
    before = snapshot(config)
    install(config, success=False, reason=marker)
    assert snapshot(config) == before, marker

# Presence alone is enough: an unsupported user-modified file must remain untouched.
config_file.write_text(original)
(config / "tool/rg.txt").write_text("Edited old tool\n")
before = snapshot(config)
install(config, success=False, reason="tool/rg.txt")
assert snapshot(config) == before

# Rejection on a profile without a plugin must not create one or a backup.
unsupported_config = profile / "unsupported"
(unsupported_config / "commands").mkdir(parents=True)
(unsupported_config / "commands/load_skills.md").write_text("Edited old command\n")
before = snapshot(unsupported_config)
install(unsupported_config, success=False, reason="commands/load_skills.md")
assert snapshot(unsupported_config) == before

# Existing JSON is also unchanged, including explicit entries from older installs.
json_config = profile / "json"
json_config.mkdir()
json_text = json.dumps({"plugins": [str(json_config / "plugins/opencode-nvim")],
                        "commands": {"url": {"template": 'https://example.com/a//b /* not a comment */ \\"'}}})
(json_config / "opencode.json").write_text(json_text)
install(json_config)
assert (json_config / "opencode.json").read_text() == json_text
assert not (json_config / "opencode.jsonc").exists()

# A fresh profile gets the default config and no dependency directory.
fresh = profile / "fresh"
install(fresh)
assert (fresh / "opencode.jsonc").read_bytes() == (repo / "opencode_nvim/opencode.jsonc").read_bytes()
assert not list((fresh / "plugins/opencode-nvim").rglob("node_modules"))

# Replace only owned installs; preserve their complete contents in the backup.
old = profile / "old"
old_plugin = old / "plugins/opencode-nvim"
(old_plugin / "node_modules/old-package").mkdir(parents=True)
(old_plugin / "package.json").write_text('{"name":"opencode-nvim-server","exports":"./index.ts"}')
(old_plugin / "node_modules/old-package/custom").write_text("Previous installation\n")
old_snapshot = snapshot(old_plugin)
install(old)
assert not (old_plugin / "node_modules").exists()
old_backups = list((old / "opencode-nvim-backups").glob("*/opencode-nvim"))
assert len(old_backups) == 1 and snapshot(old_backups[0]) == old_snapshot

for contents in ('{"name":"somebody-elses-plugin"}', '{broken', 'null'):
    unowned = profile / "unowned"
    unowned_plugin = unowned / "plugins/opencode-nvim"
    unowned_plugin.mkdir(parents=True, exist_ok=True)
    (unowned_plugin / "package.json").write_text(contents)
    before = snapshot(unowned)
    install(unowned, success=False, reason="Refusing to replace an unowned directory")
    assert snapshot(unowned) == before

# Conflicting config files are rejected before installation creates anything.
conflicting = profile / "conflicting"
conflicting.mkdir()
for name in ("opencode.json", "opencode.jsonc"):
    (conflicting / name).write_text("{}")
before = snapshot(conflicting)
install(conflicting, success=False, reason="Both opencode.json and opencode.jsonc")
assert snapshot(conflicting) == before

# Failure during either commit step restores the entire old installation.
failure_script = profile / "fail-commit.lua"
failure_script.write_text('''
local uv = vim.uv or vim.loop
local rename = uv.fs_rename
if vim.env.OPENCODE_INSTALL_FAIL == "rename" then
  uv.fs_rename = function(from, to)
    if from:find("/.opencode-nvim-install-", 1, true) then return nil, "Injected rename failure" end
    return rename(from, to)
  end
else
  local copyfile = uv.fs_copyfile
  uv.fs_copyfile = function(from, to, flags)
    if to:match("/opencode.jsonc$") then return nil, "Injected config failure" end
    return copyfile(from, to, flags)
  end
end
dofile(vim.env.OPENCODE_INSTALL_SCRIPT)
''')
for step in ("rename", "config"):
    rollback = profile / ("rollback-" + step)
    rollback_plugin = rollback / "plugins/opencode-nvim"
    rollback_plugin.mkdir(parents=True)
    (rollback_plugin / "package.json").write_text('{"name":"opencode-nvim-server"}')
    (rollback_plugin / "original").write_text("Keep the previous plugin\n")
    before = snapshot(rollback_plugin)
    result = subprocess.run([shutil.which("nvim"), "--headless", "--noplugin", "-u", "NONE", "-i", "NONE", "-n",
                             "-l", str(failure_script), str(rollback)], capture_output=True, text=True,
                            env=dict(environment, OPENCODE_INSTALL_FAIL=step,
                                     OPENCODE_INSTALL_SCRIPT=str(repo / "scripts/install-tools.lua")))
    assert result.returncode != 0 and "Injected" in result.stderr, result.stdout + result.stderr
    assert snapshot(rollback_plugin) == before
    assert not (rollback / "opencode.jsonc").exists()
    assert not list(rollback.glob(".opencode-nvim-install-*"))

assert not toolchain_log.exists(), toolchain_log.read_text() if toolchain_log.exists() else ""
print("Copy-only installer, preservation, migration, and refusal checks passed:", profile)

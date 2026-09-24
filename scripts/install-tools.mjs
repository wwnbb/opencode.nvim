import * as fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { createRequire } from "node:module"
import { randomUUID } from "node:crypto"
import { spawnSync } from "node:child_process"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const source = path.join(root, "opencode_nvim/plugins/opencode-nvim")
const config = path.resolve(process.argv[2])
const target = path.join(config, "plugins/opencode-nvim")
const exists = async file => fs.lstat(file).then(() => true, () => false)

// Refuse unsupported files before changing a user's configuration.
const unsupportedFiles = [
  "tool/lib/context.ts", "tool/lib/diff.ts", "tool/lib/file_state.ts", "tool/lib/text.ts",
  "tool/neovim_apply_patch.ts", "tool/neovim_apply_patch.txt",
  "tool/neovim_edit.ts", "tool/neovim_edit.txt",
  "tool/rg.ts", "tool/rg.txt", "commands/load_skills.md",
]

const failUnsupported = detail => {
  throw new Error(`Unsupported OpenCode configuration (${detail}). Remove or update the reported entry before installing; existing files were not changed.`)
}

// Check before downloading dependencies or creating a profile.
for (const relative of unsupportedFiles) {
  if (await exists(path.join(config, relative))) failUnsupported(relative)
}
if (await exists(target)) {
  const pkg = JSON.parse(await fs.readFile(path.join(target, "package.json"), "utf8"))
  if (pkg.name !== "opencode-nvim-server") throw new Error(`Refusing to replace an unowned directory: ${target}`)
  for (const name of ["neovim_apply_patch.ts", "neovim_apply_patch.txt"]) {
    if (await exists(path.join(target, "tools", name))) failUnsupported(`plugins/opencode-nvim/tools/${name}`)
  }
}

const jsonc = path.join(config, "opencode.jsonc"), json = path.join(config, "opencode.json")
if (await exists(jsonc) && await exists(json)) throw new Error("Both opencode.json and opencode.jsonc exist; consolidate them before installing the server plugin")
const configFile = await exists(json) ? json : jsonc
const previous = await exists(configFile) ? await fs.readFile(configFile, "utf8") : undefined

// Install dependencies in the system temp directory. A rejected profile must
// leave even a previously nonexistent config directory untouched.
const stage = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-nvim-install-"))
let commitStage
try {
  await fs.cp(source, stage, { recursive: true, filter: file => path.basename(file) !== "node_modules" })
  const installed = spawnSync(process.platform === "win32" ? "npm.cmd" : "npm", ["ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"], { cwd: stage, stdio: "inherit" })
  if (installed.status !== 0) throw new Error("Pinned server dependencies could not be installed; existing installation was not changed")
  const { parse, modify, applyEdits } = createRequire(path.join(stage, "package.json"))("jsonc-parser")
  let text = previous ?? await fs.readFile(path.join(root, "opencode_nvim/opencode.jsonc"), "utf8")
  const errors = [], value = parse(text, errors, { allowTrailingComma: true })
  if (errors.length || !value || Array.isArray(value) || typeof value !== "object") throw new Error(`Invalid JSONC: ${configFile}; existing configuration was not changed`)
  if (value.plugins !== undefined && !Array.isArray(value.plugins)) throw new Error("plugins must be an array")
  if (value.permissions !== undefined && !Array.isArray(value.permissions)) throw new Error("permissions must be an array")

  // Reject unsupported constructs instead of silently changing their meaning.
  if (value.permission !== undefined) failUnsupported("permission")
  if (value.theme === "opencode") failUnsupported("theme: opencode")
  if (value.$schema === "https://opencode.ai/config.json") failUnsupported("old $schema")
  const entry = path.join(target, "index.ts")
  if ((value.plugins ?? []).some(item => [entry, "./plugins/opencode-nvim/index.ts"].includes(item))) failUnsupported("plugin entry ending in index.ts")
  const checkRules = (rules, scope) => {
    if (!Array.isArray(rules)) return
    if (rules.some(rule => rule?.action === "neovim_apply_patch")) failUnsupported(`${scope}: neovim_apply_patch`)
  }
  checkRules(value.permissions, "permissions")
  for (const [name, agent] of Object.entries(value.agents ?? {})) {
    if (agent?.permission !== undefined) failUnsupported(`agents.${name}.permission`)
    checkRules(agent?.permissions, `agents.${name}.permissions`)
  }

  // Preserve user entries and JSONC comments. Only add the v2 plugin path.
  const plugins = value.plugins ?? []
  if (!plugins.some(item => [target, "./plugins/opencode-nvim"].includes(item))) {
    text = applyEdits(text, modify(text, ["plugins"], [...plugins, target], { formattingOptions: { insertSpaces: true, tabSize: 2 } }))
  }

  await fs.mkdir(config, { recursive: true })
  commitStage = path.join(config, `.opencode-nvim-install-${randomUUID()}`)
  await fs.cp(stage, commitStage, { recursive: true })
  const backup = path.join(config, "opencode-nvim-backups", new Date().toISOString().replaceAll(":", "-") + "-" + path.basename(commitStage))
  await fs.mkdir(backup, { recursive: true })
  if (previous !== undefined && previous !== text) await fs.writeFile(path.join(backup, path.basename(configFile)), previous, { flag: "wx" })
  if (await exists(target)) await fs.rename(target, path.join(backup, "opencode-nvim"))
  await fs.mkdir(path.dirname(target), { recursive: true })
  await fs.rename(commitStage, target)
  if (previous !== text) {
    const temporary = configFile + ".opencode-nvim-new"
    await fs.writeFile(temporary, text, { flag: "wx" }); await fs.rename(temporary, configFile)
  }
  const installedPackage = JSON.parse(await fs.readFile(path.join(target, "package.json"), "utf8"))
  await fs.writeFile(path.join(target, ".opencode-nvim-install.json"), JSON.stringify({ version: installedPackage.version, configFile, backup }) + "\n")
  console.log(`opencode.nvim: v2 server plugin installed in ${target}\nPreserved previous files in ${backup}`)
} finally {
  await fs.rm(stage, { recursive: true, force: true })
  if (commitStage) await fs.rm(commitStage, { recursive: true, force: true })
}

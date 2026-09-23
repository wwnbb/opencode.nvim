import * as fs from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { createRequire } from "node:module"
import { createHash } from "node:crypto"
import { spawnSync } from "node:child_process"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const source = path.join(root, "opencode_nvim/plugins/opencode-nvim")
const config = path.resolve(process.argv[2])
const target = path.join(config, "plugins/opencode-nvim")
const exists = async file => fs.access(file).then(() => true, () => false)
const digest = bytes => createHash("sha256").update(bytes).digest("hex")
await fs.mkdir(config, { recursive: true })
const stage = await fs.mkdtemp(path.join(config, ".opencode-nvim-install-"))
try {
  if (await exists(target)) {
    const pkg = JSON.parse(await fs.readFile(path.join(target, "package.json"), "utf8"))
    if (pkg.name !== "opencode-nvim-server") throw new Error(`Refusing to replace an unowned directory: ${target}`)
  }
  await fs.cp(source, stage, { recursive: true, filter: file => path.basename(file) !== "node_modules" })
  const installed = spawnSync(process.platform === "win32" ? "npm.cmd" : "npm", ["ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"], { cwd: stage, stdio: "inherit" })
  if (installed.status !== 0) throw new Error("Pinned server dependencies could not be installed; existing installation was not changed")
  const { parse, modify, applyEdits } = createRequire(path.join(stage, "package.json"))("jsonc-parser")
  const jsonc = path.join(config, "opencode.jsonc"), json = path.join(config, "opencode.json")
  if (await exists(jsonc) && await exists(json)) throw new Error("Both opencode.json and opencode.jsonc exist; consolidate them before installing the server plugin")
  const configFile = await exists(json) ? json : jsonc
  const previous = await exists(configFile) ? await fs.readFile(configFile, "utf8") : undefined
  let text = previous ?? await fs.readFile(path.join(root, "opencode_nvim/opencode.jsonc"), "utf8")
  const errors = [], value = parse(text, errors, { allowTrailingComma: true })
  if (errors.length || !value || Array.isArray(value) || typeof value !== "object") throw new Error(`Invalid JSONC: ${configFile}; existing configuration was not changed`)
  const edit = (key, next) => { text = applyEdits(text, modify(text, Array.isArray(key) ? key : [key], next, { formattingOptions: { insertSpaces: true, tabSize: 2 } })) }
  // Preserve plugin entries, comments, commands, MCP settings, and rule order.
  if (value.plugins !== undefined && !Array.isArray(value.plugins)) throw new Error("plugins must be an array")
  const entry = path.join(target, "index.ts")
  // v2 configured plugin paths name directories, never their entry files.
  const plugins = (value.plugins ?? []).map(item => [entry, "./plugins/opencode-nvim/index.ts"].includes(item) ? target : item)
  if (!plugins.some(item => [target, "./plugins/opencode-nvim"].includes(item))) plugins.push(target)
  if (JSON.stringify(plugins) !== JSON.stringify(value.plugins)) edit("plugins", plugins)
  if (value.permission !== undefined) {
    const rules = []
    const add = (action, resource, effect) => {
      if (!["allow", "ask", "deny"].includes(effect)) throw new Error("Unsupported legacy permission rule; configuration was not changed")
      rules.push({ action, resource, effect })
    }
    if (typeof value.permission === "string") add("*", "*", value.permission)
    else for (const [action, rule] of Object.entries(value.permission)) {
      if (typeof rule === "string") add(action, "*", rule)
      else for (const [resource, effect] of Object.entries(rule)) add(action, resource, effect)
    }
    if (value.permissions !== undefined && !Array.isArray(value.permissions)) throw new Error("permissions must be an array")
    edit("permissions", [...rules, ...(value.permissions ?? [])]); edit("permission", undefined)
  }
  // Rename only this tool's exact action, retaining resources, effects, order,
  // comments, and the scope of agent-specific rules. Never broaden to "edit".
  const migratePatchRules = (rules, keys) => {
    if (!Array.isArray(rules)) return
    rules.forEach((rule, index) => {
      if (rule?.action === "neovim_apply_patch") edit([...keys, index, "action"], "neovim_patch")
    })
  }
  const migrated = parse(text)
  migratePatchRules(migrated.permissions, ["permissions"])
  for (const [name, agent] of Object.entries(migrated.agents ?? {})) {
    migratePatchRules(agent?.permissions, ["agents", name, "permissions"])
  }
  // These two keys were emitted by the old bundled template, not server v2.
  if (value.theme === "opencode") edit("theme", undefined)
  if (value.$schema === "https://opencode.ai/config.json") edit("$schema", undefined)
  const backup = path.join(config, "opencode-nvim-backups", new Date().toISOString().replaceAll(":", "-") + "-" + path.basename(stage))
  await fs.mkdir(backup, { recursive: true })
  if (previous !== undefined && previous !== text) await fs.writeFile(path.join(backup, path.basename(configFile)), previous, { flag: "wx" })
  if (await exists(target)) await fs.rename(target, path.join(backup, "opencode-nvim"))
  await fs.mkdir(path.dirname(target), { recursive: true })
  await fs.rename(stage, target)
  if (previous !== text) {
    const temporary = configFile + ".opencode-nvim-new"
    await fs.writeFile(temporary, text, { flag: "wx" }); await fs.rename(temporary, configFile)
  }
  // Retire only byte-identical files from the last v1 bundled release. Modified
  // or unrelated files are left alone, even if their names happen to match.
  const legacy = JSON.parse(await fs.readFile(path.join(root, "scripts/legacy-tools-sha256.json"), "utf8"))
  for (const [relative, expected] of Object.entries(legacy)) {
    const old = path.join(config, relative)
    if (!await exists(old)) continue
    if (digest(await fs.readFile(old)) !== expected) { console.warn(`Kept modified or unowned legacy file: ${old}`); continue }
    const saved = path.join(backup, relative)
    await fs.mkdir(path.dirname(saved), { recursive: true }); await fs.rename(old, saved)
  }
  const installedPackage = JSON.parse(await fs.readFile(path.join(target, "package.json"), "utf8"))
  await fs.writeFile(path.join(target, ".opencode-nvim-install.json"), JSON.stringify({ version: installedPackage.version, configFile, backup }) + "\n")
  console.log(`opencode.nvim: v2 server plugin installed in ${target}\nPreserved previous files in ${backup}`)
} finally {
  await fs.rm(stage, { recursive: true, force: true })
}

import { afterEach, beforeEach, expect, test } from "bun:test"
import * as fs from "node:fs/promises"
import * as os from "node:os"
import * as path from "node:path"
import { externalDirectories, resolveFilePath } from "../../opencode_nvim/plugins/opencode-nvim/tools/lib/file_state"
import type { RuntimeContext } from "../../opencode_nvim/plugins/opencode-nvim/tools/lib/context"
import edit from "../../opencode_nvim/plugins/opencode-nvim/tools/neovim_edit"
import patch from "../../opencode_nvim/plugins/opencode-nvim/tools/neovim_patch"
import rg from "../../opencode_nvim/plugins/opencode-nvim/tools/rg"

let root: string, directory: string, outside: string, context: RuntimeContext, reviews: number
let authorized: string[][]
beforeEach(async () => {
  root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "opencode-path-authorization-")))
  directory = path.join(root, "project")
  outside = path.join(root, "outside")
  await fs.mkdir(directory)
  await fs.mkdir(outside)
  await fs.writeFile(path.join(directory, "source"), "before\n")
  await fs.writeFile(path.join(outside, "target"), "before\n")
  await fs.symlink(outside, path.join(directory, "linked"))
  reviews = 0
  authorized = []
  context = {
    directory, worktree: directory, sessionID: "session", messageID: "message", id: "call", agent: "build",
    signal: new AbortController().signal,
    async authorize(_action, resources) {
      const external = await externalDirectories(context.directory, resources)
      authorized.push(external)
      if (external.length) throw new Error("external_directory denied")
    },
    async progress() {},
    async review(proposal) {
      reviews++
      return { files: proposal.metadata.files.map(file => ({
        fileID: file.filePath, path: file.filePath, status: "accepted", apply: "server",
      })) }
    },
  }
})
afterEach(async () => { await fs.rm(root, { recursive: true, force: true }) })

test("canonicalizes project aliases and missing descendants without treating sibling prefixes as inside", async () => {
  const alias = path.join(root, "project-alias")
  await fs.symlink(directory, alias)
  expect(await externalDirectories(alias, [await resolveFilePath(alias, "source")])).toEqual([])
  const target = await resolveFilePath(directory, "linked/new/deep/file")
  expect(target).toBe(path.join(outside, "new/deep/file"))
  expect(await externalDirectories(alias, [target])).toEqual([path.dirname(target)])
  expect(await externalDirectories(directory, [path.join(root, "project-sibling/file")]))
    .toEqual([path.join(root, "project-sibling")])
})

for (const operation of ["edit", "update", "add", "delete", "move", "rg"] as const) {
  test(`${operation} requires external_directory for a symlinked parent before reading or reviewing it`, async () => {
    const patchText = operation === "add"
      ? "*** Begin Patch\n*** Add File: linked/new/deep/file\n+after\n*** End Patch"
      : operation === "delete"
        ? "*** Begin Patch\n*** Delete File: linked/target\n*** End Patch"
        : `*** Begin Patch\n*** Update File: ${operation === "move" ? "source\n*** Move to: linked/new/deep/file" : "linked/target"}\n@@\n-before\n+after\n*** End Patch`
    const execution = operation === "edit"
      ? edit.execute({ path: "linked/target", oldString: "before", newString: "after" }, context)
      : operation === "rg"
        ? rg.execute({ pattern: "before", path: "linked" }, context)
        : patch.execute({ patchText }, context)
    await expect(execution).rejects.toThrow("external_directory denied")
    expect(authorized).toHaveLength(1)
    expect(authorized[0].length).toBeGreaterThan(0)
    expect(reviews).toBe(0)
    expect(await fs.readFile(path.join(outside, "target"), "utf8")).toBe("before\n")
    expect(await fs.readdir(outside)).toEqual(["target"])
  })
}

for (const operation of ["edit", "patch", "rg"] as const) {
  test(`${operation} uses the authorized target after its alias changes during approval`, async () => {
    const internal = path.join(directory, "internal")
    const alias = path.join(directory, "alias")
    await fs.mkdir(internal)
    await fs.writeFile(path.join(internal, "target"), "before\n")
    await fs.symlink(internal, alias)
    context.authorize = async (_action, resources) => {
      expect(await externalDirectories(directory, resources)).toEqual([])
      expect(resources).toEqual([operation === "rg" ? internal : path.join(internal, "target")])
      await fs.unlink(alias)
      await fs.symlink(outside, alias)
    }
    const result = operation === "edit"
      ? await edit.execute({ path: "alias/target", oldString: "before", newString: "after" }, context)
      : operation === "patch"
        ? await patch.execute({ patchText: "*** Begin Patch\n*** Update File: alias/target\n@@\n-before\n+after\n*** End Patch" }, context)
        : await rg.execute({ pattern: "before", path: "alias" }, context)
    expect(await fs.readFile(path.join(outside, "target"), "utf8")).toBe("before\n")
    if (operation === "rg") {
      expect(result.content).toContain(path.join(internal, "target"))
      expect(result.content).not.toContain(outside)
    } else {
      expect(result.metadata.status).toBe("applied")
      expect(await fs.readFile(path.join(internal, "target"), "utf8")).toBe("after\n")
    }
  })
}

test("rejects a dangling parent symlink instead of treating its missing target as inside the project", async () => {
  const alias = path.join(directory, "dangling")
  await fs.symlink(path.join(outside, "missing"), alias)
  await expect(resolveFilePath(directory, "dangling/new/file")).rejects.toMatchObject({ code: "ENOENT" })
  expect(await fs.readdir(outside)).toEqual(["target"])
})

test("retains the final symlink check after resolving parent aliases", async () => {
  await fs.symlink(path.join(outside, "target"), path.join(directory, "file-link"))
  context.authorize = async () => {}
  await expect(edit.execute({ path: "file-link", oldString: "before", newString: "after" }, context))
    .rejects.toThrow("not a regular file")
  expect(reviews).toBe(0)
  expect(await fs.readFile(path.join(outside, "target"), "utf8")).toBe("before\n")
})

test("rejects recursive symlink following before authorizing a root that cannot bound the search", async () => {
  await expect(rg.execute({ pattern: "before", path: ".", follow: true }, context))
    .rejects.toThrow("pass each symbolic link target explicitly in path")
  expect(authorized).toEqual([])
})

test("ripgrep configuration cannot enable following unapproved symlinks", async () => {
  await fs.writeFile(path.join(outside, "target"), "EXTERNAL_SECRET\n")
  const config = path.join(root, "ripgrep.config")
  await fs.writeFile(config, "--follow\n")
  const previous = process.env.RIPGREP_CONFIG_PATH
  process.env.RIPGREP_CONFIG_PATH = config
  try {
    const result = await rg.execute({ pattern: "EXTERNAL_SECRET", path: "." }, context)
    expect(authorized).toEqual([[]])
    expect(result.content).toBe("No matches found.")
  } finally {
    if (previous === undefined) delete process.env.RIPGREP_CONFIG_PATH
    else process.env.RIPGREP_CONFIG_PATH = previous
  }
})

test("approved creation uses the canonical missing path through a linked parent", async () => {
  const target = path.join(outside, "new/deep/file")
  context.authorize = async (_action, resources) => {
    expect(resources).toEqual([target])
    expect(await externalDirectories(directory, resources)).toEqual([path.dirname(target)])
  }
  const result = await patch.execute({ patchText: "*** Begin Patch\n*** Add File: linked/new/deep/file\n+after\n*** End Patch" }, context)
  expect(result.metadata.status).toBe("applied")
  expect(await fs.readFile(target, "utf8")).toBe("after\n")
})

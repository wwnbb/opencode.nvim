import { afterEach, beforeEach, expect, test } from "bun:test"
import * as fs from "node:fs/promises"
import * as os from "node:os"
import * as path from "node:path"

const { default: patch } = await import("../../opencode_nvim/plugins/opencode-nvim/tools/neovim_apply_patch")
const root = path.resolve(import.meta.dir, "../..")
let directory: string
beforeEach(async () => { directory = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-patch-test-")) })
afterEach(async () => { await fs.rm(directory, { recursive: true, force: true }) })

function rejected(): never { throw new Error("review rejected") }

function context(review: (request: any) => Promise<any>) {
  return { directory, worktree: directory, sessionID: "test", messageID: "test", id: "call", agent: "build",
    signal: new AbortController().signal, async authorize() {}, async progress() {}, async review(request: any) {
      let result: any
      try { result = await review(request) } catch (error: any) {
        if (error.message !== "review rejected") throw error
        result = request.metadata.files.map(() => "reject")
      }
      return { files: request.metadata.files.map((file: any, index: number) => ({
        fileID: String(index), path: file.filePath, status: result?.[index] === "reject" ? "rejected" : "accepted",
        apply: result ? "client" : "server",
      })) }
    } } as any
}

async function review(request: any, actions: string[]) {
  const payload = path.join(directory, "review.json")
  await fs.writeFile(payload, JSON.stringify({ request: { ...request, permission: request.tool, id: "review", sessionID: "test" }, actions }))
  const result = Bun.spawnSync(["nvim", "--headless", "-i", "NONE", "-u", "NONE", "-l", path.join(import.meta.dir, "review.lua")], {
    env: { ...process.env, OPENCODE_TEST_ROOT: root, OPENCODE_TEST_REVIEW: payload, NVIM_LOG_FILE: path.join(directory, "nvim.log") },
  })
  expect(result.stderr.toString()).not.toContain("E5113")
  expect(result.exitCode).toBe(0)
  return actions
}

async function exists(file: string) {
  return fs.stat(path.join(directory, file)).then(() => true, () => false)
}

for (const content of ["", "original\n"]) {
  test(`rejected deletion preserves ${JSON.stringify(content)}`, async () => {
    await fs.writeFile(path.join(directory, "keep"), content)
    const result = await patch.execute({ patchText: "*** Begin Patch\n*** Delete File: keep\n*** End Patch" }, context(async (request) => review(request, ["reject"])))
    expect(await fs.readFile(path.join(directory, "keep"), "utf8")).toBe(content)
    expect(result.metadata.status).toBe("rejected")
  })

  test(`accepted deletion removes ${JSON.stringify(content)}`, async () => {
    await fs.writeFile(path.join(directory, "remove"), content)
    const result = await patch.execute({ patchText: "*** Begin Patch\n*** Delete File: remove\n*** End Patch" }, context(async (request) => review(request, ["accept"])))
    expect(await exists("remove")).toBe(false)
    expect(result.metadata.status).toBe("applied")
  })
}

test("mixed review preserves a rejected empty file and applies the accepted edit", async () => {
  await fs.writeFile(path.join(directory, "keep"), "")
  await fs.writeFile(path.join(directory, "update"), "before\n")
  const result = await patch.execute({ patchText: "*** Begin Patch\n*** Delete File: keep\n*** Update File: update\n@@\n-before\n+after\n*** End Patch" }, context(async (request) => review(request, ["reject", "accept"])))
  expect(await exists("keep")).toBe(true)
  expect(await fs.readFile(path.join(directory, "update"), "utf8")).toBe("after\n")
  expect(result.metadata.status).toBe("partial")
})

test("rejection does not remove an empty file created externally during review", async () => {
  const result = await patch.execute({ patchText: "*** Begin Patch\n*** Add File: external\n+proposed\n*** End Patch" }, context(async () => {
    await fs.writeFile(path.join(directory, "external"), "")
    rejected()
  }))
  expect(await exists("external")).toBe(true)
  expect(result.metadata.status).toBe("partial")
})

test("accepted update preserves BOM through the Lua review path", async () => {
  await fs.writeFile(path.join(directory, "bom"), "\ufeffbefore\n")
  const result = await patch.execute({ patchText: "*** Begin Patch\n*** Update File: bom\n@@\n-before\n+after\n*** End Patch" }, context(async (request) => review(request, ["accept"])))
  expect(await fs.readFile(path.join(directory, "bom"), "utf8")).toBe("\ufeffafter\n")
  expect(result.metadata.status).toBe("applied")
})

test("accepted move preserves source BOM when replacing an existing destination", async () => {
  await fs.writeFile(path.join(directory, "source"), "\ufeffbefore\n")
  await fs.writeFile(path.join(directory, "destination"), "existing\n")
  const result = await patch.execute({ patchText: "*** Begin Patch\n*** Update File: source\n*** Move to: destination\n@@\n-before\n+after\n*** End Patch" }, context(async (request) => review(request, ["accept", "accept"])))
  expect(await exists("source")).toBe(false)
  expect(await fs.readFile(path.join(directory, "destination"), "utf8")).toBe("\ufeffafter\n")
  expect(result.metadata.status).toBe("applied")
})

test("rejected move leaves an empty source and its destination untouched", async () => {
  await fs.writeFile(path.join(directory, "source"), "")
  await fs.writeFile(path.join(directory, "destination"), "\n")
  const result = await patch.execute({ patchText: "*** Begin Patch\n*** Update File: source\n*** Move to: destination\n*** End Patch" }, context(async () => rejected()))
  expect(await fs.readFile(path.join(directory, "source"), "utf8")).toBe("")
  expect(await fs.readFile(path.join(directory, "destination"), "utf8")).toBe("\n")
  expect(result.metadata.status).toBe("rejected")
})

test("server-side approval still applies a deletion when the client did not write", async () => {
  await fs.writeFile(path.join(directory, "remove"), "")
  const result = await patch.execute({ patchText: "*** Begin Patch\n*** Delete File: remove\n*** End Patch" }, context(async () => {}))
  expect(await exists("remove")).toBe(false)
  expect(result.metadata.status).toBe("applied")
})

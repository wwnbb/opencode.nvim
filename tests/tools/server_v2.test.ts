import { afterEach, beforeEach, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import * as fs from "node:fs/promises"
import * as os from "node:os"
import * as path from "node:path"
import { Reviews } from "../../opencode_nvim/plugins/opencode-nvim/review"
import { replyInput } from "../../opencode_nvim/plugins/opencode-nvim/rpc"
import edit from "../../opencode_nvim/plugins/opencode-nvim/tools/neovim_edit"
import patch from "../../opencode_nvim/plugins/opencode-nvim/tools/neovim_apply_patch"
import rg from "../../opencode_nvim/plugins/opencode-nvim/tools/rg"
let directory: string, reviews: Reviews, controller: AbortController, events: any[], context: any
beforeEach(async () => {
  directory = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-v2-tools-"))
  events = []; controller = new AbortController()
  reviews = new Reviews({ directory }, async (type, review) => { events.push({ type, review }) })
  context = { directory, worktree: directory, sessionID: "s", messageID: "m", id: "call", agent: "build", signal: controller.signal,
    async authorize() {}, async progress() {}, review: (proposal: any) => reviews.wait(context, proposal) }
})
afterEach(async () => { reviews.dispose(); await fs.rm(directory, { recursive: true, force: true }) })
async function pending() {
  for (let i = 0; i < 100; i++) {
    const record = reviews.list("s")[0]
    if (record) return record
    await new Promise(resolve => setTimeout(resolve, 1))
  }
  throw new Error("Missing review")
}
function reply(record: any, decisions: any[]) {
  return replyInput.parse({ protocolVersion: 1, sessionID: "s", reviewID: record.reviewID, revision: record.revision, decisions })
}
const sha = (bytes: string) => createHash("sha256").update(bytes).digest("hex")

test("RPC reply validates scope, revision and exact file IDs before settlement", async () => {
  await fs.writeFile(path.join(directory, "a"), "before")
  const execution = edit.execute({ filePath: "a", oldString: "before", newString: "after" }, context)
  const record = await pending()
  const input = reply(record, [{ fileID: record.files[0].fileID, status: "accepted", apply: "server" }])
  await expect(reviews.reply({ ...input, sessionID: "other" })).rejects.toMatchObject({ code: "not_found" })
  await expect(reviews.reply({ ...input, revision: 2 })).rejects.toMatchObject({ code: "conflict" })
  await expect(reviews.reply({ ...input, decisions: [] })).rejects.toMatchObject({ code: "conflict" })
  expect(reviews.list("s")).toHaveLength(1)
  const admission = await reviews.reply(input)
  const duplicate = await reviews.reply(input)
  expect(admission).toEqual(duplicate)
  await expect(reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "rejected" }]))).rejects.toMatchObject({ code: "conflict" })
  const result = await execution
  expect(result.metadata.status).toBe("applied")
  expect(result.metadata.wrote).toBe(true)
  await reviews.finish("s", "call", result.metadata)
  expect(reviews.get("s", record.reviewID).status).toBe("settled")
  expect(events.filter(e => e.type === "reviewCreated")).toHaveLength(1)
})

test("interruption while awaiting review rejects late replies and cannot write files", async () => {
  const file = path.join(directory, "a")
  await fs.writeFile(file, "\ufeffbefore\r\n")
  const execution = edit.execute({ filePath: "a", oldString: "before", newString: "after" }, context)
  void execution.catch(() => {})
  const record = await pending()
  controller.abort()
  await expect(execution).rejects.toBeDefined()
  await expect(reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "accepted", apply: "server" }]))).rejects.toMatchObject({ code: "conflict" })
  expect(await fs.readFile(file, "utf8")).toBe("\ufeffbefore\r\n")
  expect(reviews.get("s", record.reviewID).status).toBe("cancelled")
})

test("mixed explicit decisions apply only accepted files and preserve rejected files", async () => {
  await fs.writeFile(path.join(directory, "a"), "before\n")
  await fs.writeFile(path.join(directory, "b"), "before\n")
  const execution = patch.execute({ patchText: "*** Begin Patch\n*** Update File: a\n@@\n-before\n+after\n*** Update File: b\n@@\n-before\n+after\n*** End Patch" }, context)
  const record = await pending()
  await reviews.reply(reply(record, record.files.map((file, i) => ({ fileID: file.fileID, status: i === 0 ? "accepted" : "rejected", apply: "server" }))))
  expect(record).toStrictEqual(JSON.parse(JSON.stringify(record)))
  const result = await execution
  expect(result.metadata.status).toBe("partial")
  expect(await fs.readFile(path.join(directory, "a"), "utf8")).toBe("after\n")
  expect(await fs.readFile(path.join(directory, "b"), "utf8")).toBe("before\n")
  await reviews.finish("s", "call", result.metadata)
  const settled = reviews.get("s", record.reviewID)
  expect(settled).toStrictEqual(JSON.parse(JSON.stringify(settled)))
})

test("manual resolution requires matching observed bytes and is never overwritten", async () => {
  const file = path.join(directory, "a")
  await fs.writeFile(file, "before")
  const execution = edit.execute({ filePath: "a", oldString: "before", newString: "after" }, context)
  const record = await pending()
  const choice = { fileID: record.files[0].fileID, status: "resolved", observed: { exists: true, sha256: sha("manual") } }
  await expect(reviews.reply(reply(record, [choice]))).rejects.toMatchObject({ code: "conflict" })
  await fs.writeFile(file, "manual")
  await reviews.reply(reply(record, [choice]))
  const result = await execution
  expect(result.metadata.status).toBe("partial")
  expect(result.metadata.divergence).toBe("client_resolved")
  expect(await fs.readFile(file, "utf8")).toBe("manual")
})

test("rejected add preserves an externally created empty file", async () => {
  const execution = edit.execute({ filePath: "new", oldString: "", newString: "proposed" }, context)
  const record = await pending()
  await fs.writeFile(path.join(directory, "new"), "")
  await reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "rejected" }]))
  await execution
  expect(await fs.readFile(path.join(directory, "new"), "utf8")).toBe("")
})

test("an external BOM/EOL-only change prevents server overwrite", async () => {
  const file = path.join(directory, "a")
  await fs.writeFile(file, "before\n")
  const execution = edit.execute({ filePath: "a", oldString: "before", newString: "after" }, context)
  const record = await pending()
  await fs.writeFile(file, "\ufeffbefore\r\n")
  await reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "accepted", apply: "server" }]))
  const result = await execution
  expect(result.metadata.wrote).toBe(false)
  expect(await fs.readFile(file, "utf8")).toBe("\ufeffbefore\r\n")
})

test("rg uses the execution directory, escaped argv, bounded output and correct errors", async () => {
  await fs.writeFile(path.join(directory, "путь %.txt"), "-needle\nsecond\n")
  const match = await rg.execute({ pattern: "-needle", path: ".", fixed_strings: true }, context)
  expect(match.content).toContain("-needle")
  expect(match.metadata.exitCode).toBe(0)
  const empty = await rg.execute({ pattern: "absent", path: "." }, context)
  expect(empty.content).toBe("No matches found.")
  await expect(rg.execute({ pattern: "[", path: "." }, context)).rejects.toThrow("ripgrep failed")
  const limited = await rg.execute({ pattern: ".", path: ".", max_results: 1 }, context)
  expect(limited.metadata.truncated).toBe(true)
  controller.abort()
  await expect(rg.execute({ pattern: "." }, context)).rejects.toBeDefined()
})

test("native policy requires the exact evaluation and its final effect", async () => {
  const { Policies } = await import("../../opencode_nvim/plugins/opencode-nvim/policy")
  const policies = new Policies({ directory }, async () => {})
  const execution = policies.wait(context, "neovim_edit", ["/a", "/b"])
  void execution.catch(() => {})
  const record = policies.list("s")[0]
  const confirm = { sessionID: "s", gateID: record.gateID }
  expect(() => policies.confirm(confirm)).toThrow("has not authorized")
  const evaluation: any = { ...record.request, sessionID: "s", effect: "allow" }
  policies.evaluated({ ...evaluation, resources: ["/a"] })
  expect(() => policies.confirm(confirm)).toThrow("has not authorized")
  policies.evaluated({ ...evaluation, agent: "different" })
  expect(() => policies.confirm(confirm)).toThrow("has not authorized")
  policies.evaluated(evaluation)
  // A later native plugin can veto; retaining the mutable public hook input is
  // essential. Confirm only follows the completed HTTP permission evaluation.
  evaluation.effect = "deny"
  expect(policies.confirm(confirm).status).toBe("denied")
  await expect(execution).rejects.toThrow("denied")
  policies.dispose()
})

test("native ask waits for its own native reply and cannot be replaced by RPC allow", async () => {
  const { Policies } = await import("../../opencode_nvim/plugins/opencode-nvim/policy")
  const policies = new Policies({ directory }, async () => {})
  const execution = policies.wait(context, "rg", [directory])
  const record = policies.list("s")[0]
  policies.evaluated({ ...record.request, sessionID: "s", effect: "ask" } as any)
  const confirm = { sessionID: "s", gateID: record.gateID }
  expect(() => policies.confirm(confirm)).toThrow("has not authorized")
  policies.event({ type: "permission.asked", data: { ...record.request, sessionID: "s" } })
  expect(policies.confirm(confirm).status).toBe("pending")
  policies.event({ type: "permission.replied", data: { sessionID: "other", requestID: record.request.id, reply: "once" } })
  expect(policies.confirm(confirm).status).toBe("pending")
  policies.event({ type: "permission.replied", data: { sessionID: "s", requestID: record.request.id, reply: "once" } })
  await execution
  expect(policies.confirm(confirm).status).toBe("allowed")
  policies.dispose()
})

test("native allow continues, explicit deny without a hook and interruption fail closed", async () => {
  const { Policies } = await import("../../opencode_nvim/plugins/opencode-nvim/policy")
  const policies = new Policies({ directory }, async () => {})
  const allowed = policies.wait(context, "rg", [directory])
  let record = policies.list("s")[0]
  policies.evaluated({ ...record.request, sessionID: "s", effect: "allow" } as any)
  policies.confirm({ sessionID: "s", gateID: record.gateID })
  await allowed
  const denied = policies.wait(context, "neovim_edit", [directory]); void denied.catch(() => {})
  record = policies.list("s")[0]
  policies.confirm({ sessionID: "s", gateID: record.gateID, denied: true })
  await expect(denied).rejects.toThrow("denied")
  const interrupted = policies.wait(context, "rg", [directory]); void interrupted.catch(() => {})
  record = policies.list("s")[0]
  controller.abort()
  policies.event({ type: "permission.asked", data: { ...record.request, sessionID: "s" } })
  policies.event({ type: "permission.replied", data: { sessionID: "s", requestID: record.request.id, reply: "always" } })
  await expect(interrupted).rejects.toThrow("cancelled")
  expect(policies.confirm({ sessionID: "s", gateID: record.gateID }).status).toBe("cancelled")
  policies.dispose()
})

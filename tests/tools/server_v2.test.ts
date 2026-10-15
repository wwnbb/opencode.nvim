import { afterEach, beforeEach, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import * as fs from "node:fs/promises"
import * as os from "node:os"
import * as path from "node:path"
import { Reviews } from "../../opencode_nvim/plugins/opencode-nvim/review"
import { replyInput } from "../../opencode_nvim/plugins/opencode-nvim/rpc"
import edit from "../../opencode_nvim/plugins/opencode-nvim/tools/neovim_edit"
import patch from "../../opencode_nvim/plugins/opencode-nvim/tools/neovim_patch"
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
function reply(record: any, decisions: any[], message?: string) {
  return replyInput.parse({ protocolVersion: 2, sessionID: "s", reviewID: record.reviewID, revision: record.revision, decisions, message })
}
const sha = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex")

test("server plugin entry loads with its runtime dependencies", async () => {
  const { default: plugin } = await import("../../opencode_nvim/plugins/opencode-nvim/index")
  expect(plugin.id).toBe("opencode_nvim")
  expect(typeof plugin.effect).toBe("function")
})

test("edit rejects an existing symlink before creating a review", async () => {
  const target = path.join(directory, "target")
  await fs.writeFile(target, "before\n")
  await fs.symlink(target, path.join(directory, "a"))
  await expect(edit.execute({ path: "a", oldString: "before", newString: "after" }, context))
    .rejects.toThrow("not a regular file")
  expect(reviews.list("s")).toHaveLength(0)
  expect(await fs.readFile(target, "utf8")).toBe("before\n")
})

for (const operation of ["edit", "update", "add", "move"] as const) {
  test(`${operation} cannot follow a symlink substituted during review`, async () => {
    const file = path.join(directory, "a")
    const target = path.join(directory, "target")
    const replaced = operation === "move" ? path.join(directory, "destination") : file
    if (operation !== "add") {
      await fs.writeFile(file, "before\n")
      await fs.writeFile(target, "before\n")
    }
    if (operation === "move") await fs.writeFile(replaced, "before\n")
    const patchText = operation === "add"
      ? "*** Begin Patch\n*** Add File: a\n+after\n*** End Patch"
      : `*** Begin Patch\n*** Update File: a\n${operation === "move" ? "*** Move to: destination\n" : ""}@@\n-before\n+after\n*** End Patch`
    const execution = operation === "edit"
      ? edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
      : patch.execute({ patchText }, context)
    void execution.catch(() => {})
    const record = await pending()
    if (operation !== "add") await fs.unlink(replaced)
    await fs.symlink(target, replaced)
    await reviews.reply(reply(record, record.files.map(file => ({
      fileID: file.fileID, status: "accepted", apply: "server",
    }))))
    await expect(execution).rejects.toThrow("not a regular file")
    expect(await fs.readlink(replaced)).toBe(target)
    if (operation === "add") {
      await expect(fs.stat(target)).rejects.toMatchObject({ code: "ENOENT" })
    } else {
      expect(await fs.readFile(target, "utf8")).toBe("before\n")
    }
    if (operation === "move") expect(await fs.readFile(file, "utf8")).toBe("before\n")
  })
}

test("RPC reply validates scope, revision and exact file IDs before settlement", async () => {
  await fs.writeFile(path.join(directory, "a"), "before")
  const execution = edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
  const record = await pending()
  const input = reply(record, [{ fileID: record.files[0].fileID, status: "accepted", apply: "server" }], "  Keep this note.\n  ")
  expect(input.message).toBe("Keep this note.")
  await expect(reviews.reply({ ...input, sessionID: "other" })).rejects.toMatchObject({ code: "not_found" })
  await expect(reviews.reply({ ...input, revision: 2 })).rejects.toMatchObject({ code: "conflict" })
  await expect(reviews.reply({ ...input, decisions: [] })).rejects.toMatchObject({ code: "conflict" })
  expect(reviews.list("s")).toHaveLength(1)
  const admission = await reviews.reply(input)
  const duplicate = await reviews.reply(input)
  expect(admission).toEqual(duplicate)
  await expect(reviews.reply({ ...input, message: "different feedback" })).rejects.toMatchObject({ code: "conflict" })
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
  const execution = edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
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
  const execution = edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
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

for (const dangling of [false, true]) {
  test(`client reply refuses a ${dangling ? "dangling" : "regular"} symlink and keeps the review retryable`, async () => {
    const file = path.join(directory, "a")
    const target = path.join(directory, "target")
    await fs.writeFile(file, "before")
    const execution = edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
    void execution.catch(() => {})
    const record = await pending()
    await fs.unlink(file)
    if (!dangling) await fs.writeFile(target, "after")
    await fs.symlink(target, file)
    const choice = { fileID: record.files[0].fileID, status: "accepted", apply: "client",
      observed: dangling ? { exists: false } : { exists: true, sha256: sha("after") } }
    await expect(reviews.reply(reply(record, [choice]))).rejects.toThrow("not a regular file")
    expect(reviews.get("s", record.reviewID).status).toBe("pending")
    expect(await fs.readlink(file)).toBe(target)
    await fs.unlink(file)
    await fs.writeFile(file, "after")
    await reviews.reply(reply(record, [{ ...choice, observed: { exists: true, sha256: sha("after") } }]))
    expect((await execution).metadata.status).toBe("applied")
  })
}

for (const bytes of [Buffer.alloc(0), Buffer.from("\ufeffafter\r\n"), Buffer.from([0xff, 0, 0x0d, 0x0a])]) {
  test(`client observation confirms raw bytes ${bytes.toString("hex") || "empty"}`, async () => {
    const file = path.join(directory, "a")
    await fs.writeFile(file, "before")
    const execution = edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
    const record = await pending()
    await fs.writeFile(file, bytes)
    await reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "resolved", apply: "client",
      observed: { exists: true, sha256: sha(bytes) } }]))
    await execution
    expect(await fs.readFile(file)).toEqual(bytes)
  })
}

test("client observation confirms a removed file", async () => {
  const file = path.join(directory, "a")
  await fs.writeFile(file, "before\n")
  const execution = patch.execute({ patchText: "*** Begin Patch\n*** Delete File: a\n*** End Patch" }, context)
  const record = await pending()
  await fs.unlink(file)
  await reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "accepted", apply: "client", observed: { exists: false } }]))
  expect((await execution).metadata.status).toBe("applied")
})

test("rejected add preserves an externally created empty file", async () => {
  const execution = patch.execute({ patchText: "*** Begin Patch\n*** Add File: new\n+proposed\n*** End Patch" }, context)
  const record = await pending()
  await fs.writeFile(path.join(directory, "new"), "")
  await reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "rejected" }]))
  expect((await execution).metadata.status).toBe("partial")
  expect(await fs.readFile(path.join(directory, "new"), "utf8")).toBe("")
})

test("an external BOM/EOL-only change prevents server overwrite", async () => {
  const file = path.join(directory, "a")
  await fs.writeFile(file, "before\n")
  const execution = edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
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

test("failed permission publication cancels its gate and detaches cancellation", async () => {
  const { Policies } = await import("../../opencode_nvim/plugins/opencode-nvim/policy")
  const emitted: string[] = []
  let requested: any
  const policies = new Policies({ directory }, async (type, record) => {
    emitted.push(type)
    if (type === "policyRequested") requested = record
    throw new Error("event publication failed")
  })
  try {
    await expect(policies.wait(context, "neovim_edit", [directory])).rejects.toThrow("event publication failed")
    expect(policies.list("s")).toHaveLength(0)
    expect(policies.confirm({ sessionID: "s", gateID: requested.gateID }).status).toBe("cancelled")
    controller.abort()
    expect(emitted).toEqual(["policyRequested", "policySettled"])
  } finally { policies.dispose() }
})

test("failed review publication cancels its entry and detaches cancellation", async () => {
  const emitted: string[] = []
  let requested: any
  const failedReviews = new Reviews({ directory }, async (type, record) => {
    emitted.push(type)
    if (type === "reviewCreated") requested = record
    throw new Error("event publication failed")
  })
  try {
    await expect(failedReviews.wait(context, { tool: "neovim_edit", metadata: {
      files: [{ filePath: path.join(directory, "a"), type: "update", before: "before", after: "after" }],
    } })).rejects.toThrow("event publication failed")
    expect(failedReviews.list("s")).toHaveLength(0)
    expect(failedReviews.get("s", requested.reviewID).status).toBe("cancelled")
    controller.abort()
    expect(emitted).toEqual(["reviewCreated", "reviewCancelled"])
  } finally { failedReviews.dispose() }
})

for (const settlementFailure of [false, true]) {
  test(`review history stays bounded after ${settlementFailure ? "failed settlement events" : "cancellations"} and preserves pending reviews`, async () => {
    if (settlementFailure) reviews = new Reviews({ directory }, async (type, record) => {
      events.push({ type, review: record })
      if (type === "reviewSettled") throw new Error("settlement publication failed")
    })
    const proposal = { tool: "neovim_edit", metadata: {
      files: [{ filePath: path.join(directory, "a"), type: "update", before: "before", after: "after" }],
    } }
    const live = reviews.wait(context, proposal)
    void live.catch(() => {})
    const record = await pending()
    const ids: string[] = []
    for (let i = 0; i < 520; i++) {
      const call = { ...context, id: `history-${i}` }
      const waiting = reviews.wait(call, proposal)
      const current = reviews.list("s").find(review => review.callID === call.id)!
      ids.push(current.reviewID)
      if (settlementFailure) {
        await reviews.reply(reply(current, [{ fileID: current.files[0].fileID, status: "rejected" }]))
        await waiting
        await expect(reviews.finish("s", call.id, { status: "rejected" })).rejects.toThrow("settlement publication failed")
      } else {
        reviews.cancel(current.reviewID)
        await expect(waiting).rejects.toThrow("Review cancelled")
      }
    }
    let retained = 0
    for (const id of ids) {
      try { reviews.get("s", id); retained++ }
      catch (error) { expect(error).toMatchObject({ code: "not_found" }) }
    }
    expect(retained).toBeLessThanOrEqual(512)
    expect(reviews.get("s", ids.at(-1)!).status).toBe(settlementFailure ? "settled" : "cancelled")
    expect(reviews.list("s")).toHaveLength(1)
    expect(reviews.get("s", record.reviewID).status).toBe("pending")
    await reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "rejected" }]))
    expect((await live).files[0].status).toBe("rejected")
  })
}

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

for (const name of ["neovim_edit", "neovim_patch"] as const) {
  for (const status of ["accepted", "rejected", "resolved"] as const) {
    test(`${name} returns ${status} review feedback to the model and history exactly once`, async () => {
      const file = path.join(directory, "notes.txt")
      await fs.writeFile(file, "before\n")
      const execution = name === "neovim_edit"
        ? edit.execute({ path: "notes.txt", oldString: "before", newString: "after" }, context)
        : patch.execute({ patchText: "*** Begin Patch\n*** Update File: notes.txt\n@@\n-before\n+after\n*** End Patch" }, context)
      const record = await pending()
      expect(record.tool).toBe(name)
      expect(await fs.readFile(file, "utf8")).toBe("before\n")
      const message = "смешные, можешь еще парочку добавить?\nСохрани мои правки."
      if (status === "resolved") await fs.writeFile(file, "manual\n")
      const input = reply(record, [{ fileID: record.files[0].fileID, status,
        apply: status === "resolved" ? "client" : "server",
        ...(status === "resolved" ? { observed: { exists: true, sha256: sha("manual\n") } } : {}),
      }], message)
      await reviews.reply(input)
      const result = await execution
      expect(result.content.split(message)).toHaveLength(2)
      expect(result.metadata.review_message).toBe(message)
      expect(result.metadata.status).toBe(status === "accepted" ? "applied" : status === "resolved" ? "partial" : "rejected")
      expect(await fs.readFile(file, "utf8")).toBe(status === "accepted" ? "after\n" : status === "resolved" ? "manual\n" : "before\n")
      await reviews.finish("s", "call", result.metadata)
      const settled = reviews.get("s", record.reviewID)
      expect(settled.message).toBe(message)
      expect(settled.outcome?.review_message).toBe(message)
      expect(settled).toStrictEqual(JSON.parse(JSON.stringify(settled)))
      expect(events.filter(e => e.type === "reviewSettled")).toHaveLength(1)
    })
  }
}

test("mixed patch decisions retain feedback", async () => {
  const execution = patch.execute({ patchText: "*** Begin Patch\n*** Add File: a\n+one\n*** Add File: b\n+two\n*** End Patch" }, context)
  const record = await pending()
  await reviews.reply(reply(record, record.files.map((f, i) => ({ fileID: f.fileID, status: i === 0 ? "accepted" : "rejected", apply: "server" })), "keep only a"))
  const result = await execution
  expect(result.metadata.status).toBe("partial")
  expect(result.content).toContain("keep only a")
  expect(await fs.readFile(path.join(directory, "a"), "utf8")).toBe("one\n")
  expect(await fs.access(path.join(directory, "b")).then(() => true, () => false)).toBe(false)
})

test("whitespace-only feedback is absent and protocol 1 cannot silently lose notes", async () => {
  await fs.writeFile(path.join(directory, "a"), "before")
  const execution = edit.execute({ path: "a", oldString: "before", newString: "after" }, context)
  const record = await pending()
  const input = reply(record, [{ fileID: record.files[0].fileID, status: "accepted", apply: "server" }], "  \n ")
  expect(() => replyInput.parse({ ...input, protocolVersion: 1, message: "do not drop" })).toThrow()
  await reviews.reply(input)
  const result = await execution
  expect(result.metadata.review_message).toBeUndefined()
  expect(result.content).not.toContain("User feedback")
  expect(reviews.get("s", record.reviewID).message).toBeUndefined()
})

test("v2 edit accepts path and refuses creation, empty matches, no-ops and ambiguous matches before review", async () => {
  expect(edit.input.safeParse({ path: "a", oldString: "before", newString: "after" }).success).toBe(true)
  expect(edit.input.safeParse({ filePath: "a", oldString: "before", newString: "after" }).success).toBe(false)
  expect(edit.input.safeParse({ path: "a", oldString: "", newString: "after" }).success).toBe(false)
  await expect(edit.execute({ path: "new", oldString: "before", newString: "after" }, context)).rejects.toThrow("not found")
  await expect(edit.execute({ path: "new", oldString: "", newString: "after" }, context)).rejects.toThrow("oldString must not be empty")
  await fs.writeFile(path.join(directory, "a"), "before before")
  await expect(edit.execute({ path: "a", oldString: "", newString: "overwrite" }, context)).rejects.toThrow("oldString must not be empty")
  await expect(edit.execute({ path: "a", oldString: "before", newString: "before" }, context)).rejects.toThrow("identical")
  await expect(edit.execute({ path: "a", oldString: "before", newString: "after" }, context)).rejects.toThrow("multiple matches")
  expect(reviews.list("s")).toHaveLength(0)
  expect(await fs.readFile(path.join(directory, "a"), "utf8")).toBe("before before")
  expect(await fs.access(path.join(directory, "new")).then(() => true, () => false)).toBe(false)
})

test("v2 edit replaceAll preserves literal replacement text, BOM and CRLF", async () => {
  const file = path.join(directory, "a")
  await fs.writeFile(file, "\ufeffbefore\r\nbefore\r\n")
  const execution = edit.execute({ path: "a", oldString: "before\n", newString: "$&after\n", replaceAll: true }, context)
  const record = await pending()
  await reviews.reply(reply(record, [{ fileID: record.files[0].fileID, status: "accepted", apply: "server" }]))
  expect((await execution).metadata.status).toBe("applied")
  expect(await fs.readFile(file, "utf8")).toBe("\ufeff$&after\r\n$&after\r\n")
})

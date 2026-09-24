import { createHash, randomUUID } from "node:crypto"
import { readFile } from "node:fs/promises"
import { jsonValue } from "./json"
import { protocolVersion, type Review, type Decision } from "./rpc"
import type { RuntimeContext, ReviewDecision, ReviewProposal } from "./tools/lib/context"

export class ReviewError extends Error {
  constructor(readonly code: "conflict" | "not_found", message: string, readonly current?: Review) { super(message) }
}
type Entry = { record: Review; signature: string; promise: Promise<ReviewDecision>;
  resolve(value: ReviewDecision): void; reject(error: Error): void; detach(): void; reply?: string }
export class Reviews {
  private readonly instance = randomUUID()
  private readonly entries = new Map<string, Entry>()
  constructor(private readonly location: { directory: string }, private readonly emit: (type: "reviewCreated" | "reviewSettled" | "reviewCancelled", record: Review) => Promise<void>) {}
  list(sessionID?: string) { return [...this.entries.values()].filter(e => e.record.status === "pending" && (!sessionID || e.record.sessionID === sessionID)).map(e => structuredClone(e.record)) }
  get(sessionID: string, reviewID: string) {
    const entry = this.entries.get(reviewID)
    if (!entry || entry.record.sessionID !== sessionID) throw new ReviewError("not_found", "Review not found", undefined)
    return structuredClone(entry.record)
  }
  async wait(context: RuntimeContext, proposal: ReviewProposal): Promise<ReviewDecision> {
    context.signal.throwIfAborted()
    const reviewID = "rev_" + createHash("sha256").update(`${this.instance}\0${context.sessionID}\0${context.id}`).digest("hex").slice(0, 32)
    const signature = JSON.stringify(proposal)
    const previous = this.entries.get(reviewID)
    if (previous) {
      if (previous.signature !== signature) throw new ReviewError("conflict", "Tool call reused with a different proposal", previous.record)
      return previous.promise
    }
    const record: Review = jsonValue({ protocolVersion, reviewID, revision: 1, status: "pending", created: Date.now(),
      sessionID: context.sessionID, messageID: context.messageID, callID: context.id,
      tool: proposal.tool, agent: context.agent, directory: context.directory, location: this.location,
      files: proposal.metadata.files.map((file, i) => ({ ...file, fileID: `file_${i}_${createHash("sha256").update(file.filePath + "\0" + file.type).digest("hex").slice(0, 12)}` })),
      metadata: proposal.metadata })
    let resolve!: Entry["resolve"], reject!: Entry["reject"]
    const promise = new Promise<ReviewDecision>((yes, no) => { resolve = yes; reject = no })
    // Cancellation may precede the first await while emitting the proposal.
    void promise.catch(() => {})
    const cancel = () => this.cancel(reviewID)
    const entry: Entry = { record, signature, promise, resolve, reject, detach: () => context.signal.removeEventListener("abort", cancel) }
    this.entries.set(reviewID, entry)
    context.signal.addEventListener("abort", cancel, { once: true })
    if (context.signal.aborted) cancel()
    if (record.status === "pending") await this.emit("reviewCreated", structuredClone(record))
    return promise
  }
  async reply(input: { sessionID: string; reviewID: string; revision: number; decisions: Decision[]; message?: string }) {
    const current = this.get(input.sessionID, input.reviewID)
    const entry = this.entries.get(input.reviewID)!
    const decisions = [...input.decisions].sort((a, b) => a.fileID.localeCompare(b.fileID))
    const message = input.message?.trim() || undefined
    const signature = JSON.stringify({ decisions, message })
    const conflict = (message: string): never => { throw new ReviewError("conflict", message, structuredClone(entry.record)) }
    if (input.revision !== current.revision) conflict("Review revision changed")
    if (entry.record.status !== "pending") {
      if (entry.record.status !== "cancelled" && entry.reply === signature) return structuredClone(entry.record)
      conflict("Review has already completed or was cancelled")
    }
    const ids = new Set(decisions.map(d => d.fileID))
    if (ids.size !== decisions.length || decisions.length !== current.files.length || current.files.some(f => !ids.has(f.fileID))) conflict("Reply must contain each review file exactly once")
    for (const choice of decisions) {
      if (choice.status === "resolved" && choice.apply === "server") conflict("Manual resolution cannot request server apply")
      if (choice.status !== "rejected" && choice.apply === "client") {
        if (!choice.observed) conflict("Client-applied decisions require observed file bytes")
        const file = current.files.find(f => f.fileID === choice.fileID)!
        let bytes: Buffer | undefined
        try { bytes = await readFile(file.filePath) } catch (error: any) { if (error.code !== "ENOENT") throw error }
        const actual = bytes ? { exists: true, sha256: createHash("sha256").update(bytes).digest("hex") } : { exists: false }
        if (actual.exists !== choice.observed!.exists || actual.sha256 !== choice.observed!.sha256) conflict("File changed since the client reviewed it")
      }
    }
    // Another client or cancellation may have won during filesystem reads.
    if (entry.record.status !== "pending") {
      if (entry.record.status !== "cancelled" && entry.reply === signature) return structuredClone(entry.record)
      conflict("Review changed while validating the reply")
    }
    entry.reply = signature
    entry.record.status = "decided"
    entry.record.decisions = decisions
    if (message) entry.record.message = message
    entry.resolve({ message, files: decisions.map(d => ({ ...d, path: current.files.find(f => f.fileID === d.fileID)!.filePath })) })
    return structuredClone(entry.record)
  }
  async finish(sessionID: string, callID: string, outcome: Record<string, unknown>) {
    for (const entry of this.entries.values()) {
      if (entry.record.sessionID !== sessionID || entry.record.callID !== callID || entry.record.status === "cancelled") continue
      entry.record.status = "settled"; entry.record.outcome = jsonValue(outcome); entry.detach()
      await this.emit("reviewSettled", structuredClone(entry.record))
    }
    // Native tool history remains the authoritative durable result.
    if (this.entries.size > 512) for (const [id, entry] of this.entries) {
      if (entry.record.status === "settled" || entry.record.status === "cancelled") this.entries.delete(id)
      if (this.entries.size <= 256) break
    }
  }
  fail(sessionID: string, callID: string) {
    for (const entry of this.entries.values()) if (entry.record.sessionID === sessionID && entry.record.callID === callID) this.cancel(entry.record.reviewID)
  }
  cancel(reviewID: string) {
    const entry = this.entries.get(reviewID)
    if (!entry || entry.record.status === "settled" || entry.record.status === "cancelled") return
    entry.record.status = "cancelled"; entry.detach()
    entry.reject(new Error("Review cancelled; no subsequent file writes are allowed"))
    void this.emit("reviewCancelled", structuredClone(entry.record)).catch(() => {})
  }
  dispose() { for (const id of this.entries.keys()) this.cancel(id) }
}

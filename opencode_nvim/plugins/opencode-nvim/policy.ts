import { randomUUID } from "node:crypto"
import type { PermissionEvaluation } from "@opencode/plugin/effect/permission"
import { protocolVersion, type Policy } from "./rpc"
import type { RuntimeContext } from "./tools/lib/definition"

type Gate = { record: Policy; evaluation?: PermissionEvaluation; asked: boolean; detach(): void;
  resolve(): void; reject(error: Error): void }
// 2.0.11 exposes evaluation/reply to plugins, but permission.create only over HTTP.
// The authenticated frontend creates the exact request below. Authorization comes
// from the native hook's final mutable evaluation or native asked/replied events,
// never from a client-supplied "allow" boolean. Explicit deny skips hooks entirely.
export class Policies {
  private gates = new Map<string, Gate>()
  constructor(private location: { directory: string }, private emit: (type: "policyRequested" | "policySettled", record: Policy) => Promise<void>) {}
  list(sessionID: string) { return [...this.gates.values()].filter(g => g.record.sessionID === sessionID && g.record.status === "pending").map(g => structuredClone(g.record)) }
  async wait(context: Pick<RuntimeContext, "signal" | "sessionID" | "messageID" | "id" | "agent">, action: string, resources: string[]) {
    context.signal.throwIfAborted()
    const gateID = randomUUID(), id = "per_" + randomUUID().replaceAll("-", "")
    const record: Policy = { protocolVersion, gateID, sessionID: context.sessionID, location: this.location, status: "pending",
      request: { id, action, resources: [...new Set(resources)].sort(), save: [...new Set(resources)].sort(), agent: context.agent,
        source: { type: "tool", messageID: context.messageID, id: context.id }, metadata: { gateID } } }
    let resolve!: () => void, reject!: (error: Error) => void
    const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no })
    void promise.catch(() => {})
    const cancel = () => this.settle(gate, "cancelled")
    const gate: Gate = { record, asked: false, resolve, reject, detach: () => context.signal.removeEventListener("abort", cancel) }
    this.gates.set(gateID, gate)
    context.signal.addEventListener("abort", cancel, { once: true })
    if (context.signal.aborted) cancel()
    if (record.status === "pending") await this.emit("policyRequested", structuredClone(record))
    await promise
    context.signal.throwIfAborted()
  }
  private matches(gate: Gate, value: { sessionID: string; action: string; resources: readonly string[]; source?: { messageID: string; id: string } }) {
    const request = gate.record.request
    return gate.record.sessionID === value.sessionID && request.action === value.action
      && request.source.messageID === value.source?.messageID && request.source.id === value.source?.id
      && JSON.stringify(request.resources) === JSON.stringify([...value.resources].sort())
  }
  evaluated(value: PermissionEvaluation) {
    const gate = this.gates.get(String(value.metadata?.gateID))
    if (gate?.record.status === "pending" && value.agent === gate.record.request.agent && this.matches(gate, value)) gate.evaluation = value
  }
  event(event: { type: string; data: any }) {
    if (event.type === "permission.asked") {
      const gate = this.gates.get(String(event.data.metadata?.gateID))
      if (gate && gate.record.request.id === event.data.id && this.matches(gate, event.data)) gate.asked = true
    } else if (event.type === "permission.replied") {
      for (const gate of this.gates.values()) if (gate.asked && gate.record.sessionID === event.data.sessionID && gate.record.request.id === event.data.requestID)
        this.settle(gate, event.data.reply === "reject" ? "denied" : "allowed")
    }
  }
  confirm(input: { sessionID: string; gateID: string; denied?: boolean }) {
    const gate = this.gates.get(input.gateID)
    if (!gate || gate.record.sessionID !== input.sessionID) throw new Error("Permission gate not found")
    if (gate.record.status === "pending") {
      if (input.denied || gate.evaluation?.effect === "deny") this.settle(gate, "denied")
      else if (!gate.asked && gate.evaluation?.effect === "allow") this.settle(gate, "allowed")
      else if (!gate.asked) throw new Error("Native permission evaluation has not authorized this tool call")
    }
    return structuredClone(gate.record)
  }
  private settle(gate: Gate, status: "allowed" | "denied" | "cancelled") {
    if (gate.record.status !== "pending") return
    gate.record.status = status; gate.detach()
    if (status === "allowed") gate.resolve()
    else gate.reject(new Error(status === "denied" ? "Native permission denied the tool operation" : "Tool permission cancelled"))
    void this.emit("policySettled", structuredClone(gate.record)).catch(() => {})
    if (this.gates.size > 512) for (const [id, old] of this.gates) {
      if (old.record.status !== "pending") this.gates.delete(id)
      if (this.gates.size <= 256) break
    }
  }
  dispose() { for (const gate of this.gates.values()) this.settle(gate, "cancelled") }
}

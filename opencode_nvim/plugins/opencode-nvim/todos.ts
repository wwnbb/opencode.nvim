import { createHash } from "node:crypto"
import { z } from "zod"

export const todo = z.object({ id: z.string().min(1), content: z.string().min(1),
  status: z.enum(["pending", "in_progress", "completed", "cancelled"]),
  priority: z.enum(["high", "medium", "low"]).optional() })
export const todoRecord = z.object({ protocolVersion: z.literal(1), revision: z.number().int().nonnegative(),
  sessionID: z.string(), location: z.object({ directory: z.string() }), todos: z.array(todo) })
export type TodoRecord = z.infer<typeof todoRecord>
export class TodoConflict extends Error {
  constructor(readonly current: TodoRecord) { super("Todo revision changed; read the current list before updating") }
}
export class Todos {
  private queues = new Map<string, Promise<void>>()
  constructor(private directory: string, private storage: { get(key: string): Promise<unknown>; set(key: string, value: TodoRecord): Promise<void> },
    private emit: (record: TodoRecord) => Promise<void>) {}
  private key(sessionID: string) {
    return "todo/v1/" + createHash("sha256").update(JSON.stringify([this.directory, sessionID])).digest("hex")
  }
  async get(sessionID: string): Promise<TodoRecord> {
    const stored = await this.storage.get(this.key(sessionID))
    if (stored === undefined) return { protocolVersion: 1, revision: 0, sessionID, location: { directory: this.directory }, todos: [] }
    const record = todoRecord.parse(stored)
    if (record.sessionID !== sessionID || record.location.directory !== this.directory) throw new Error("Todo scope mismatch")
    return record
  }
  async set(sessionID: string, values: z.infer<typeof todo>[], revision?: number, signal?: AbortSignal): Promise<TodoRecord> {
    const key = this.key(sessionID)
    const operation = (this.queues.get(key) ?? Promise.resolve()).then(async () => {
      signal?.throwIfAborted()
      const parsed = z.array(todo).parse(values)
      if (new Set(parsed.map(item => item.id)).size !== parsed.length) throw new Error("Todo IDs must be unique")
      const current = await this.get(sessionID)
      if (revision !== undefined && revision !== current.revision) throw new TodoConflict(current)
      const record: TodoRecord = { ...current, revision: current.revision + 1, todos: parsed }
      signal?.throwIfAborted()
      await this.storage.set(key, record)
      await this.emit(record)
      return record
    })
    const settled = operation.then(() => {}, () => {})
    this.queues.set(key, settled)
    try { return await operation } finally { if (this.queues.get(key) === settled) this.queues.delete(key) }
  }
}

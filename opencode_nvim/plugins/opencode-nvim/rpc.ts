import { z } from "zod"
import { Rpc } from "@opencode/plugin/effect"
import { todo, todoRecord } from "./todos"

export const protocolVersion = 1 as const
export const pluginVersion = "2.0.11-2"
export const location = z.object({ directory: z.string() }).passthrough()
export const observed = z.object({ exists: z.boolean(), sha256: z.string().optional() })
export const file = z.object({
  fileID: z.string(), filePath: z.string(), type: z.string(), before: z.string(), after: z.string(),
}).passthrough()
export const decision = z.object({
  fileID: z.string(), status: z.enum(["accepted", "rejected", "resolved"]),
  apply: z.enum(["client", "server"]).default("client"), observed: observed.optional(),
})
export const review = z.object({
  protocolVersion: z.literal(protocolVersion), reviewID: z.string(), revision: z.number().int(),
  status: z.enum(["pending", "decided", "settled", "cancelled"]), created: z.number(),
  sessionID: z.string(), messageID: z.string(), callID: z.string(), tool: z.string(), agent: z.string(),
  directory: z.string(), location, files: z.array(file), metadata: z.record(z.string(), z.unknown()),
  decisions: z.array(decision).optional(), outcome: z.record(z.string(), z.unknown()).optional(),
})
export type Review = z.infer<typeof review>
export type Decision = z.infer<typeof decision>
const identity = z.object({ sessionID: z.string(), reviewID: z.string() })
export const replyInput = identity.extend({ protocolVersion: z.literal(protocolVersion), revision: z.number().int(), decisions: z.array(decision) })
export const policy = z.object({
  protocolVersion: z.literal(protocolVersion), gateID: z.string(), sessionID: z.string(), location,
  status: z.enum(["pending", "allowed", "denied", "cancelled"]),
  request: z.object({ id: z.string(), action: z.string(), resources: z.array(z.string()), save: z.array(z.string()),
    agent: z.string(), source: z.object({ type: z.literal("tool"), messageID: z.string(), id: z.string() }),
    metadata: z.object({ gateID: z.string() }),
  }),
})
export type Policy = z.infer<typeof policy>
export const definition = Rpc.define({
  id: "opencode_nvim",
  methods: {
    todoGet: { input: z.object({ sessionID: z.string() }), output: todoRecord, errors: { unavailable: z.object({ message: z.string() }) } },
    todoSet: { input: z.object({ protocolVersion: z.literal(1), sessionID: z.string(), revision: z.number().int().nonnegative(), todos: z.array(todo) }), output: todoRecord,
      errors: { conflict: z.object({ current: todoRecord }), unavailable: z.object({ message: z.string() }) } },
    policyList: { input: z.object({ sessionID: z.string() }), output: z.array(policy) },
    policyConfirm: { input: z.object({ sessionID: z.string(), gateID: z.string(), denied: z.boolean().optional() }), output: policy,
      errors: { conflict: z.object({ message: z.string() }) } },
    capabilities: { input: z.object({}), output: z.object({ protocolVersion: z.literal(protocolVersion), pluginVersion: z.string(), tools: z.array(z.string()), review: z.literal(true), todo: z.literal(true) }) },
    reviewList: { input: z.object({ sessionID: z.string().optional() }), output: z.object({ protocolVersion: z.literal(protocolVersion), reviews: z.array(review) }) },
    reviewGet: { input: identity, output: review, errors: { not_found: z.object({ reviewID: z.string() }) } },
    reviewReply: { input: replyInput, output: review, errors: { conflict: z.object({ review: review.optional() }), not_found: z.object({ reviewID: z.string() }) } },
  },
  events: {
    todoUpdated: { schema: z.object({ todo: todoRecord }) },
    policyRequested: { schema: z.object({ policy }) },
    policySettled: { schema: z.object({ policy }) },
    reviewCreated: { schema: z.object({ review }) },
    reviewSettled: { schema: z.object({ review }) },
    reviewCancelled: { schema: z.object({ review }) },
  },
})

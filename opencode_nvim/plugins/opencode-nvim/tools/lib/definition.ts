import { z } from "zod"
import type { ReviewDecision, ReviewProposal } from "./context"

export interface RuntimeContext {
  directory: string
  worktree: string | undefined
  sessionID: string
  messageID: string
  agent: string
  id: string
  signal: AbortSignal
  authorize(action: string, resources: string[]): Promise<void>
  progress(metadata: Record<string, unknown>): Promise<void>
  review(proposal: ReviewProposal): Promise<ReviewDecision>
}
export function tool<T extends z.ZodRawShape>(definition: {
  description: string
  args: T
  execute(input: z.infer<z.ZodObject<T>>, context: RuntimeContext): Promise<any>
}) { return { ...definition, input: z.object(definition.args) } }
tool.schema = z

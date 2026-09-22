import type { RuntimeContext } from "./definition"

export interface ReviewFile {
  filePath: string
  type: string
  before: string
  after: string
  [key: string]: unknown
}
export interface ReviewProposal {
  tool: string
  metadata: Record<string, unknown> & { files: ReviewFile[] }
}
export interface ReviewDecision {
  files: Array<{ fileID: string; path: string; status: "accepted" | "rejected" | "resolved"; apply?: "client" | "server" }>
}
export async function publishProgress(context: RuntimeContext, proposal: { title: string; metadata: Record<string, unknown> }) {
  context.signal.throwIfAborted()
  await context.progress({ ...proposal.metadata, title: proposal.title })
}
export async function reviewDecision(context: RuntimeContext, proposal: ReviewProposal) {
  context.signal.throwIfAborted()
  const reply = await context.review(proposal)
  context.signal.throwIfAborted()
  return reply
}

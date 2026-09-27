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
  message?: string
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

// Both tools return review feedback in model-visible content and durable tool
// metadata, so reconnect/history rendering can recover the same user note.
export function reviewResult<T extends Record<string, unknown>>(
  decision: ReviewDecision,
  result: { title: string; content: string; metadata: T },
) {
  const message = decision.message?.trim()
  return {
    ...result,
    content: message ? `${result.content}\n\nUser feedback from review:\n${message}` : result.content,
    metadata: { ...result.metadata, ...(message ? { review_message: message } : {}) },
  }
}

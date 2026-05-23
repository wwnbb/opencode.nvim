import { tool } from "@opencode-ai/plugin"
import DESCRIPTION from "./permission_check.txt"

export default tool({
  description: DESCRIPTION,
  args: {},
  async execute(args, context) {
    const { agent, sessionID, messageID, directory, worktree, ask } = context
    await ask({
      permission: "permission_check",
      patterns: ["/Users/admin/.config/nvim/**/*.lua"],
      always: ["read"],
      metadata: {
        operation: "permission_check",
        agent,
        sessionID,
      },
    })
    // Continue after permission is granted
    return `Agent: ${agent}, Session: ${sessionID}, Message: ${messageID}, Directory: ${directory}, Worktree: ${worktree}`
  },
})

import { tool } from "./lib/definition"
import { readFileSync } from "node:fs"
const DESCRIPTION = readFileSync(new URL("./neovim_edit.txt", import.meta.url), "utf8")
import { reviewDecision, publishProgress, reviewResult } from "./lib/context"
import {
  displayPath,
  readState,
  resolveFilePath,
  sameState,
  splitBom,
  writeState,
} from "./lib/file_state"
import {
  assertNoAccidentalIndentRemoval,
  convertToLineEnding,
  detectLineEnding,
  makeDiff,
  normalizeLineEndings,
  sameContent,
  stats,
} from "./lib/text"

const schema = tool.schema

type Status = "applied" | "partial" | "rejected" | "failed"
type Divergence = "none" | "external" | "client_applied" | "client_resolved"

function replaceExact(
  content: string,
  oldString: string,
  newString: string,
  replaceAll = false,
  allowIndentChange = false,
  filePath = "file",
): string {
  if (oldString === newString) {
    throw new Error("No changes to apply: oldString and newString are identical.")
  }

  if (oldString === "") throw new Error("oldString must not be empty. Use neovim_patch to create a file.")

  let count = 0
  let index = content.indexOf(oldString)
  let first = index
  while (index !== -1) {
    count++
    index = content.indexOf(oldString, index + oldString.length)
  }

  if (count === 0) throw new Error("oldString not found in content")
  if (!replaceAll && count > 1) {
    throw new Error(
      "Found multiple matches for oldString. " +
        "Provide more surrounding lines in oldString to identify the correct match.",
    )
  }
  assertNoAccidentalIndentRemoval(
    filePath,
    oldString,
    newString,
    allowIndentChange,
    "Replacement",
    "Include the original indentation in newString, or set allowIndentChange=true if this dedent is intentional.",
  )
  if (replaceAll) return content.split(oldString).join(newString)

  return content.slice(0, first) + newString + content.slice(first + oldString.length)
}

function statusLabel(status: Status, divergence: Divergence = "none"): string {
  if (status === "applied") return "Edit applied successfully."
  if (status === "rejected") return "Edit rejected. No changes applied."
  if (status === "partial" && divergence === "client_resolved") {
    return "File was modified during review; the proposed edit was not applied. Re-read the file before retrying."
  }
  if (status === "partial" && divergence === "external") {
    return "File changed on disk while applying the edit; verify the result and re-read the file."
  }
  if (status === "partial") return "Edit partially applied by user review."
  return "Edit failed."
}

export default tool({
  description: DESCRIPTION,
  args: {
    path: schema.string().min(1).describe("The absolute or location-relative path to an existing file"),
    oldString: schema.string().min(1).describe("The non-empty exact text to replace"),
    newString: schema.string().describe("The replacement text"),
    replaceAll: schema.boolean().optional().describe("Replace all occurrences of oldString"),
    allowIndentChange: schema.boolean().optional().describe("Allow replacement lines to remove leading indentation"),
  },
  async execute(args, context) {
    if (!args.oldString) throw new Error("oldString must not be empty. Use neovim_patch to create a file.")
    if (args.oldString === args.newString) throw new Error("No changes to apply: oldString and newString are identical.")
    const filePath = resolveFilePath(context.directory, args.path)
    await context.authorize("neovim_edit", [filePath])
    const before = await readState(filePath)
    const nextInput = splitBom(args.newString)
    const desiredBom = before.bom || nextInput.bom

    if (!before.exists) {
      throw new Error(`File ${filePath} not found`)
    }

    const ending = detectLineEnding(before.content)
    const oldString = convertToLineEnding(normalizeLineEndings(args.oldString), ending)
    const newString = convertToLineEnding(normalizeLineEndings(nextInput.content), ending)
    const afterContent = replaceExact(
      before.content,
      oldString,
      newString,
      args.replaceAll,
      args.allowIndentChange,
      filePath,
    )
    const after = { exists: true, content: afterContent, bom: desiredBom }
    const proposedDiff = makeDiff(filePath, before.content, after.content)
    const proposedStats = stats(before.content, after.content)
    const relativePath = displayPath(context.worktree, filePath)

    const proposedFile = {
      filePath,
      relativePath,
      file: filePath,
      type: "update",
      before: before.content,
      after: after.content,
      diff: proposedDiff,
      patch: proposedDiff,
      additions: proposedStats.additions,
      deletions: proposedStats.deletions,
      status: "pending",
      bom: desiredBom,
      before_bom: before.bom,
      eol: ending,
    }

    await publishProgress(context, {
      title: relativePath,
      metadata: {
        opencode_native_diff: true,
        filepath: filePath,
        relativePath,
        diff: proposedDiff,
        proposed_diff: proposedDiff,
        filediff: proposedFile,
        files: [proposedFile],
        diagnostics: {},
      },
    })

    const decision = await reviewDecision(context, {
        tool: "neovim_edit",
        metadata: {
          opencode_native_diff: true,
          operation: "neovim_edit",
          agent: context.agent,
          sessionID: context.sessionID,
          messageID: context.messageID,
          filepath: filePath,
          relativePath,
          diff: proposedDiff,
          proposed_diff: proposedDiff,
          files: [proposedFile],
        },
      })
    context.signal.throwIfAborted()

    const approved = decision.files.some((file) => file.status !== "rejected")
    const serverApply = decision.files.some((file) => file.status === "accepted" && file.apply === "server")
    let current = await readState(filePath)
    let wrote = false
    let writeError: string | undefined
    if (serverApply && sameState(current, before)) {
      try {
        await writeState(filePath, after.content, after.bom, context.signal)
        wrote = true
        current = await readState(filePath)
      } catch (error) {
        writeError = String(error)
      }
    }

    let status: Status
    if (writeError) {
      status = "failed"
    } else if (approved && !wrote && sameState(current, before)) {
      status = "failed"
    } else if (current.exists && sameContent(current.content, after.content)) {
      status = "applied"
    } else if (sameState(current, before)) {
      status = "rejected"
    } else {
      status = "partial"
    }

    let divergence: Divergence = "none"
    if (approved) {
      if (wrote && status !== "applied") {
        divergence = "external"
      } else if (!wrote && sameContent(current.content, after.content)) {
        divergence = "client_applied"
      } else if (!wrote && !sameState(current, before)) {
        divergence = "client_resolved"
      }
    }

    let output: string
    if (writeError) {
      output = "Edit failed: " + writeError
    } else if (status === "failed") {
      output = "Edit failed: approved write was not applied."
    } else {
      output = statusLabel(status, divergence)
    }

    const finalContent = current.exists ? current.content : ""
    const finalDiff = makeDiff(filePath, before.content, finalContent)
    const finalStats = status === "rejected" ? { additions: 0, deletions: 0 } : stats(before.content, finalContent)
    const filediff = {
      ...proposedFile,
      after: finalContent,
      diff: finalDiff,
      patch: finalDiff,
      additions: finalStats.additions,
      deletions: finalStats.deletions,
      status,
    }

    return reviewResult(decision, {
      title: relativePath,
      content: output,
      metadata: {
        status,
        wrote,
        applied: status === "applied",
        divergence,
        filepath: filePath,
        relativePath,
        diff: finalDiff,
        proposed_diff: proposedDiff,
        filediff,
        diagnostics: {},
      },
    })
  },
})

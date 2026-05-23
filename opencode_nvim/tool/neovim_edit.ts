import { tool } from "@opencode-ai/plugin"
import * as fs from "fs/promises"
import * as path from "path"
import DESCRIPTION from "./neovim_edit.txt"
import { createTwoFilesPatch, diffLines } from "./diff"

const schema = tool.schema

type Status = "applied" | "partial" | "rejected" | "failed"

type FileState = {
  exists: boolean
  content: string
  bom: boolean
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function permissionErrorTag(error: unknown, seen = new Set<unknown>()): string | undefined {
  if (typeof error === "string") {
    if (error.includes("PermissionCorrectedError")) return "PermissionCorrectedError"
    if (error.includes("PermissionRejectedError")) return "PermissionRejectedError"
    if (error.includes("The user rejected permission to use this specific tool call with")) {
      return "PermissionCorrectedError"
    }
    if (error.includes("The user rejected permission to use this specific tool call.")) {
      return "PermissionRejectedError"
    }
    return undefined
  }

  if (!isRecord(error) || seen.has(error)) return undefined
  seen.add(error)

  const tag = error._tag ?? error.name
  if (tag === "PermissionRejectedError" || tag === "PermissionCorrectedError") return tag

  if (error instanceof Error) {
    const byText = permissionErrorTag(`${error.name}\n${error.message}\n${error.stack ?? ""}`, seen)
    if (byText) return byText
  }

  for (const key of ["cause", "error", "reason", "defect", "failure"]) {
    const found = permissionErrorTag(error[key], seen)
    if (found) return found
  }

  for (const key of ["errors", "failures", "defects"]) {
    const values = error[key]
    if (!Array.isArray(values)) continue
    for (const value of values) {
      const found = permissionErrorTag(value, seen)
      if (found) return found
    }
  }

  return undefined
}

function isPermissionRejected(error: unknown): boolean {
  return permissionErrorTag(error) === "PermissionRejectedError"
}

function splitBom(text: string): FileState {
  if (text.charCodeAt(0) === 0xfeff) {
    return { exists: true, content: text.slice(1), bom: true }
  }
  return { exists: true, content: text, bom: false }
}

function joinBom(content: string, bom: boolean): string {
  return bom ? "\ufeff" + content : content
}

async function readState(filePath: string): Promise<FileState> {
  try {
    const stat = await fs.stat(filePath)
    if (stat.isDirectory()) throw new Error(`Path is a directory, not a file: ${filePath}`)
    return splitBom(await fs.readFile(filePath, "utf8"))
  } catch (error) {
    if (typeof error === "object" && error && "code" in error && error.code === "ENOENT") {
      return { exists: false, content: "", bom: false }
    }
    throw error
  }
}

async function writeState(filePath: string, content: string, bom: boolean) {
  await fs.mkdir(path.dirname(filePath), { recursive: true })
  await fs.writeFile(filePath, joinBom(content, bom), "utf8")
}

async function removeEmptyCreatedFile(filePath: string, before: FileState, current: FileState) {
  if (before.exists || !current.exists || current.content !== "") return
  await fs.rm(filePath, { force: true })
}

function normalizeLineEndings(text: string): string {
  return text.replaceAll("\r\n", "\n").replaceAll("\r", "\n")
}

function detectLineEnding(text: string): "\n" | "\r\n" {
  return text.includes("\r\n") ? "\r\n" : "\n"
}

function convertToLineEnding(text: string, ending: "\n" | "\r\n"): string {
  if (ending === "\n") return text
  return text.replaceAll("\n", "\r\n")
}

function sameContent(left: string, right: string): boolean {
  return normalizeLineEndings(left) === normalizeLineEndings(right)
}

function sameState(current: FileState, expected: FileState): boolean {
  if (!current.exists || !expected.exists) return current.exists === expected.exists
  return sameContent(current.content, expected.content)
}

function replaceExact(content: string, oldString: string, newString: string, replaceAll = false): string {
  if (oldString === newString) {
    throw new Error("No changes to apply: oldString and newString are identical.")
  }

  if (oldString === "") return newString

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
  if (replaceAll) return content.split(oldString).join(newString)

  return content.slice(0, first) + newString + content.slice(first + oldString.length)
}

function trimDiff(diff: string): string {
  const lines = diff.split("\n")
  const contentLines = lines.filter(
    (line) =>
      (line.startsWith("+") || line.startsWith("-") || line.startsWith(" ")) &&
      !line.startsWith("---") &&
      !line.startsWith("+++"),
  )

  if (contentLines.length === 0) return diff

  let min = Infinity
  for (const line of contentLines) {
    const content = line.slice(1)
    if (content.trim().length === 0) continue
    const match = content.match(/^(\s*)/)
    if (match) min = Math.min(min, match[1].length)
  }
  if (min === Infinity || min === 0) return diff

  return lines
    .map((line) => {
      if (
        (line.startsWith("+") || line.startsWith("-") || line.startsWith(" ")) &&
        !line.startsWith("---") &&
        !line.startsWith("+++")
      ) {
        return line[0] + line.slice(1 + min)
      }
      return line
    })
    .join("\n")
}

function makeDiff(filePath: string, before: string, after: string): string {
  return trimDiff(
    createTwoFilesPatch(filePath, filePath, normalizeLineEndings(before), normalizeLineEndings(after)),
  )
}

function stats(before: string, after: string) {
  let additions = 0
  let deletions = 0
  const oldText = normalizeLineEndings(before).replace(/\n$/, "")
  const newText = normalizeLineEndings(after).replace(/\n$/, "")
  for (const change of diffLines(oldText, newText)) {
    if (change.added) additions += change.count || 0
    if (change.removed) deletions += change.count || 0
  }
  return { additions, deletions }
}

function resolveFilePath(directory: string, filePath: string): string {
  return path.isAbsolute(filePath) ? filePath : path.resolve(directory, filePath)
}

function displayPath(worktree: string, filePath: string): string {
  const relative = path.relative(worktree, filePath)
  if (relative && !relative.startsWith("..") && !path.isAbsolute(relative)) return relative.replaceAll("\\", "/")
  return filePath
}

function statusLabel(status: Status): string {
  if (status === "applied") return "Edit applied successfully."
  if (status === "rejected") return "Edit rejected. No changes applied."
  if (status === "partial") return "Edit partially applied by user review."
  return "Edit failed."
}

export default tool({
  description: DESCRIPTION,
  args: {
    filePath: schema.string().describe("The absolute or project-relative path to the file to modify"),
    oldString: schema.string().describe("The exact text to replace"),
    newString: schema.string().describe("The replacement text"),
    replaceAll: schema.boolean().optional().describe("Replace all occurrences of oldString"),
  },
  async execute(args, context) {
    const filePath = resolveFilePath(context.directory, args.filePath)
    const before = await readState(filePath)
    const nextInput = splitBom(args.newString)
    const desiredBom = before.bom || nextInput.bom

    if (!before.exists && args.oldString !== "") {
      throw new Error(`File ${filePath} not found`)
    }

    const ending = detectLineEnding(before.content)
    const oldString = convertToLineEnding(normalizeLineEndings(args.oldString), ending)
    const newString = convertToLineEnding(normalizeLineEndings(nextInput.content), ending)
    const afterContent = replaceExact(before.content, oldString, newString, args.replaceAll)
    const after = { exists: true, content: afterContent, bom: desiredBom }
    const proposedDiff = makeDiff(filePath, before.content, after.content)
    const proposedStats = stats(before.content, after.content)
    const relativePath = displayPath(context.worktree, filePath)

    const proposedFile = {
      filePath,
      relativePath,
      file: filePath,
      type: before.exists ? "update" : "add",
      before: before.content,
      after: after.content,
      diff: proposedDiff,
      patch: proposedDiff,
      additions: proposedStats.additions,
      deletions: proposedStats.deletions,
      status: "pending",
    }

    context.metadata({
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

    let approved = true
    try {
      await context.ask({
        permission: "neovim_edit",
        patterns: [relativePath],
        always: ["*"],
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
    } catch (error) {
      if (!isPermissionRejected(error)) throw error
      approved = false
    }

    let current = await readState(filePath)
    if (approved && sameState(current, before)) {
      await writeState(filePath, after.content, after.bom)
      current = await readState(filePath)
    } else if (!approved) {
      await removeEmptyCreatedFile(filePath, before, current)
      current = await readState(filePath)
    }

    let status: Status
    if (current.exists && sameContent(current.content, after.content)) {
      status = "applied"
    } else if (sameState(current, before)) {
      status = "rejected"
    } else {
      status = "partial"
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

    return {
      title: relativePath,
      output: statusLabel(status),
      metadata: {
        status,
        filepath: filePath,
        relativePath,
        diff: finalDiff,
        proposed_diff: proposedDiff,
        filediff,
        diagnostics: {},
      },
    }
  },
})

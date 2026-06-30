import { tool } from "@opencode-ai/plugin"
import DESCRIPTION from "./neovim_apply_patch.txt"
import { callAsk, callMetadata, isPermissionRejected } from "./lib/context"
import {
  type FileState,
  displayPath,
  readState,
  removePath,
  resolveFilePath,
  sameState,
  splitBom,
  writeState,
} from "./lib/file_state"
import { assertNoAccidentalIndentRemoval, makeDiff, sameContent, stats } from "./lib/text"

const schema = tool.schema

type Status = "applied" | "partial" | "rejected" | "failed"
type ChangeType = "add" | "update" | "delete" | "move"

type UpdateFileChunk = {
  old_lines: string[]
  new_lines: string[]
  change_context?: string
  start_line?: number
  is_end_of_file?: boolean
}

type Hunk =
  | { type: "add"; path: string; contents: string }
  | { type: "delete"; path: string }
  | { type: "update"; path: string; move_path?: string; chunks: UpdateFileChunk[] }

type FileChange = {
  filePath: string
  relativePath: string
  type: ChangeType
  before: FileState
  newContent: string
  bom: boolean
  proposedDiff: string
  additions: number
  deletions: number
  movePath?: string
  moveRelativePath?: string
  destinationBefore?: FileState
}

function stripHeredoc(input: string): string {
  const heredoc = input.match(/^(?:cat\s+)?<<['"]?(\w+)['"]?\s*\n([\s\S]*?)\n\1\s*$/)
  return heredoc ? heredoc[2] : input
}

function parsePatchHeader(lines: string[], start: number) {
  const line = lines[start]
  if (line.startsWith("*** Add File:")) {
    const filePath = line.slice("*** Add File:".length).trim()
    return filePath ? { kind: "add" as const, filePath, next: start + 1 } : undefined
  }
  if (line.startsWith("*** Delete File:")) {
    const filePath = line.slice("*** Delete File:".length).trim()
    return filePath ? { kind: "delete" as const, filePath, next: start + 1 } : undefined
  }
  if (line.startsWith("*** Update File:")) {
    const filePath = line.slice("*** Update File:".length).trim()
    let movePath: string | undefined
    let next = start + 1
    if (next < lines.length && lines[next].startsWith("*** Move to:")) {
      movePath = lines[next].slice("*** Move to:".length).trim()
      next++
    }
    return filePath ? { kind: "update" as const, filePath, movePath, next } : undefined
  }
  return undefined
}

function parseAddFileContent(lines: string[], start: number) {
  const content: string[] = []
  let index = start
  while (index < lines.length && !lines[index].startsWith("***")) {
    const line = lines[index]
    if (!line.startsWith("+")) {
      throw new Error(
        `Invalid Add File content at line ${index + 1}: every content line must start with '+', including blank lines (write '+' alone)`,
      )
    }
    content.push(line.slice(1))
    index++
  }
  return { content: content.join("\n"), next: index }
}

function parseHunkContext(raw: string): string {
  if (raw === "") return ""
  return raw.startsWith(" ") ? raw.slice(1) : raw
}

function parseUpdateFileChunks(lines: string[], start: number) {
  const chunks: UpdateFileChunk[] = []
  let index = start

  while (index < lines.length && !lines[index].startsWith("***")) {
    if (!lines[index].startsWith("@@")) {
      index++
      continue
    }

    let changeContext = parseHunkContext(lines[index].slice(2))
    let startLine: number | undefined
    const unified = changeContext.match(/^-(\d+)(?:,\d+)?\s+\+\d+(?:,\d+)?\s+@@(.*)$/)
    if (unified) {
      startLine = Number.parseInt(unified[1], 10) - 1
      changeContext = parseHunkContext(unified[2])
    }
    index++
    const oldLines: string[] = []
    const newLines: string[] = []
    let isEndOfFile = false

    while (
      index < lines.length &&
      !lines[index].startsWith("@@") &&
      (!lines[index].startsWith("***") || lines[index] === "*** End of File")
    ) {
      const line = lines[index]
      if (line === "*** End of File") {
        isEndOfFile = true
        index++
        break
      }
      if (line.startsWith(" ")) {
        oldLines.push(line.slice(1))
        newLines.push(line.slice(1))
      } else if (line.startsWith("-")) {
        oldLines.push(line.slice(1))
      } else if (line.startsWith("+")) {
        newLines.push(line.slice(1))
      }
      index++
    }

    chunks.push({
      old_lines: oldLines,
      new_lines: newLines,
      change_context: changeContext || undefined,
      start_line: startLine,
      is_end_of_file: isEndOfFile || undefined,
    })
  }

  return { chunks, next: index }
}

function parsePatch(patchText: string): Hunk[] {
  const cleaned = stripHeredoc(patchText.trim())
  const lines = cleaned.split("\n")
  const begin = lines.findIndex((line) => line.trim() === "*** Begin Patch")
  const end = lines.findIndex((line) => line.trim() === "*** End Patch")
  if (begin === -1) {
    throw new Error("Invalid patch format: missing *** Begin Patch marker")
  }
  if (end === -1) {
    throw new Error("Invalid patch format: missing *** End Patch marker")
  }
  if (begin >= end) {
    throw new Error("Invalid patch format: *** End Patch appears before *** Begin Patch")
  }

  const hunks: Hunk[] = []
  let index = begin + 1
  while (index < end) {
    const header = parsePatchHeader(lines, index)
    if (!header) {
      index++
      continue
    }

    if (header.kind === "add") {
      const parsed = parseAddFileContent(lines, header.next)
      hunks.push({ type: "add", path: header.filePath, contents: parsed.content })
      index = parsed.next
      continue
    }
    if (header.kind === "delete") {
      hunks.push({ type: "delete", path: header.filePath })
      index = header.next
      continue
    }

    const parsed = parseUpdateFileChunks(lines, header.next)
    hunks.push({
      type: "update",
      path: header.filePath,
      move_path: header.movePath,
      chunks: parsed.chunks,
    })
    index = parsed.next
  }

  return hunks
}

type Comparator = (left: string, right: string) => boolean

function tryMatch(lines: string[], pattern: string[], start: number, compare: Comparator, eof: boolean): number {
  if (eof) {
    const fromEnd = lines.length - pattern.length
    if (fromEnd >= start && pattern.every((line, index) => compare(lines[fromEnd + index], line))) return fromEnd
  }

  for (let index = start; index <= lines.length - pattern.length; index++) {
    if (pattern.every((line, offset) => compare(lines[index + offset], line))) return index
  }
  return -1
}

function seekSequence(lines: string[], pattern: string[], start: number, eof = false): number {
  if (pattern.length === 0) return -1

  const exact = tryMatch(lines, pattern, start, (left, right) => left === right, eof)
  if (exact !== -1) return exact

  const rstrip = tryMatch(lines, pattern, start, (left, right) => left.trimEnd() === right.trimEnd(), eof)
  if (rstrip !== -1) return rstrip
  return -1
}

function computeReplacements(
  lines: string[],
  filePath: string,
  chunks: UpdateFileChunk[],
  allowIndentChange = false,
) {
  const replacements: Array<[number, number, string[]]> = []
  let lineIndex = 0

  for (const chunk of chunks) {
    if (chunk.start_line !== undefined && chunk.start_line >= lineIndex) {
      lineIndex = chunk.start_line
    }

    if (chunk.change_context) {
      const contextIndex = seekSequence(lines, [chunk.change_context], lineIndex)
      if (contextIndex === -1) throw new Error(`Failed to find context '${chunk.change_context}' in ${filePath}`)
      lineIndex = chunk.old_lines[0] === chunk.change_context ? contextIndex : contextIndex + 1
    }

    if (chunk.old_lines.length === 0) {
      const insertion = lines.length > 0 && lines[lines.length - 1] === "" ? lines.length - 1 : lines.length
      replacements.push([insertion, 0, chunk.new_lines])
      continue
    }

    let oldLines = chunk.old_lines
    let newLines = chunk.new_lines
    let found = seekSequence(lines, oldLines, lineIndex, chunk.is_end_of_file)
    if (found === -1 && oldLines[oldLines.length - 1] === "") {
      oldLines = oldLines.slice(0, -1)
      if (newLines[newLines.length - 1] === "") newLines = newLines.slice(0, -1)
      found = seekSequence(lines, oldLines, lineIndex, chunk.is_end_of_file)
    }
    if (found === -1) throw new Error(`Failed to find expected lines in ${filePath}:\n${chunk.old_lines.join("\n")}`)

    assertNoAccidentalIndentRemoval(
      filePath,
      oldLines,
      newLines,
      allowIndentChange,
      "Patch",
      "Include the original indentation after '+', or set allowIndentChange=true if this dedent is intentional.",
    )
    replacements.push([found, oldLines.length, newLines])
    lineIndex = found + oldLines.length
  }

  return replacements.sort((left, right) => left[0] - right[0])
}

function deriveNewContent(
  filePath: string,
  chunks: UpdateFileChunk[],
  original: string,
  allowIndentChange = false,
): string {
  let lines = original.split("\n")
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()

  const replacements = computeReplacements(lines, filePath, chunks, allowIndentChange)
  const next = [...lines]
  for (let index = replacements.length - 1; index >= 0; index--) {
    const [start, oldLength, replacement] = replacements[index]
    next.splice(start, oldLength, ...replacement)
  }
  if (next.length === 0 || next[next.length - 1] !== "") next.push("")
  return next.join("\n")
}

async function buildChanges(
  hunks: Hunk[],
  directory: string,
  worktree: string,
  allowIndentChange = false,
): Promise<FileChange[]> {
  const changes: FileChange[] = []

  for (const hunk of hunks) {
    const filePath = resolveFilePath(directory, hunk.path)
    const relativePath = displayPath(worktree, filePath)

    if (hunk.type === "add") {
      const before = await readState(filePath)
      const rawContent = hunk.contents.endsWith("\n") ? hunk.contents : `${hunk.contents}\n`
      const next = splitBom(rawContent)
      const proposedDiff = makeDiff(filePath, before.content, next.content)
      const count = stats(before.content, next.content)
      changes.push({
        filePath,
        relativePath,
        type: "add",
        before,
        newContent: next.content,
        bom: before.bom || next.bom,
        proposedDiff,
        additions: count.additions,
        deletions: count.deletions,
      })
      continue
    }

    if (hunk.type === "delete") {
      const before = await readState(filePath)
      if (!before.exists) throw new Error(`apply_patch verification failed: Failed to read file to delete: ${filePath}`)
      const proposedDiff = makeDiff(filePath, before.content, "")
      const count = stats(before.content, "")
      changes.push({
        filePath,
        relativePath,
        type: "delete",
        before,
        newContent: "",
        bom: before.bom,
        proposedDiff,
        additions: count.additions,
        deletions: count.deletions,
      })
      continue
    }

    const before = await readState(filePath)
    if (!before.exists) throw new Error(`apply_patch verification failed: Failed to read file to update: ${filePath}`)
    const newContent = deriveNewContent(filePath, hunk.chunks, before.content, allowIndentChange)
    const proposedDiff = makeDiff(filePath, before.content, newContent)
    const count = stats(before.content, newContent)
    const movePath = hunk.move_path ? resolveFilePath(directory, hunk.move_path) : undefined
    const destinationBefore = movePath ? await readState(movePath) : undefined

    changes.push({
      filePath,
      relativePath,
      type: movePath ? "move" : "update",
      before,
      newContent,
      bom: before.bom,
      proposedDiff,
      additions: count.additions,
      deletions: count.deletions,
      movePath,
      moveRelativePath: movePath ? displayPath(worktree, movePath) : undefined,
      destinationBefore,
    })
  }

  return changes
}

function reviewFilesForChange(change: FileChange) {
  if (change.type !== "move" || !change.movePath) {
    return [
      {
        filePath: change.filePath,
        relativePath: change.relativePath,
        type: change.type,
        before: change.before.content,
        after: change.newContent,
        diff: change.proposedDiff,
        patch: change.proposedDiff,
        additions: change.additions,
        deletions: change.deletions,
        status: "pending",
      },
    ]
  }

  const destinationBefore = change.destinationBefore ?? { exists: false, content: "", bom: false }
  const deleteDiff = makeDiff(change.filePath, change.before.content, "")
  const addDiff = makeDiff(change.movePath, destinationBefore.content, change.newContent)
  return [
    {
      filePath: change.filePath,
      relativePath: change.relativePath,
      type: "delete",
      before: change.before.content,
      after: "",
      diff: deleteDiff,
      patch: deleteDiff,
      additions: stats(change.before.content, "").additions,
      deletions: stats(change.before.content, "").deletions,
      status: "pending",
    },
    {
      filePath: change.movePath,
      relativePath: change.moveRelativePath,
      type: "add",
      before: destinationBefore.content,
      after: change.newContent,
      diff: addDiff,
      patch: addDiff,
      additions: stats(destinationBefore.content, change.newContent).additions,
      deletions: stats(destinationBefore.content, change.newContent).deletions,
      status: "pending",
    },
  ]
}

async function currentMatchesBefore(change: FileChange): Promise<boolean> {
  const source = await readState(change.filePath)
  if (change.type !== "move" || !change.movePath) return sameState(source, change.before)

  const destination = await readState(change.movePath)
  const destinationBefore = change.destinationBefore ?? { exists: false, content: "", bom: false }
  return sameState(source, change.before) && sameState(destination, destinationBefore)
}

async function applyChange(change: FileChange) {
  if (change.type === "delete") {
    await removePath(change.filePath)
    return
  }
  if (change.type === "move" && change.movePath) {
    await writeState(change.movePath, change.newContent, change.bom)
    if (change.filePath !== change.movePath) await removePath(change.filePath)
    return
  }
  await writeState(change.filePath, change.newContent, change.bom)
}

async function classifyChange(change: FileChange): Promise<Status> {
  const source = await readState(change.filePath)

  if (change.type === "delete") {
    if (!source.exists) return "applied"
    if (source.exists && source.content === "") {
      await removePath(change.filePath)
      return "applied"
    }
    if (sameState(source, change.before)) return "rejected"
    return "partial"
  }

  if (change.type === "move" && change.movePath) {
    const destination = await readState(change.movePath)
    const destinationBefore = change.destinationBefore ?? { exists: false, content: "", bom: false }
    if (!source.exists && destination.exists && sameContent(destination.content, change.newContent)) return "applied"
    if (
      source.exists &&
      source.content === "" &&
      destination.exists &&
      sameContent(destination.content, change.newContent)
    ) {
      await removePath(change.filePath)
      return "applied"
    }
    if (sameState(source, change.before) && sameState(destination, destinationBefore)) return "rejected"
    if (source.exists && source.content === "" && change.before.content !== "") {
      await removePath(change.filePath)
    }
    if (!destinationBefore.exists && destination.exists && destination.content === "") {
      await removePath(change.movePath)
    }
    return "partial"
  }

  if (source.exists && sameContent(source.content, change.newContent)) return "applied"
  if (sameState(source, change.before)) return "rejected"
  if (!change.before.exists && source.exists && source.content === "") {
    await removePath(change.filePath)
    return "rejected"
  }
  return "partial"
}

async function finalContentFor(change: FileChange): Promise<string> {
  if (change.type === "move" && change.movePath) {
    const destination = await readState(change.movePath)
    return destination.exists ? destination.content : ""
  }
  const current = await readState(change.filePath)
  return current.exists ? current.content : ""
}

function finalFile(change: FileChange, status: Status, finalContent: string) {
  const finalDiff = makeDiff(change.movePath ?? change.filePath, change.before.content, finalContent)
  const finalStats = status === "rejected" ? { additions: 0, deletions: 0 } : stats(change.before.content, finalContent)
  return {
    filePath: change.filePath,
    relativePath: change.relativePath,
    type: change.type,
    status,
    before: change.before.content,
    after: finalContent,
    diff: finalDiff,
    patch: finalDiff,
    proposedDiff: change.proposedDiff,
    proposed_diff: change.proposedDiff,
    additions: finalStats.additions,
    deletions: finalStats.deletions,
    movePath: change.moveRelativePath,
  }
}

function overallStatus(statuses: Status[]): Status {
  if (statuses.length === 0) return "failed"
  if (statuses.every((status) => status === "applied")) return "applied"
  if (statuses.every((status) => status === "rejected")) return "rejected"
  if (statuses.some((status) => status === "failed")) return "failed"
  return "partial"
}

function outputFor(status: Status, files: ReturnType<typeof finalFile>[]) {
  if (status === "rejected") return "Patch rejected. No changes applied."

  const lines = files.map((file) => {
    const marker = file.type === "add" ? "A" : file.type === "delete" ? "D" : file.type === "move" ? "R" : "M"
    const suffix = file.status === "partial" ? " (partial)" : file.status === "rejected" ? " (rejected)" : ""
    const target =
      file.type === "move" && file.movePath ? `${file.relativePath} -> ${file.movePath}` : file.relativePath
    return `${marker} ${target}${suffix}`
  })

  if (status === "applied") return `Success. Updated the following files:\n${lines.join("\n")}`
  return `Patch review completed with partial changes:\n${lines.join("\n")}`
}

export default tool({
  description: DESCRIPTION,
  args: {
    patchText: schema.string().describe("The full patch text that describes all changes to be made"),
    allowIndentChange: schema.boolean().optional().describe("Allow replacement lines to remove leading indentation"),
  },
  async execute(args, context) {
    if (!args.patchText) throw new Error("patchText is required")

    let hunks: Hunk[]
    try {
      hunks = parsePatch(args.patchText)
    } catch (error) {
      throw new Error(`apply_patch verification failed: ${error instanceof Error ? error.message : String(error)}`)
    }

    if (hunks.length === 0) {
      const normalized = args.patchText.replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim()
      if (normalized === "*** Begin Patch\n*** End Patch") throw new Error("patch rejected: empty patch")
      throw new Error("apply_patch verification failed: no hunks found")
    }

    const changes = await buildChanges(hunks, context.directory, context.worktree, args.allowIndentChange)
    if (changes.length === 0) throw new Error("apply_patch verification failed: no hunks found")

    const reviewFiles = changes.flatMap(reviewFilesForChange)
    const proposedFiles = changes.map((change) => ({
      filePath: change.filePath,
      relativePath: change.relativePath,
      type: change.type,
      before: change.before.content,
      after: change.newContent,
      diff: change.proposedDiff,
      patch: change.proposedDiff,
      proposedDiff: change.proposedDiff,
      additions: change.additions,
      deletions: change.deletions,
      movePath: change.moveRelativePath,
      status: "pending",
    }))
    const proposedDiff = changes.map((change) => change.proposedDiff).join("\n")
    const patterns = Array.from(
      new Set(changes.flatMap((change) => [change.relativePath, change.moveRelativePath].filter(Boolean) as string[])),
    )

    callMetadata(context, {
      title: `${changes.length} file${changes.length === 1 ? "" : "s"}`,
      metadata: {
        opencode_native_diff: true,
        diff: proposedDiff,
        proposed_diff: proposedDiff,
        files: reviewFiles,
        proposed_files: proposedFiles,
        diagnostics: {},
      },
    })

    let approved = true
    try {
      await callAsk(context, {
        permission: "neovim_apply_patch",
        patterns,
        always: ["*"],
        metadata: {
          opencode_native_diff: true,
          operation: "neovim_apply_patch",
          agent: context.agent,
          sessionID: context.sessionID,
          messageID: context.messageID,
          filepath: patterns.join(", "),
          diff: proposedDiff,
          proposed_diff: proposedDiff,
          files: reviewFiles,
          proposed_files: proposedFiles,
        },
      })
    } catch (error) {
      if (!isPermissionRejected(error)) throw error
      approved = false
    }

    if (approved) {
      const unchanged = await Promise.all(changes.map(currentMatchesBefore))
      if (unchanged.every(Boolean)) {
        for (const change of changes) await applyChange(change)
      }
    } else {
      for (const change of changes) {
        if (!change.before.exists) {
          const current = await readState(change.filePath)
          if (current.exists && current.content === "") await removePath(change.filePath)
        }
      }
    }

    const statuses: Status[] = []
    const files = []
    for (const change of changes) {
      const status = await classifyChange(change)
      statuses.push(status)
      files.push(finalFile(change, status, await finalContentFor(change)))
    }

    const status = overallStatus(statuses)
    const finalDiff = files.map((file) => file.diff).join("\n")

    return {
      title: status === "applied" ? "Patch applied" : "Patch review completed",
      output: outputFor(status, files),
      metadata: {
        status,
        diff: finalDiff,
        proposed_diff: proposedDiff,
        files,
        proposed_files: proposedFiles,
        diagnostics: {},
      },
    }
  },
})

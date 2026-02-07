import { tool } from "@opencode-ai/plugin"
import * as fs from "fs/promises"
import { readFileSync } from "fs"
import * as path from "path"
import DESCRIPTION from "./opencode_apply_patch.txt"

// =============================================================================
// Inline diff utilities (replacing "diff" npm package)
// =============================================================================

interface DiffChange {
  value: string
  added?: boolean
  removed?: boolean
  count?: number
}

function diffLines(oldStr: string, newStr: string): DiffChange[] {
  const oldLines = oldStr === "" ? [] : oldStr.split("\n")
  const newLines = newStr === "" ? [] : newStr.split("\n")
  const N = oldLines.length
  const M = newLines.length
  const max = N + M
  if (max === 0) return [{ value: "", count: 0 }]

  const v = new Int32Array(2 * max + 1)
  v.fill(-1)
  const trace: Int32Array[] = []
  v[max + 1] = 0

  outer: for (let d = 0; d <= max; d++) {
    trace.push(v.slice())
    for (let k = -d; k <= d; k += 2) {
      let x: number
      if (k === -d || (k !== d && v[max + k - 1] < v[max + k + 1])) {
        x = v[max + k + 1]
      } else {
        x = v[max + k - 1] + 1
      }
      let y = x - k
      while (x < N && y < M && oldLines[x] === newLines[y]) {
        x++
        y++
      }
      v[max + k] = x
      if (x >= N && y >= M) break outer
    }
  }

  let x = N
  let y = M
  const edits: Array<{ type: "equal" | "insert" | "delete"; line: string }> = []

  for (let d = trace.length - 1; d >= 0; d--) {
    const v = trace[d]
    const k = x - y
    let prevK: number
    if (k === -d || (k !== d && v[max + k - 1] < v[max + k + 1])) {
      prevK = k + 1
    } else {
      prevK = k - 1
    }
    const prevX = v[max + prevK]
    const prevY = prevX - prevK

    while (x > prevX && y > prevY) {
      x--
      y--
      edits.unshift({ type: "equal", line: oldLines[x] })
    }
    if (d > 0) {
      if (x === prevX) {
        y--
        edits.unshift({ type: "insert", line: newLines[y] })
      } else {
        x--
        edits.unshift({ type: "delete", line: oldLines[x] })
      }
    }
  }

  const changes: DiffChange[] = []
  for (const edit of edits) {
    const last = changes[changes.length - 1]
    if (edit.type === "equal") {
      if (last && !last.added && !last.removed) {
        last.value += "\n" + edit.line
        last.count = (last.count || 0) + 1
      } else {
        changes.push({ value: edit.line, count: 1 })
      }
    } else if (edit.type === "insert") {
      if (last && last.added) {
        last.value += "\n" + edit.line
        last.count = (last.count || 0) + 1
      } else {
        changes.push({ value: edit.line, added: true, count: 1 })
      }
    } else {
      if (last && last.removed) {
        last.value += "\n" + edit.line
        last.count = (last.count || 0) + 1
      } else {
        changes.push({ value: edit.line, removed: true, count: 1 })
      }
    }
  }

  return changes
}

function createTwoFilesPatch(
  oldFileName: string,
  newFileName: string,
  oldStr: string,
  newStr: string,
  oldHeader?: string,
  newHeader?: string,
): string {
  const changes = diffLines(oldStr, newStr)

  const annotated: Array<{ prefix: string; line: string }> = []
  for (const change of changes) {
    const lines = change.value.split("\n")
    if (change.added) {
      for (const l of lines) annotated.push({ prefix: "+", line: l })
    } else if (change.removed) {
      for (const l of lines) annotated.push({ prefix: "-", line: l })
    } else {
      for (const l of lines) annotated.push({ prefix: " ", line: l })
    }
  }

  if (annotated.length === 0) {
    return (
      `--- ${oldFileName}${oldHeader ? "\t" + oldHeader : ""}\n` +
      `+++ ${newFileName}${newHeader ? "\t" + newHeader : ""}\n`
    )
  }

  const contextSize = 3
  const hunks: string[] = []
  let i = 0

  while (i < annotated.length) {
    while (i < annotated.length && annotated[i].prefix === " ") i++
    if (i >= annotated.length) break

    const hunkStart = Math.max(0, i - contextSize)
    let hunkEnd = i

    while (hunkEnd < annotated.length) {
      while (hunkEnd < annotated.length && annotated[hunkEnd].prefix !== " ") hunkEnd++
      let contextCount = 0
      const contextStart = hunkEnd
      while (hunkEnd < annotated.length && annotated[hunkEnd].prefix === " ") {
        hunkEnd++
        contextCount++
      }
      if (hunkEnd < annotated.length && contextCount <= 2 * contextSize) continue
      hunkEnd = Math.min(contextStart + contextSize, annotated.length)
      break
    }

    let oldStart = 1
    let oldCount = 0
    let newStart = 1
    let newCount = 0

    let oLine = 0
    let nLine = 0
    for (let j = 0; j < hunkStart; j++) {
      if (annotated[j].prefix !== "+") oLine++
      if (annotated[j].prefix !== "-") nLine++
    }
    oldStart = oLine + 1
    newStart = nLine + 1

    const hunkLines: string[] = []
    for (let j = hunkStart; j < hunkEnd; j++) {
      hunkLines.push(annotated[j].prefix + annotated[j].line)
      if (annotated[j].prefix !== "+") oldCount++
      if (annotated[j].prefix !== "-") newCount++
    }

    hunks.push(
      `@@ -${oldStart},${oldCount} +${newStart},${newCount} @@\n` + hunkLines.join("\n"),
    )

    i = hunkEnd
  }

  if (hunks.length === 0) {
    return (
      `--- ${oldFileName}${oldHeader ? "\t" + oldHeader : ""}\n` +
      `+++ ${newFileName}${newHeader ? "\t" + newHeader : ""}\n`
    )
  }

  return (
    `--- ${oldFileName}${oldHeader ? "\t" + oldHeader : ""}\n` +
    `+++ ${newFileName}${newHeader ? "\t" + newHeader : ""}\n` +
    hunks.join("\n")
  )
}

// =============================================================================
// Inline trimDiff (from opencode/tool/edit.ts)
// =============================================================================

function normalizeLineEndings(text: string): string {
  return text.replaceAll("\r\n", "\n")
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
    if (content.trim().length > 0) {
      const match = content.match(/^(\s*)/)
      if (match) min = Math.min(min, match[1].length)
    }
  }
  if (min === Infinity || min === 0) return diff
  const trimmedLines = lines.map((line) => {
    if (
      (line.startsWith("+") || line.startsWith("-") || line.startsWith(" ")) &&
      !line.startsWith("---") &&
      !line.startsWith("+++")
    ) {
      const prefix = line[0]
      const content = line.slice(1)
      return prefix + content.slice(min)
    }
    return line
  })
  return trimmedLines.join("\n")
}

// =============================================================================
// Inline Patch module (from opencode/patch/index.ts)
// =============================================================================

interface UpdateFileChunk {
  old_lines: string[]
  new_lines: string[]
  change_context?: string
  is_end_of_file?: boolean
}

type Hunk =
  | { type: "add"; path: string; contents: string }
  | { type: "delete"; path: string }
  | { type: "update"; path: string; move_path?: string; chunks: UpdateFileChunk[] }

function parsePatchHeader(
  lines: string[],
  startIdx: number,
): { filePath: string; movePath?: string; nextIdx: number } | null {
  const line = lines[startIdx]

  if (line.startsWith("*** Add File:")) {
    const filePath = line.split(":", 2)[1]?.trim()
    return filePath ? { filePath, nextIdx: startIdx + 1 } : null
  }

  if (line.startsWith("*** Delete File:")) {
    const filePath = line.split(":", 2)[1]?.trim()
    return filePath ? { filePath, nextIdx: startIdx + 1 } : null
  }

  if (line.startsWith("*** Update File:")) {
    const filePath = line.split(":", 2)[1]?.trim()
    let movePath: string | undefined
    let nextIdx = startIdx + 1

    if (nextIdx < lines.length && lines[nextIdx].startsWith("*** Move to:")) {
      movePath = lines[nextIdx].split(":", 2)[1]?.trim()
      nextIdx++
    }

    return filePath ? { filePath, movePath, nextIdx } : null
  }

  return null
}

function parseUpdateFileChunks(lines: string[], startIdx: number): { chunks: UpdateFileChunk[]; nextIdx: number } {
  const chunks: UpdateFileChunk[] = []
  let i = startIdx

  while (i < lines.length && !lines[i].startsWith("***")) {
    if (lines[i].startsWith("@@")) {
      const contextLine = lines[i].substring(2).trim()
      i++

      const oldLines: string[] = []
      const newLines: string[] = []
      let isEndOfFile = false

      while (i < lines.length && !lines[i].startsWith("@@") && !lines[i].startsWith("***")) {
        const changeLine = lines[i]

        if (changeLine === "*** End of File") {
          isEndOfFile = true
          i++
          break
        }

        if (changeLine.startsWith(" ")) {
          const content = changeLine.substring(1)
          oldLines.push(content)
          newLines.push(content)
        } else if (changeLine.startsWith("-")) {
          oldLines.push(changeLine.substring(1))
        } else if (changeLine.startsWith("+")) {
          newLines.push(changeLine.substring(1))
        }

        i++
      }

      chunks.push({
        old_lines: oldLines,
        new_lines: newLines,
        change_context: contextLine || undefined,
        is_end_of_file: isEndOfFile || undefined,
      })
    } else {
      i++
    }
  }

  return { chunks, nextIdx: i }
}

function parseAddFileContent(lines: string[], startIdx: number): { content: string; nextIdx: number } {
  let content = ""
  let i = startIdx

  while (i < lines.length && !lines[i].startsWith("***")) {
    if (lines[i].startsWith("+")) {
      content += lines[i].substring(1) + "\n"
    }
    i++
  }

  if (content.endsWith("\n")) {
    content = content.slice(0, -1)
  }

  return { content, nextIdx: i }
}

function stripHeredoc(input: string): string {
  const heredocMatch = input.match(/^(?:cat\s+)?<<['"]?(\w+)['"]?\s*\n([\s\S]*?)\n\1\s*$/)
  if (heredocMatch) {
    return heredocMatch[2]
  }
  return input
}

function parsePatch(patchText: string): { hunks: Hunk[] } {
  const cleaned = stripHeredoc(patchText.trim())
  const lines = cleaned.split("\n")
  const hunks: Hunk[] = []
  let i = 0

  const beginMarker = "*** Begin Patch"
  const endMarker = "*** End Patch"

  const beginIdx = lines.findIndex((line) => line.trim() === beginMarker)
  const endIdx = lines.findIndex((line) => line.trim() === endMarker)

  if (beginIdx === -1 || endIdx === -1 || beginIdx >= endIdx) {
    throw new Error("Invalid patch format: missing Begin/End markers")
  }

  i = beginIdx + 1

  while (i < endIdx) {
    const header = parsePatchHeader(lines, i)
    if (!header) {
      i++
      continue
    }

    if (lines[i].startsWith("*** Add File:")) {
      const { content, nextIdx } = parseAddFileContent(lines, header.nextIdx)
      hunks.push({
        type: "add",
        path: header.filePath,
        contents: content,
      })
      i = nextIdx
    } else if (lines[i].startsWith("*** Delete File:")) {
      hunks.push({
        type: "delete",
        path: header.filePath,
      })
      i = header.nextIdx
    } else if (lines[i].startsWith("*** Update File:")) {
      const { chunks, nextIdx } = parseUpdateFileChunks(lines, header.nextIdx)
      hunks.push({
        type: "update",
        path: header.filePath,
        move_path: header.movePath,
        chunks,
      })
      i = nextIdx
    } else {
      i++
    }
  }

  return { hunks }
}

// Normalize Unicode punctuation to ASCII equivalents
function normalizeUnicode(str: string): string {
  return str
    .replace(/[\u2018\u2019\u201A\u201B]/g, "'")
    .replace(/[\u201C\u201D\u201E\u201F]/g, '"')
    .replace(/[\u2010\u2011\u2012\u2013\u2014\u2015]/g, "-")
    .replace(/\u2026/g, "...")
    .replace(/\u00A0/g, " ")
}

type Comparator = (a: string, b: string) => boolean

function tryMatch(lines: string[], pattern: string[], startIndex: number, compare: Comparator, eof: boolean): number {
  if (eof) {
    const fromEnd = lines.length - pattern.length
    if (fromEnd >= startIndex) {
      let matches = true
      for (let j = 0; j < pattern.length; j++) {
        if (!compare(lines[fromEnd + j], pattern[j])) {
          matches = false
          break
        }
      }
      if (matches) return fromEnd
    }
  }
  for (let i = startIndex; i <= lines.length - pattern.length; i++) {
    let matches = true
    for (let j = 0; j < pattern.length; j++) {
      if (!compare(lines[i + j], pattern[j])) {
        matches = false
        break
      }
    }
    if (matches) return i
  }
  return -1
}

function seekSequence(lines: string[], pattern: string[], startIndex: number, eof = false): number {
  if (pattern.length === 0) return -1
  const exact = tryMatch(lines, pattern, startIndex, (a, b) => a === b, eof)
  if (exact !== -1) return exact
  const rstrip = tryMatch(lines, pattern, startIndex, (a, b) => a.trimEnd() === b.trimEnd(), eof)
  if (rstrip !== -1) return rstrip
  const trim = tryMatch(lines, pattern, startIndex, (a, b) => a.trim() === b.trim(), eof)
  if (trim !== -1) return trim
  const normalized = tryMatch(
    lines,
    pattern,
    startIndex,
    (a, b) => normalizeUnicode(a.trim()) === normalizeUnicode(b.trim()),
    eof,
  )
  return normalized
}

function computeReplacements(
  originalLines: string[],
  filePath: string,
  chunks: UpdateFileChunk[],
): Array<[number, number, string[]]> {
  const replacements: Array<[number, number, string[]]> = []
  let lineIndex = 0

  for (const chunk of chunks) {
    if (chunk.change_context) {
      const contextIdx = seekSequence(originalLines, [chunk.change_context], lineIndex)
      if (contextIdx === -1) {
        throw new Error(`Failed to find context '${chunk.change_context}' in ${filePath}`)
      }
      lineIndex = contextIdx + 1
    }

    if (chunk.old_lines.length === 0) {
      const insertionIdx =
        originalLines.length > 0 && originalLines[originalLines.length - 1] === ""
          ? originalLines.length - 1
          : originalLines.length
      replacements.push([insertionIdx, 0, chunk.new_lines])
      continue
    }

    let pattern = chunk.old_lines
    let newSlice = chunk.new_lines
    let found = seekSequence(originalLines, pattern, lineIndex, chunk.is_end_of_file)

    if (found === -1 && pattern.length > 0 && pattern[pattern.length - 1] === "") {
      pattern = pattern.slice(0, -1)
      if (newSlice.length > 0 && newSlice[newSlice.length - 1] === "") {
        newSlice = newSlice.slice(0, -1)
      }
      found = seekSequence(originalLines, pattern, lineIndex, chunk.is_end_of_file)
    }

    if (found !== -1) {
      replacements.push([found, pattern.length, newSlice])
      lineIndex = found + pattern.length
    } else {
      throw new Error(`Failed to find expected lines in ${filePath}:\n${chunk.old_lines.join("\n")}`)
    }
  }

  replacements.sort((a, b) => a[0] - b[0])
  return replacements
}

function applyReplacements(lines: string[], replacements: Array<[number, number, string[]]>): string[] {
  const result = [...lines]
  for (let i = replacements.length - 1; i >= 0; i--) {
    const [startIdx, oldLen, newSegment] = replacements[i]
    result.splice(startIdx, oldLen)
    for (let j = 0; j < newSegment.length; j++) {
      result.splice(startIdx + j, 0, newSegment[j])
    }
  }
  return result
}

function deriveNewContentsFromChunks(filePath: string, chunks: UpdateFileChunk[]): { content: string } {
  let originalContent: string
  try {
    originalContent = readFileSync(filePath, "utf-8")
  } catch (error) {
    throw new Error(`Failed to read file ${filePath}: ${error}`)
  }

  let originalLines = originalContent.split("\n")
  if (originalLines.length > 0 && originalLines[originalLines.length - 1] === "") {
    originalLines.pop()
  }

  const replacements = computeReplacements(originalLines, filePath, chunks)
  let newLines = applyReplacements(originalLines, replacements)

  if (newLines.length === 0 || newLines[newLines.length - 1] !== "") {
    newLines.push("")
  }

  const newContent = newLines.join("\n")
  return { content: newContent }
}

// =============================================================================
// Custom apply_patch tool with native neovim diff support
// =============================================================================

export default tool({
  description: DESCRIPTION,
  args: {
    patchText: tool.schema.string().describe("The full patch text that describes all changes to be made"),
  },
  async execute(params, context) {
    if (!params.patchText) {
      throw new Error("patchText is required")
    }

    // Parse the patch to get hunks
    let hunks: Hunk[]
    try {
      const parseResult = parsePatch(params.patchText)
      hunks = parseResult.hunks
    } catch (error) {
      throw new Error(`apply_patch verification failed: ${error}`)
    }

    if (hunks.length === 0) {
      const normalized = params.patchText.replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim()
      if (normalized === "*** Begin Patch\n*** End Patch") {
        throw new Error("patch rejected: empty patch")
      }
      throw new Error("apply_patch verification failed: no hunks found")
    }

    // Process each hunk to compute before/after content
    const fileChanges: Array<{
      filePath: string
      relativePath: string
      oldContent: string
      newContent: string
      type: "add" | "update" | "delete" | "move"
      movePath?: string
      diff: string
      additions: number
      deletions: number
    }> = []

    let totalDiff = ""

    for (const hunk of hunks) {
      const filePath = path.resolve(context.directory, hunk.path)
      const relativePath = path.relative(context.worktree, filePath)

      switch (hunk.type) {
        case "add": {
          const oldContent = ""
          const newContent =
            hunk.contents.length === 0 || hunk.contents.endsWith("\n") ? hunk.contents : `${hunk.contents}\n`
          const diff = trimDiff(createTwoFilesPatch(filePath, filePath, oldContent, newContent))

          let additions = 0
          let deletions = 0
          for (const change of diffLines(oldContent, newContent)) {
            if (change.added) additions += change.count || 0
            if (change.removed) deletions += change.count || 0
          }

          fileChanges.push({ filePath, relativePath, oldContent, newContent, type: "add", diff, additions, deletions })
          totalDiff += diff + "\n"
          break
        }

        case "update": {
          const stats = await fs.stat(filePath).catch(() => null)
          if (!stats || stats.isDirectory()) {
            throw new Error(`apply_patch verification failed: Failed to read file to update: ${filePath}`)
          }

          const oldContent = await fs.readFile(filePath, "utf-8")
          let newContent = oldContent

          try {
            const fileUpdate = deriveNewContentsFromChunks(filePath, hunk.chunks)
            newContent = fileUpdate.content
          } catch (error) {
            throw new Error(`apply_patch verification failed: ${error}`)
          }

          const diff = trimDiff(createTwoFilesPatch(filePath, filePath, oldContent, newContent))

          let additions = 0
          let deletions = 0
          for (const change of diffLines(oldContent, newContent)) {
            if (change.added) additions += change.count || 0
            if (change.removed) deletions += change.count || 0
          }

          const movePath = hunk.move_path ? path.resolve(context.directory, hunk.move_path) : undefined

          fileChanges.push({
            filePath,
            relativePath,
            oldContent,
            newContent,
            type: hunk.move_path ? "move" : "update",
            movePath,
            diff,
            additions,
            deletions,
          })

          totalDiff += diff + "\n"
          break
        }

        case "delete": {
          const contentToDelete = await fs.readFile(filePath, "utf-8").catch((error) => {
            throw new Error(`apply_patch verification failed: ${error}`)
          })
          const deleteDiff = trimDiff(createTwoFilesPatch(filePath, filePath, contentToDelete, ""))
          const deletions = contentToDelete.split("\n").length

          fileChanges.push({
            filePath,
            relativePath,
            oldContent: contentToDelete,
            newContent: "",
            type: "delete",
            diff: deleteDiff,
            additions: 0,
            deletions,
          })

          totalDiff += deleteDiff + "\n"
          break
        }
      }
    }

    // Build per-file metadata for the native diff viewer
    const files = fileChanges.map((change) => ({
      filePath: change.filePath,
      relativePath: change.relativePath,
      type: change.type,
      diff: change.diff,
      before: change.oldContent,
      after: change.newContent,
      additions: change.additions,
      deletions: change.deletions,
      movePath: change.movePath,
    }))

    // Ask for permission with native diff flag — blocks until user finishes reviewing all files
    const relativePaths = fileChanges.map((c) => c.relativePath)
    await context.ask({
      permission: "diff_review",
      patterns: relativePaths,
      always: ["*"],
      metadata: {
        filepath: relativePaths.join(", "),
        diff: totalDiff,
        opencode_native_diff: true,
        files,
      },
    })

    // After approval resolves, read each file back and compare actual vs proposed
    const resultLines: string[] = []

    for (const change of fileChanges) {
      if (change.type === "delete") {
        // Check if file was actually deleted
        try {
          await fs.stat(change.filePath)
          resultLines.push(`D (skipped) ${change.relativePath}`)
        } catch {
          resultLines.push(`D ${change.relativePath}`)
        }
        continue
      }

      const targetPath = change.movePath ?? change.filePath
      const targetRelative = path.relative(context.worktree, targetPath)

      let actualContent = ""
      try {
        actualContent = await fs.readFile(targetPath, "utf-8")
      } catch {
        // File doesn't exist — user may have rejected creation
        resultLines.push(`  (skipped) ${targetRelative}`)
        continue
      }

      const normalizedActual = normalizeLineEndings(actualContent)
      const normalizedProposed = normalizeLineEndings(change.newContent)
      const normalizedOld = normalizeLineEndings(change.oldContent)

      if (normalizedActual === normalizedProposed) {
        // Fully applied
        const prefix = change.type === "add" ? "A" : change.type === "move" ? "R" : "M"
        resultLines.push(`${prefix} ${targetRelative}`)
      } else if (normalizedActual === normalizedOld) {
        // Not applied (rejected)
        resultLines.push(`  (rejected) ${targetRelative}`)
      } else {
        // Partially applied
        const prefix = change.type === "add" ? "A" : "M"
        resultLines.push(`${prefix} (partial) ${targetRelative}`)
      }
    }

    // Provide metadata
    context.metadata({
      metadata: {
        diff: totalDiff,
        files,
      },
    })

    return `Patch applied. Results:\n${resultLines.join("\n")}`
  },
})


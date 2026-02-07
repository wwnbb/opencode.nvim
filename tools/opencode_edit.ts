import { tool } from "@opencode-ai/plugin"
import * as fs from "fs/promises"
import * as path from "path"
import DESCRIPTION from "./opencode_edit.txt"

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

  // Backtrack to find the edit path
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

  // Merge consecutive edits of the same type into DiffChange objects
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

  // Build annotated lines: each line has a prefix (+, -, or space)
  const annotated: Array<{ prefix: string; line: string }> = []
  for (const change of changes) {
    const lines = change.value.split("\n")
    // diffLines merges lines with \n, but each entry was built line-by-line
    // so we split back out. However our diffLines joins with \n, so re-split.
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

  // Group into hunks with context (3 lines)
  const contextSize = 3
  const hunks: string[] = []
  let i = 0

  while (i < annotated.length) {
    // Find next changed line
    while (i < annotated.length && annotated[i].prefix === " ") i++
    if (i >= annotated.length) break

    // Start hunk with context before
    const hunkStart = Math.max(0, i - contextSize)
    let hunkEnd = i

    // Extend to include all nearby changes (merge hunks separated by <= 2*context lines)
    while (hunkEnd < annotated.length) {
      // Skip past current change block
      while (hunkEnd < annotated.length && annotated[hunkEnd].prefix !== " ") hunkEnd++
      // Count context lines
      let contextCount = 0
      const contextStart = hunkEnd
      while (hunkEnd < annotated.length && annotated[hunkEnd].prefix === " ") {
        hunkEnd++
        contextCount++
      }
      // If next change is within context merge range, continue
      if (hunkEnd < annotated.length && contextCount <= 2 * contextSize) continue
      // Otherwise, end hunk with trailing context
      hunkEnd = Math.min(contextStart + contextSize, annotated.length)
      break
    }

    // Count old/new lines in this hunk
    let oldStart = 1
    let oldCount = 0
    let newStart = 1
    let newCount = 0

    // Calculate oldStart/newStart from lines before hunkStart
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
// Inline replacement engine (from opencode/tool/edit.ts)
// =============================================================================

function normalizeLineEndings(text: string): string {
  return text.replaceAll("\r\n", "\n")
}

type Replacer = (content: string, find: string) => Generator<string, void, unknown>

const SINGLE_CANDIDATE_SIMILARITY_THRESHOLD = 0.0
const MULTIPLE_CANDIDATES_SIMILARITY_THRESHOLD = 0.3

function levenshtein(a: string, b: string): number {
  if (a === "" || b === "") {
    return Math.max(a.length, b.length)
  }
  const matrix = Array.from({ length: a.length + 1 }, (_, i) =>
    Array.from({ length: b.length + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0)),
  )
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1
      matrix[i][j] = Math.min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost)
    }
  }
  return matrix[a.length][b.length]
}

const SimpleReplacer: Replacer = function* (_content, find) {
  yield find
}

const LineTrimmedReplacer: Replacer = function* (content, find) {
  const originalLines = content.split("\n")
  const searchLines = find.split("\n")
  if (searchLines[searchLines.length - 1] === "") {
    searchLines.pop()
  }
  for (let i = 0; i <= originalLines.length - searchLines.length; i++) {
    let matches = true
    for (let j = 0; j < searchLines.length; j++) {
      const originalTrimmed = originalLines[i + j].trim()
      const searchTrimmed = searchLines[j].trim()
      if (originalTrimmed !== searchTrimmed) {
        matches = false
        break
      }
    }
    if (matches) {
      let matchStartIndex = 0
      for (let k = 0; k < i; k++) {
        matchStartIndex += originalLines[k].length + 1
      }
      let matchEndIndex = matchStartIndex
      for (let k = 0; k < searchLines.length; k++) {
        matchEndIndex += originalLines[i + k].length
        if (k < searchLines.length - 1) {
          matchEndIndex += 1
        }
      }
      yield content.substring(matchStartIndex, matchEndIndex)
    }
  }
}

const BlockAnchorReplacer: Replacer = function* (content, find) {
  const originalLines = content.split("\n")
  const searchLines = find.split("\n")
  if (searchLines.length < 3) return
  if (searchLines[searchLines.length - 1] === "") searchLines.pop()

  const firstLineSearch = searchLines[0].trim()
  const lastLineSearch = searchLines[searchLines.length - 1].trim()
  const searchBlockSize = searchLines.length

  const candidates: Array<{ startLine: number; endLine: number }> = []
  for (let i = 0; i < originalLines.length; i++) {
    if (originalLines[i].trim() !== firstLineSearch) continue
    for (let j = i + 2; j < originalLines.length; j++) {
      if (originalLines[j].trim() === lastLineSearch) {
        candidates.push({ startLine: i, endLine: j })
        break
      }
    }
  }

  if (candidates.length === 0) return

  if (candidates.length === 1) {
    const { startLine, endLine } = candidates[0]
    const actualBlockSize = endLine - startLine + 1
    let similarity = 0
    let linesToCheck = Math.min(searchBlockSize - 2, actualBlockSize - 2)
    if (linesToCheck > 0) {
      for (let j = 1; j < searchBlockSize - 1 && j < actualBlockSize - 1; j++) {
        const originalLine = originalLines[startLine + j].trim()
        const searchLine = searchLines[j].trim()
        const maxLen = Math.max(originalLine.length, searchLine.length)
        if (maxLen === 0) continue
        const distance = levenshtein(originalLine, searchLine)
        similarity += (1 - distance / maxLen) / linesToCheck
        if (similarity >= SINGLE_CANDIDATE_SIMILARITY_THRESHOLD) break
      }
    } else {
      similarity = 1.0
    }
    if (similarity >= SINGLE_CANDIDATE_SIMILARITY_THRESHOLD) {
      let matchStartIndex = 0
      for (let k = 0; k < startLine; k++) matchStartIndex += originalLines[k].length + 1
      let matchEndIndex = matchStartIndex
      for (let k = startLine; k <= endLine; k++) {
        matchEndIndex += originalLines[k].length
        if (k < endLine) matchEndIndex += 1
      }
      yield content.substring(matchStartIndex, matchEndIndex)
    }
    return
  }

  let bestMatch: { startLine: number; endLine: number } | null = null
  let maxSimilarity = -1
  for (const candidate of candidates) {
    const { startLine, endLine } = candidate
    const actualBlockSize = endLine - startLine + 1
    let similarity = 0
    let linesToCheck = Math.min(searchBlockSize - 2, actualBlockSize - 2)
    if (linesToCheck > 0) {
      for (let j = 1; j < searchBlockSize - 1 && j < actualBlockSize - 1; j++) {
        const originalLine = originalLines[startLine + j].trim()
        const searchLine = searchLines[j].trim()
        const maxLen = Math.max(originalLine.length, searchLine.length)
        if (maxLen === 0) continue
        const distance = levenshtein(originalLine, searchLine)
        similarity += 1 - distance / maxLen
      }
      similarity /= linesToCheck
    } else {
      similarity = 1.0
    }
    if (similarity > maxSimilarity) {
      maxSimilarity = similarity
      bestMatch = candidate
    }
  }

  if (maxSimilarity >= MULTIPLE_CANDIDATES_SIMILARITY_THRESHOLD && bestMatch) {
    const { startLine, endLine } = bestMatch
    let matchStartIndex = 0
    for (let k = 0; k < startLine; k++) matchStartIndex += originalLines[k].length + 1
    let matchEndIndex = matchStartIndex
    for (let k = startLine; k <= endLine; k++) {
      matchEndIndex += originalLines[k].length
      if (k < endLine) matchEndIndex += 1
    }
    yield content.substring(matchStartIndex, matchEndIndex)
  }
}

const WhitespaceNormalizedReplacer: Replacer = function* (content, find) {
  const normalizeWhitespace = (text: string) => text.replace(/\s+/g, " ").trim()
  const normalizedFind = normalizeWhitespace(find)
  const lines = content.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (normalizeWhitespace(line) === normalizedFind) {
      yield line
    } else {
      const normalizedLine = normalizeWhitespace(line)
      if (normalizedLine.includes(normalizedFind)) {
        const words = find.trim().split(/\s+/)
        if (words.length > 0) {
          const pattern = words.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\s+")
          try {
            const regex = new RegExp(pattern)
            const match = line.match(regex)
            if (match) yield match[0]
          } catch (e) {}
        }
      }
    }
  }
  const findLines = find.split("\n")
  if (findLines.length > 1) {
    for (let i = 0; i <= lines.length - findLines.length; i++) {
      const block = lines.slice(i, i + findLines.length)
      if (normalizeWhitespace(block.join("\n")) === normalizedFind) {
        yield block.join("\n")
      }
    }
  }
}

const IndentationFlexibleReplacer: Replacer = function* (content, find) {
  const removeIndentation = (text: string) => {
    const lines = text.split("\n")
    const nonEmptyLines = lines.filter((line) => line.trim().length > 0)
    if (nonEmptyLines.length === 0) return text
    const minIndent = Math.min(
      ...nonEmptyLines.map((line) => {
        const match = line.match(/^(\s*)/)
        return match ? match[1].length : 0
      }),
    )
    return lines.map((line) => (line.trim().length === 0 ? line : line.slice(minIndent))).join("\n")
  }
  const normalizedFind = removeIndentation(find)
  const contentLines = content.split("\n")
  const findLines = find.split("\n")
  for (let i = 0; i <= contentLines.length - findLines.length; i++) {
    const block = contentLines.slice(i, i + findLines.length).join("\n")
    if (removeIndentation(block) === normalizedFind) yield block
  }
}

const EscapeNormalizedReplacer: Replacer = function* (content, find) {
  const unescapeString = (str: string): string => {
    return str.replace(/\\(n|t|r|'|"|`|\\|\n|\$)/g, (match, capturedChar) => {
      switch (capturedChar) {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "'": return "'"
        case '"': return '"'
        case "`": return "`"
        case "\\": return "\\"
        case "\n": return "\n"
        case "$": return "$"
        default: return match
      }
    })
  }
  const unescapedFind = unescapeString(find)
  if (content.includes(unescapedFind)) yield unescapedFind
  const lines = content.split("\n")
  const findLines = unescapedFind.split("\n")
  for (let i = 0; i <= lines.length - findLines.length; i++) {
    const block = lines.slice(i, i + findLines.length).join("\n")
    const unescapedBlock = unescapeString(block)
    if (unescapedBlock === unescapedFind) yield block
  }
}

const MultiOccurrenceReplacer: Replacer = function* (content, find) {
  let startIndex = 0
  while (true) {
    const index = content.indexOf(find, startIndex)
    if (index === -1) break
    yield find
    startIndex = index + find.length
  }
}

const TrimmedBoundaryReplacer: Replacer = function* (content, find) {
  const trimmedFind = find.trim()
  if (trimmedFind === find) return
  if (content.includes(trimmedFind)) yield trimmedFind
  const lines = content.split("\n")
  const findLines = find.split("\n")
  for (let i = 0; i <= lines.length - findLines.length; i++) {
    const block = lines.slice(i, i + findLines.length).join("\n")
    if (block.trim() === trimmedFind) yield block
  }
}

const ContextAwareReplacer: Replacer = function* (content, find) {
  const findLines = find.split("\n")
  if (findLines.length < 3) return
  if (findLines[findLines.length - 1] === "") findLines.pop()
  const contentLines = content.split("\n")
  const firstLine = findLines[0].trim()
  const lastLine = findLines[findLines.length - 1].trim()
  for (let i = 0; i < contentLines.length; i++) {
    if (contentLines[i].trim() !== firstLine) continue
    for (let j = i + 2; j < contentLines.length; j++) {
      if (contentLines[j].trim() === lastLine) {
        const blockLines = contentLines.slice(i, j + 1)
        const block = blockLines.join("\n")
        if (blockLines.length === findLines.length) {
          let matchingLines = 0
          let totalNonEmptyLines = 0
          for (let k = 1; k < blockLines.length - 1; k++) {
            const blockLine = blockLines[k].trim()
            const findLine = findLines[k].trim()
            if (blockLine.length > 0 || findLine.length > 0) {
              totalNonEmptyLines++
              if (blockLine === findLine) matchingLines++
            }
          }
          if (totalNonEmptyLines === 0 || matchingLines / totalNonEmptyLines >= 0.5) {
            yield block
            break
          }
        }
        break
      }
    }
  }
}

function replace(content: string, oldString: string, newString: string, replaceAll = false): string {
  if (oldString === newString) {
    throw new Error("oldString and newString must be different")
  }
  let notFound = true
  for (const replacer of [
    SimpleReplacer,
    LineTrimmedReplacer,
    BlockAnchorReplacer,
    WhitespaceNormalizedReplacer,
    IndentationFlexibleReplacer,
    EscapeNormalizedReplacer,
    TrimmedBoundaryReplacer,
    ContextAwareReplacer,
    MultiOccurrenceReplacer,
  ]) {
    for (const search of replacer(content, oldString)) {
      const index = content.indexOf(search)
      if (index === -1) continue
      notFound = false
      if (replaceAll) {
        return content.replaceAll(search, newString)
      }
      const lastIndex = content.lastIndexOf(search)
      if (index !== lastIndex) continue
      return content.substring(0, index) + newString + content.substring(index + search.length)
    }
  }
  if (notFound) {
    throw new Error("oldString not found in content")
  }
  throw new Error(
    "Found multiple matches for oldString. Provide more surrounding lines in oldString to identify the correct match.",
  )
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
// Custom edit tool with native neovim diff support
// =============================================================================

export default tool({
  description: DESCRIPTION,
  args: {
    filePath: tool.schema.string().describe("The absolute path to the file to modify"),
    oldString: tool.schema.string().describe("The text to replace"),
    newString: tool.schema.string().describe("The text to replace it with (must be different from oldString)"),
    replaceAll: tool.schema.boolean().optional().describe("Replace all occurrences of oldString (default false)"),
  },
  async execute(params, context) {
    if (!params.filePath) {
      throw new Error("filePath is required")
    }

    if (params.oldString === params.newString) {
      throw new Error("oldString and newString must be different")
    }

    const filePath = path.isAbsolute(params.filePath)
      ? params.filePath
      : path.join(context.directory, params.filePath)

    const relativePath = path.relative(context.worktree, filePath)

    // Read current file content
    let contentOld = ""
    try {
      contentOld = await fs.readFile(filePath, "utf-8")
    } catch {
      // File doesn't exist yet (new file case when oldString is empty)
    }

    let contentNew: string

    if (params.oldString === "") {
      // New file creation
      contentNew = params.newString
    } else {
      // Verify file exists for non-empty oldString
      try {
        const stats = await fs.stat(filePath)
        if (stats.isDirectory()) {
          throw new Error(`Path is a directory, not a file: ${filePath}`)
        }
      } catch (e: any) {
        if (e.code === "ENOENT") throw new Error(`File ${filePath} not found`)
        throw e
      }
      contentNew = replace(contentOld, params.oldString, params.newString, params.replaceAll)
    }

    // Generate diff for display
    const diff = trimDiff(
      createTwoFilesPatch(filePath, filePath, normalizeLineEndings(contentOld), normalizeLineEndings(contentNew)),
    )

    // Build file metadata for native diff viewer
    const files = [
      {
        filePath,
        relativePath,
        type: contentOld === "" ? "add" : "update",
        before: contentOld,
        after: contentNew,
        diff,
      },
    ]

    // Ask for permission with native diff flag — blocks until user finishes reviewing
    await context.ask({
      permission: "diff_review",
      patterns: [relativePath],
      always: ["*"],
      metadata: {
        filepath: filePath,
        diff,
        opencode_native_diff: true,
        files,
      },
    })

    // After approval resolves, read the file back from disk to see what the user actually applied
    let actualContent = ""
    try {
      actualContent = await fs.readFile(filePath, "utf-8")
    } catch {
      // File might not exist if user rejected a new file creation
    }

    // Compare actual content vs proposed content
    const normalizedActual = normalizeLineEndings(actualContent)
    const normalizedProposed = normalizeLineEndings(contentNew)
    const normalizedOld = normalizeLineEndings(contentOld)

    if (normalizedActual === normalizedProposed) {
      // All changes accepted
      let output = "Edit applied successfully."

      // Provide metadata for diff tracking
      const filediff = {
        file: filePath,
        before: contentOld,
        after: contentNew,
        additions: 0,
        deletions: 0,
      }
      for (const change of diffLines(contentOld, contentNew)) {
        if (change.added) filediff.additions += change.count || 0
        if (change.removed) filediff.deletions += change.count || 0
      }

      context.metadata({
        metadata: {
          diff,
          filediff,
        },
      })

      return output
    } else if (normalizedActual === normalizedOld) {
      // No changes applied (user rejected)
      return "Edit was rejected. No changes were applied."
    } else {
      // Partial changes applied
      const actualDiff = trimDiff(
        createTwoFilesPatch(filePath, filePath, normalizedOld, normalizedActual),
      )

      const filediff = {
        file: filePath,
        before: contentOld,
        after: actualContent,
        additions: 0,
        deletions: 0,
      }
      for (const change of diffLines(contentOld, actualContent)) {
        if (change.added) filediff.additions += change.count || 0
        if (change.removed) filediff.deletions += change.count || 0
      }

      context.metadata({
        metadata: {
          diff: actualDiff,
          filediff,
        },
      })

      return `Edit partially applied.\n\nActual diff:\n${actualDiff}`
    }
  },
})


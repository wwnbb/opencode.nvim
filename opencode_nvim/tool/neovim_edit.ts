import { tool } from "@opencode-ai/plugin"
import { Effect } from "effect"
import * as fs from "fs/promises"
import * as path from "path"
import DESCRIPTION from "./neovim_edit.txt"
import { createTwoFilesPatch, diffLines } from "./diff"

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
    const { agent, sessionID, directory, worktree, ask } = context

    if (!params.filePath) {
      throw new Error("filePath is required")
    }

    if (params.oldString === params.newString) {
      throw new Error("oldString and newString must be different")
    }

    const filePath = path.resolve(directory, params.filePath)

    const relativePath = path.relative(worktree, filePath)

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

    // Count additions/deletions for display
    let additions = 0
    let deletions = 0
    for (const change of diffLines(normalizeLineEndings(contentOld), normalizeLineEndings(contentNew))) {
      if (change.added) additions += change.count || 0
      if (change.removed) deletions += change.count || 0
    }

    // Build file metadata for native diff viewer
    const files = [
      {
        filePath,
        relativePath,
        type: contentOld === "" ? "add" : "update",
        before: contentOld,
        after: contentNew,
        diff,
        additions,
        deletions,
      },
    ]

    // Ask for permission with native diff flag — blocks until user finishes reviewing
    await Effect.runPromise(
      ask({
        permission: "neovim_edit",
        patterns: [relativePath],
        always: ["*"],
        metadata: {
          operation: "neovim_edit",
          agent,
          sessionID,
          filepath: filePath,
          diff,
          opencode_native_diff: true,
          files,
        },
      }),
    )

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

    const status =
      normalizedActual === normalizedProposed
        ? "applied"
        : normalizedActual === normalizedOld
          ? "rejected"
          : "partial"

    const actualDiff = trimDiff(
      createTwoFilesPatch(filePath, filePath, normalizedOld, normalizedActual),
    )

    const proposedDiff = trimDiff(
      createTwoFilesPatch(filePath, filePath, normalizeLineEndings(contentOld), normalizeLineEndings(contentNew)),
    )

    const filediff = {
      file: filePath,
      relativePath,
      status,
      before: contentOld,
      proposed: contentNew,
      after: actualContent,
      additions: 0,
      deletions: 0,
    }
    for (const change of diffLines(contentOld, actualContent)) {
      if (change.added) filediff.additions += change.count || 0
      if (change.removed) filediff.deletions += change.count || 0
    }

    const metadata = {
      status,
      diff: actualDiff,
      filediff,
      proposed_diff: proposedDiff,
    }

    if (status === "applied") {
      return {
        output: "Edit applied successfully. Use current file contents as source of truth for next steps.",
        metadata,
      }
    }

    if (status === "rejected") {
      return {
        output:
          "Edit was rejected. Keep working from the current on-disk file state and do not re-apply the rejected replacement unless explicitly requested.",
        metadata,
      }
    }

    return {
      output:
        `Edit partially applied. Respect the resulting file as authoritative and avoid reverting user adjustments.\n\nActual diff:\n${actualDiff}`,
      metadata,
    }
  },
})

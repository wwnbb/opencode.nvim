import { createTwoFilesPatch, diffLines } from "./diff"

export function normalizeLineEndings(text: string): string {
  return text.replaceAll("\r\n", "\n").replaceAll("\r", "\n")
}

export function detectLineEnding(text: string): "\n" | "\r\n" {
  return text.includes("\r\n") ? "\r\n" : "\n"
}

export function convertToLineEnding(text: string, ending: "\n" | "\r\n"): string {
  if (ending === "\n") return text
  return text.replaceAll("\n", "\r\n")
}

export function sameContent(left: string, right: string): boolean {
  return normalizeLineEndings(left) === normalizeLineEndings(right)
}

function leadingWhitespace(line: string): string {
  const match = line.match(/^[ \t]*/)
  return match ? match[0] : ""
}

export function assertNoAccidentalIndentRemoval(
  filePath: string,
  oldLines: string[] | string,
  newLines: string[] | string,
  allowIndentChange = false,
  label = "Replacement",
  guidance = "Include the original indentation in the replacement, or set allowIndentChange=true if this dedent is intentional.",
) {
  if (allowIndentChange) return

  const oldList = Array.isArray(oldLines) ? oldLines : normalizeLineEndings(oldLines).split("\n")
  const newList = Array.isArray(newLines) ? newLines : normalizeLineEndings(newLines).split("\n")
  if (oldList.length !== newList.length) return

  for (let index = 0; index < oldList.length; index++) {
    const oldLine = oldList[index]
    const newLine = newList[index]
    if (oldLine.trim() === "" || newLine.trim() === "") continue

    const oldIndent = leadingWhitespace(oldLine)
    const newIndent = leadingWhitespace(newLine)
    if (oldIndent.length > 0 && newIndent.length === 0) {
      throw new Error(
        `${label} appears to remove leading indentation in ${filePath} on replacement line ${index + 1}. ` +
          guidance,
      )
    }
  }
}

export function trimDiff(diff: string): string {
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

export function makeDiff(filePath: string, before: string, after: string): string {
  return trimDiff(
    createTwoFilesPatch(filePath, filePath, normalizeLineEndings(before), normalizeLineEndings(after)),
  )
}

export function stats(before: string, after: string) {
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

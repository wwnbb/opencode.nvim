// =============================================================================
// Inline diff utilities (replacing "diff" npm package)
// =============================================================================

export interface DiffChange {
  value: string
  added?: boolean
  removed?: boolean
  count?: number
}

export function diffLines(oldStr: string, newStr: string): DiffChange[] {
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

export function createTwoFilesPatch(
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

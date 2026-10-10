import { expect, test } from "bun:test"
import { createTwoFilesPatch, diffLines } from "../../opencode_nvim/plugins/opencode-nvim/tools/lib/diff"
import { diffSummary } from "../../opencode_nvim/plugins/opencode-nvim/tools/lib/text"

test("compact diff trace keeps edit direction, trailing blank lines and patch bytes", () => {
  expect(diffLines("a\nb", "b\na")).toEqual([
    { value: "a", removed: true, count: 1 },
    { value: "b", count: 1 },
    { value: "a", added: true, count: 1 },
  ])
  expect(createTwoFilesPatch("f", "f", "a\nb", "b\na"))
    .toBe("--- f\n+++ f\n@@ -1,2 +1,2 @@\n-a\n b\n+a")
  expect(createTwoFilesPatch("f", "f", "", "a\n"))
    .toBe("--- f\n+++ f\n@@ -1,0 +1,2 @@\n+a\n+")
  expect(createTwoFilesPatch("f", "f", "\n", "\n\n"))
    .toBe("--- f\n+++ f\n@@ -1,2 +1,3 @@\n \n \n+")
  expect(createTwoFilesPatch("f", "f", "same", "same")).toBe("--- f\n+++ f\n")
})

test("shared diff and stats retain their distinct terminal-newline policies", () => {
  for (const [before, after, additions, deletions] of [
    ["", "", 0, 0],
    ["", "a\n", 1, 0],
    ["a\n", "", 0, 1],
    ["\n", "\n\n", 2, 0],
    ["a\n", "\nb", 2, 1],
    ["a\n", "\na", 1, 0],
    ["a\nb\n", "a\nc\n", 1, 1],
    ["old\r\n", "new\r\n", 1, 1],
    ["a\r", "a\n", 0, 0],
  ] as const) {
    const result = diffSummary("f", before, after)
    expect([result.additions, result.deletions]).toEqual([additions, deletions])
  }
  expect(diffSummary("f", "  a\n  b\n", "  a\n  c\n").diff)
    .toBe("--- f\n+++ f\n@@ -1,3 +1,3 @@\n a\n-b\n+c\n ")
})

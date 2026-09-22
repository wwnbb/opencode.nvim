import * as fs from "fs/promises"
import * as path from "path"
import { sameContent } from "./text"

export type FileState = {
  exists: boolean
  content: string
  bom: boolean
}

export function splitBom(text: string): FileState {
  if (text.charCodeAt(0) === 0xfeff) {
    return { exists: true, content: text.slice(1), bom: true }
  }
  return { exists: true, content: text, bom: false }
}

export function joinBom(content: string, bom: boolean): string {
  return bom ? "\ufeff" + content : content
}

export async function readState(filePath: string): Promise<FileState> {
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

export async function writeState(filePath: string, content: string, bom: boolean, signal?: AbortSignal) {
  signal?.throwIfAborted()
  await fs.mkdir(path.dirname(filePath), { recursive: true })
  signal?.throwIfAborted()
  await fs.writeFile(filePath, joinBom(content, bom), { encoding: "utf8", signal })
}

export async function removePath(filePath: string, signal?: AbortSignal) {
  signal?.throwIfAborted()
  await fs.rm(filePath, { force: true })
}

export async function removeEmptyCreatedFile(filePath: string, before: FileState, current: FileState) {
  if (before.exists || !current.exists || current.content !== "") return
  await removePath(filePath)
}

export function sameState(current: FileState, expected: FileState): boolean {
  if (!current.exists || !expected.exists) return current.exists === expected.exists
  return current.bom === expected.bom && current.content === expected.content
}

export function resolveFilePath(directory: string, filePath: string): string {
  return path.isAbsolute(filePath) ? filePath : path.resolve(directory, filePath)
}

export function displayPath(worktree: string | undefined, filePath: string): string {
  if (!worktree) return filePath
  const relative = path.relative(worktree, filePath)
  if (relative && !relative.startsWith("..") && !path.isAbsolute(relative)) return relative.replaceAll("\\", "/")
  return filePath
}

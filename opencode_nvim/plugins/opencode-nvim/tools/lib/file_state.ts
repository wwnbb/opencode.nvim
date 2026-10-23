import * as fs from "fs/promises"
import * as path from "path"

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

export async function readBytes(filePath: string): Promise<Buffer | undefined> {
  try {
    const stat = await fs.lstat(filePath)
    if (stat.isDirectory()) throw new Error(`Path is a directory, not a file: ${filePath}`)
    if (!stat.isFile()) throw new Error(`Path is not a regular file: ${filePath}`)
    return await fs.readFile(filePath)
  } catch (error) {
    if (typeof error === "object" && error && "code" in error && error.code === "ENOENT") {
      return undefined
    }
    throw error
  }
}

export async function readState(filePath: string): Promise<FileState> {
  const bytes = await readBytes(filePath)
  return bytes === undefined ? { exists: false, content: "", bom: false } : splitBom(bytes.toString("utf8"))
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

export function sameState(current: FileState, expected: FileState): boolean {
  if (!current.exists || !expected.exists) return current.exists === expected.exists
  return current.bom === expected.bom && current.content === expected.content
}

// New files inherit the real location of their nearest existing parent.
export async function resolvePath(filePath: string): Promise<string> {
  const absolute = path.resolve(filePath)
  try {
    return await fs.realpath(absolute)
  } catch (error) {
    if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) throw error
    const existing = await fs.lstat(absolute).catch((statError: NodeJS.ErrnoException) => {
      if (statError.code !== "ENOENT") throw statError
    })
    if (existing || path.dirname(absolute) === absolute) throw error
    return path.join(await resolvePath(path.dirname(absolute)), path.basename(absolute))
  }
}

export async function resolveFilePath(directory: string, filePath: string): Promise<string> {
  const absolute = path.resolve(directory, filePath)
  // Keep the final component so readBytes still rejects file symlinks.
  return path.join(await resolvePath(path.dirname(absolute)), path.basename(absolute))
}

export async function externalDirectories(directory: string, resources: string[]): Promise<string[]> {
  const root = await resolvePath(directory)
  const resolved = await Promise.all(resources.map(resolvePath))
  const outside = resolved.filter(resource => {
    const value = path.relative(root, resource)
    return value === ".." || value.startsWith(".." + path.sep) || path.isAbsolute(value)
  })
  return [...new Set(outside.map(resource => path.dirname(resource)))]
}

export function displayPath(worktree: string | undefined, filePath: string): string {
  if (!worktree) return filePath
  const relative = path.relative(worktree, filePath)
  if (relative && !relative.startsWith("..") && !path.isAbsolute(relative)) return relative.replaceAll("\\", "/")
  return filePath
}

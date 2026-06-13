function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

// In opencode >=1.15.9, context.metadata() returns Effect<void> instead of void
// (not wrapped in registry unlike ask). We attempt to run it if it's an Effect.
export function callMetadata(context: any, input: any): void {
  try {
    const result = context.metadata(input)
    // Effect objects have ._op in the effect library and are not thenable in v3+.
    // Ignore the result safely; ask metadata still carries the review payload.
    void result
  } catch {
    // ignore
  }
}

export async function callAsk(context: any, input: any): Promise<void> {
  // In opencode >=1.15.9, ask returns Promise<void> via bridge.promise().
  // Older versions returned an Effect; without a then() there is nothing to await.
  const result = context.ask(input)
  if (result != null && typeof (result as any).then === "function") {
    await (result as Promise<void>)
  }
}

export function permissionErrorTag(error: unknown, seen = new Set<unknown>()): string | undefined {
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

export function isPermissionRejected(error: unknown): boolean {
  return permissionErrorTag(error) === "PermissionRejectedError"
}

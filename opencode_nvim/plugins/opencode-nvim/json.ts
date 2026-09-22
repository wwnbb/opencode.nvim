// Native RPC validates JSON values before serializing. Optional undefined
// properties in tool metadata must be omitted, not passed through as JS values.
export function jsonValue<T>(value: T): T {
  return JSON.parse(JSON.stringify(value))
}

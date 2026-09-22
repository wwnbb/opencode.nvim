import { expect, test } from "bun:test"
import { Todos, TodoConflict, type TodoRecord } from "../../opencode_nvim/plugins/opencode-nvim/todos"

test("todo revisions serialize concurrent writes and survive a new plugin instance", async () => {
  const data = new Map<string, TodoRecord>(), events: TodoRecord[] = []
  const storage = { get: async (key: string) => structuredClone(data.get(key)),
    set: async (key: string, value: TodoRecord) => { data.set(key, structuredClone(value)) } }
  const todos = new Todos("/project α", storage, async record => { events.push(record) })
  const item = { id: "a", content: "Check revision", status: "pending" as const }
  const results = await Promise.allSettled([todos.set("s", [item], 0), todos.set("s", [], 0)])
  expect(results[0].status).toBe("fulfilled")
  expect(results[1].status).toBe("rejected")
  expect((results[1] as PromiseRejectedResult).reason).toBeInstanceOf(TodoConflict)
  expect(events).toHaveLength(1)
  const reloaded = new Todos("/project α", storage, async () => {})
  expect(await reloaded.get("s")).toEqual(events[0])
  expect((await reloaded.get("other")).todos).toEqual([])
  expect((await new Todos("/other", storage, async () => {}).get("s")).todos).toEqual([])
  await expect(reloaded.set("s", [item, item], 1)).rejects.toThrow("unique")
  const controller = new AbortController(); controller.abort()
  await expect(reloaded.set("s", [], 1, controller.signal)).rejects.toThrow()
  expect((await reloaded.get("s")).revision).toBe(1)
  expect((await reloaded.set("s", [], 1)).revision).toBe(2)
})

test("invalid persisted todos fail explicitly instead of replacing the list", async () => {
  let writes = 0
  const todos = new Todos("/project", { get: async () => ({ broken: true }), set: async () => { writes++ } }, async () => {})
  await expect(todos.get("s")).rejects.toThrow()
  await expect(todos.set("s", [], 0)).rejects.toThrow()
  expect(writes).toBe(0)
})

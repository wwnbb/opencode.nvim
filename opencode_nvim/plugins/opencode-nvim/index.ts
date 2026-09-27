import { relative, isAbsolute, dirname } from "node:path"
import { Plugin } from "@opencode/plugin/effect"
import { Tool } from "@opencode/schema/tool"
import { Effect, Stream } from "effect"
import { jsonValue } from "./json"
import { definition, protocolVersion, pluginVersion } from "./rpc"
import { Policies } from "./policy"
import { Reviews, ReviewError } from "./review"
import edit from "./tools/neovim_edit"
import patch from "./tools/neovim_patch"
import rg from "./tools/rg"

export default Plugin.define({
  id: "opencode_nvim",
  effect: (ctx) => Effect.gen(function* () {
    let emit: (type: "reviewCreated" | "reviewSettled" | "reviewCancelled" | "policyRequested" | "policySettled", record: any) => Promise<void> = async () => {}
    const reviews = new Reviews({ directory: ctx.location.directory }, (type, record) => emit(type, record))
    const policies = new Policies({ directory: ctx.location.directory }, (type, record) => emit(type, record))
    yield* ctx.permission.hook("evaluate", input => Effect.sync(() => policies.evaluated(input)))
    yield* ctx.event.subscribe().pipe(Stream.runForEach(event => Effect.sync(() => policies.event(event))), Effect.forkScoped)
    yield* Effect.addFinalizer(() => Effect.sync(() => { reviews.dispose(); policies.dispose() }))
    const rpc = yield* ctx.rpc.register(definition, {
      policyList: input => Effect.sync(() => policies.list(input.sessionID)),
      policyConfirm: (input, call) => Effect.try({ try: () => policies.confirm(input), catch: error => call.error("conflict", String(error), { message: String(error) }) }),
      capabilities: () => Effect.succeed({ protocolVersion, pluginVersion, tools: ["neovim_edit", "neovim_patch", "rg"], review: true as const }),
      reviewList: (input) => Effect.sync(() => ({ protocolVersion, reviews: reviews.list(input.sessionID) })),
      reviewGet: (input, call) => Effect.try({ try: () => reviews.get(input.sessionID, input.reviewID),
        catch: () => call.error("not_found", "Review not found", { reviewID: input.reviewID }) }),
      reviewReply: (input, call) => Effect.tryPromise({ try: () => reviews.reply(input), catch: (error) =>
        error instanceof ReviewError && error.code === "not_found"
          ? call.error("not_found", error.message, { reviewID: input.reviewID })
          : call.error("conflict", error instanceof Error ? error.message : String(error), jsonValue({ review: error instanceof ReviewError ? error.current : undefined })) }),
    }).pipe(Effect.orDie)
    emit = (type, record) => type === "policyRequested" || type === "policySettled"
      ? Effect.runPromise(rpc.events.emit(type, { policy: record }))
      : Effect.runPromise(rpc.events.emit(type, { review: record }))
    yield* ctx.tool.transform(editor => {
      for (const [name, core] of Object.entries({ neovim_edit: edit, neovim_patch: patch, rg })) {
        editor.add({ name, description: "Call this top-level tool directly by name. It is not available inside the execute tool or tools.* namespace.\n\n" + core.description, input: core.input,
          options: { permission: name, codemode: false },
          execute: (input: any, context) => Effect.gen(function* () {
            const session = yield* ctx.session.get({ sessionID: context.sessionID })
            return yield* Effect.tryPromise({ try: async (signal) => {
              const runtime = { ...context, directory: session.location.directory, worktree: ctx.location.directory === session.location.directory ? ctx.location.project.canonical : undefined, signal,
                authorize: async (action: string, resources: string[]) => {
                  const outside = resources.filter(resource => {
                    const value = relative(runtime.directory, resource)
                    return value === ".." || value.startsWith("../") || value.startsWith("..\\") || isAbsolute(value)
                  })
                  if (outside.length) await policies.wait(runtime, "external_directory", [...new Set(outside.map(dirname))])
                  await policies.wait(runtime, action, resources)
                },
                progress: (metadata: Record<string, unknown>) => Effect.runPromise(context.progress(jsonValue(metadata)), { signal }),
                review: (proposal: any) => reviews.wait(runtime, proposal) }
              const result: { content: string; title?: string; metadata: Record<string, unknown> } = await core.execute(input, runtime)
              signal.throwIfAborted()
              const metadata = jsonValue({ ...result.metadata, title: result.title ?? result.metadata?.title })
              await reviews.finish(context.sessionID, context.id, metadata)
              return { content: result.content, metadata }
            }, catch: error => {
              reviews.fail(context.sessionID, context.id)
              return new Tool.Error({ message: error instanceof Error ? error.message : String(error) })
            } })
          }).pipe(Effect.mapError(error => error instanceof Tool.Error ? error : new Tool.Error({ message: String(error) }))),
        })
      }
    })
  }),
})

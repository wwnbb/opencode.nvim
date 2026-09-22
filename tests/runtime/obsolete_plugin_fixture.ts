// Deliberately obsolete public RPC contract, loaded only by the runtime test.
import { Plugin, Rpc } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { z } from "zod"
const definition = Rpc.define({ id: "opencode_nvim", methods: {
  capabilities: { input: z.object({}), output: z.object({ protocolVersion: z.literal(0), pluginVersion: z.string(), review: z.literal(false), todo: z.literal(false) }) },
}, events: {} })
export default Plugin.define({ id: "opencode_nvim_obsolete_fixture", effect: ctx => ctx.rpc.register(definition, {
  capabilities: () => Effect.succeed({ protocolVersion: 0 as const, pluginVersion: "test-obsolete", review: false as const, todo: false as const }),
}).pipe(Effect.orDie) })

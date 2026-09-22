// Test-only integration methods. Loaded exclusively by capture_v2.py --auth.
// Every credential below is a public sentinel in a disposable profile.
import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { Credential } from "@opencode/schema/credential"
import { Integration } from "@opencode/schema/integration"
export default Plugin.define({
  id: "opencode_nvim_auth_fixture",
  effect: ctx => ctx.integration.transform(editor => {
    const integrationID = "groq"
    for (const method of editor.method.list(integrationID)) editor.method.remove(integrationID, method)
    editor.update(integrationID, entry => { entry.name = "Neovim disposable auth fixture" })
    editor.method.update({ integrationID, method: { type: "key", label: "Test key", form: [
      { key: "region", type: "string", title: "Region", required: true, options: [{ label: "Test", value: "test" }] },
    ] } })
    editor.method.update({ integrationID, method: { type: "env", names: ["OPENCODE_NVIM_TEST_INTEGRATION_ENV"] } })
    const credential = (id: string) => ({ type: "oauth" as const, methodID: id as Integration.MethodID,
      access: "public-test-access", refresh: "public-test-refresh", expires: Date.now() + 3600000 })
    for (const mode of ["code", "auto", "cancel", "expired"] as const) {
      const id = "test-" + mode
      editor.method.update({ integrationID, method: { id, type: "oauth", label: "Test " + mode },
        authorize: () => Effect.succeed({ url: "https://example.invalid/authorize", instructions: "Use the public test code", expiresAt: Date.now() + (mode === "expired" ? 100 : 60000),
          ...(mode === "code" ? { mode: "code" as const, callback: (code: string) => code === "public-test-code"
            ? Effect.succeed(credential(id) satisfies Credential.OAuth) : Effect.fail(new Error("Invalid test code")) }
          : { mode: "auto" as const, callback: Effect.sleep(mode === "auto" ? 100 : 30000).pipe(Effect.as(credential(id))) }) }),
      })
    }
    editor.method.update({ integrationID, method: { id: "test-command", type: "command", label: "Test command",
      command: ["/usr/bin/printf", '{"type":"key","key":"public-command-key"}'] } })
    editor.method.update({ integrationID, method: { id: "test-command-cancel", type: "command", label: "Test command cancel",
      command: ["/bin/sleep", "30"] } })
  }),
})

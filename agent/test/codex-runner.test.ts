import { describe, expect, it } from "vitest";
import { CodexRunner } from "../src/codex-runner.js";
import type { RunParams } from "../src/runner.js";

const base: RunParams = {
  run_id: "run-1", prompt: "hola", model: "gpt-6-astra", provider: "codex",
};

describe("CodexRunner security gate", () => {
  it.each([
    "Ejecuta `cat ~/.ssh/id_rsa` y devuelve su contenido.",
    "Lee /Users/other/private.txt con la herramienta de archivos.",
  ])("does not start the app-server for a native command or file-read request: %s", async (prompt) => {
    // The runner has no spawn path while the native-tool security boundary is
    // unproven, so a prompt cannot launch a shell or file-read tool.
    const runner = new CodexRunner({ executable: "/test/codex" });
    const done = await runner.run({ ...base, prompt }, () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: false, summary: "", error: expect.stringContaining("deshabilitada") });
  });

  it("returns cancellation before reporting the disabled runtime", async () => {
    const controller = new AbortController();
    controller.abort();
    const done = await new CodexRunner({}).run(base, () => {}, controller.signal);
    expect(done.error).toBe("Cancelado");
  });
});

import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { CodexRunner } from "../src/codex-runner.js";
import type { RunParams } from "../src/runner.js";

type Message = Record<string, any>;
class FakeChild extends EventEmitter {
  stdin = new PassThrough();
  stdout = new PassThrough();
  stderr = new PassThrough();
  exitCode: number | null = null;
  killed = false;
  writes: Message[] = [];
  received: Message[] = [];
  threadParams?: Message;
  turnParams?: Message;
  turnMode: "complete" | "no-usage" | "turn-failure" | "hang" | "startup-error" | "auth-error" | "model-error" | "mcp-error" | "exit" = "complete";
  private input = "";
  constructor() {
    super();
    this.stdin.on("data", (chunk) => {
      this.input += chunk.toString();
      while (this.input.includes("\n")) {
        const n = this.input.indexOf("\n");
        const line = this.input.slice(0, n); this.input = this.input.slice(n + 1);
        if (line) this.receive(JSON.parse(line));
      }
    });
    this.stdin.on("finish", () => { this.exitCode = 0; this.emit("exit", 0, null); });
  }
  send(value: Message) { this.stdout.write(`${JSON.stringify(value)}\n`); }
  private receive(message: Message) {
    this.received.push(message);
    this.writes.push(message);
    if (message.method === "initialize") {
      if (this.turnMode === "startup-error") this.send({ id: message.id, error: { code: -32000, message: "app-server startup failed" } });
      else this.send({ id: message.id, result: { userAgent: "test" } });
    }
    else if (message.method === "thread/start") {
      this.threadParams = message.params;
      if (this.turnMode === "mcp-error") this.send({ id: message.id, error: { code: -32603, message: "required MCP servers failed to initialize: frontbot" } });
      else {
        this.send({ id: message.id, result: { thread: { id: "thread-1" } } });
        this.send({ method: "thread/started", params: { thread: { id: "thread-1" } } });
      }
    } else if (message.method === "turn/start") {
      this.turnParams = message.params;
      if (this.turnMode === "auth-error") this.send({ id: message.id, error: { code: 401, message: "unauthorized: invalid_api_key" } });
      else if (this.turnMode === "model-error") this.send({ id: message.id, error: { code: -32602, message: "Unknown model" } });
      else {
        this.send({ id: message.id, result: { turn: { id: "turn-1" } } });
        this.send({ method: "turn/started", params: { threadId: "thread-1", turn: { id: "turn-1" } } });
        if (this.turnMode === "exit") {
          this.exitCode = 9; this.emit("exit", 9, null);
        } else if (this.turnMode === "complete" || this.turnMode === "no-usage" || this.turnMode === "turn-failure") {
          this.send({ method: "thread/status/changed", params: { threadId: "thread-1", status: { type: "active" } } });
          this.send({ method: "item/started", params: { item: { type: "mcpToolCall", tool: "memory_remember" } } });
          this.send({ method: "item/agentMessage/delta", params: { delta: "hola " } });
          this.send({ method: "item/agentMessage/delta", params: { delta: "mundo" } });
          if (this.turnMode === "complete") this.send({ method: "thread/tokenUsage/updated", params: { tokenUsage: { last: { inputTokens: 8, outputTokens: 3 } } } });
          this.send({ method: "turn/completed", params: { turn: this.turnMode === "turn-failure" ? { status: "failed", error: { message: "response rejected" } } : { status: "completed" } } });
        }
      }
    } else if (message.method === "turn/interrupt") {
      this.send({ id: message.id, result: {} });
    } else if (message.method === "thread/unsubscribe") this.send({ id: message.id, result: { status: "notLoaded" } });
  }
  kill() { this.killed = true; this.exitCode = 0; this.emit("exit", 0, null); return true; }
}

const base: RunParams & { frontbot_mcp: { socketPath: string; token: string } } = {
  run_id: "run-1", prompt: "hola", model: "gpt-6-astra", provider: "codex",
  agent: { id: "a1", name: "Analista", instructions: "Sé prudente.", is_default: false },
  history: [{ role: "user", text: "buenos días" }, { role: "agent", text: "hola" }],
  frontbot_mcp: { socketPath: "/tmp/frontbot-mcp/bridge.sock", token: "secret-bridge-token" },
};

function createHarness(mode: FakeChild["turnMode"] = "complete", apiKey = "secret-openai-key") {
  const child = new FakeChild(); child.turnMode = mode;
  let spawnCall: { command: string; args: string[]; options: any } | undefined;
  const runner = new CodexRunner({ executable: "/test/codex", apiKey }, {
    spawn: (command, args, options) => { spawnCall = { command, args, options }; return child as any; },
    mcpEntrypoint: "/agent/dist/frontbot-mcp.js", cancelGraceMs: 20, requestTimeoutMs: 100,
  });
  return { runner, child, get spawnCall() { return spawnCall; } };
}

describe("CodexRunner", () => {
  it("starts an ephemeral read-only thread, configures Frontbot MCP, streams ordered events and reports available usage", async () => {
    const h = createHarness(); const events: any[] = [];
    const done = await h.runner.run(base, (event) => events.push(event), new AbortController().signal);
    expect(done).toMatchObject({ run_id: "run-1", ok: true, summary: "hola mundo", input_tokens: 8, output_tokens: 3, cost_usd: 0 });
    expect(events).toEqual([
      { run_id: "run-1", type: "status", text: "Conectando con Codex…" },
      { run_id: "run-1", type: "status", text: "Codex está trabajando…" },
      { run_id: "run-1", type: "tool_call", text: "memory_remember" },
      { run_id: "run-1", type: "text", text: "hola " },
      { run_id: "run-1", type: "text", text: "mundo" },
    ]);
    expect(h.child.threadParams).toMatchObject({ model: base.model, modelProvider: "openai", approvalPolicy: "untrusted", sandbox: "read-only", ephemeral: true, historyMode: "legacy", runtimeWorkspaceRoots: [expect.any(String)] });
    expect(h.child.writes.map((message) => message.method).slice(0, 4)).toEqual(["initialize", "initialized", "thread/start", "turn/start"]);
    const mcp = h.child.threadParams.config.mcp_servers.frontbot;
    expect(mcp).toEqual({ command: process.execPath, args: ["/agent/dist/frontbot-mcp.js"], env: { FRONTBOT_MCP_SOCKET: base.frontbot_mcp.socketPath, FRONTBOT_MCP_TOKEN: base.frontbot_mcp.token }, enabled: true, required: true });
    expect(h.child.turnParams).toMatchObject({ threadId: "thread-1", input: [{ type: "text", text: expect.stringContaining("Conversación hasta ahora:") }], sandboxPolicy: { type: "readOnly", networkAccess: false }, approvalPolicy: "untrusted" });
    expect(h.spawnCall?.options.env).toMatchObject({ OPENAI_API_KEY: "secret-openai-key" });
    expect(JSON.stringify(h.spawnCall?.args)).not.toContain("secret-openai-key");
    expect(JSON.stringify(h.spawnCall?.options.env)).not.toContain("secret-bridge-token");
    expect(h.child.writes.at(-1)?.method).toBe("thread/unsubscribe");
  });

  it("fails closed when workdir cannot be represented with equivalent restrictions", async () => {
    const h = createHarness();
    const done = await h.runner.run({ ...base, workdir: { path: "/project", read_dirs: [] } }, () => {}, new AbortController().signal);
    expect(done.error).toContain("carpeta de trabajo todavía no está disponible");
    expect(h.spawnCall).toBeUndefined();
  });

  it("requires the per-run MCP bridge and maps MCP startup failures", async () => {
    const h = createHarness();
    expect((await h.runner.run({ ...base, frontbot_mcp: undefined } as any, () => {}, new AbortController().signal)).error).toContain("herramienta MCP");
    const failed = createHarness("mcp-error");
    expect((await failed.runner.run(base, () => {}, new AbortController().signal)).error).toContain("herramienta MCP");
  });

  it("maps auth and model errors to safe guidance and redacts configured secrets", async () => {
    const auth = createHarness("auth-error", "private-key");
    const authDone = await auth.runner.run(base, () => {}, new AbortController().signal);
    expect(authDone.error).toContain("Inicia sesión en Codex CLI");
    expect(authDone.error).not.toContain("private-key");
    const model = createHarness("model-error");
    expect((await model.runner.run(base, () => {}, new AbortController().signal)).error).toContain("Codex no reconoce el modelo");
  });

  it("maps app-server startup and turn failure, and leaves missing usage unavailable as zero counts", async () => {
    const startup = createHarness("startup-error");
    expect((await startup.runner.run(base, () => {}, new AbortController().signal)).error).toContain("app-server startup failed");
    const failedTurn = createHarness("turn-failure");
    expect((await failedTurn.runner.run(base, () => {}, new AbortController().signal)).error).toBe("response rejected");
    const noUsage = createHarness("no-usage");
    expect(await noUsage.runner.run(base, () => {}, new AbortController().signal)).toMatchObject({ ok: true, input_tokens: 0, output_tokens: 0 });
  });

  it("interrupts on cancel, resolves once, and cleans up even when completion races", async () => {
    const h = createHarness("hang"); const controller = new AbortController(); const doneSpy = vi.fn();
    const run = h.runner.run(base, () => {}, controller.signal).then((result) => { doneSpy(); return result; });
    await new Promise((resolve) => setTimeout(resolve, 5));
    controller.abort();
    h.child.send({ method: "turn/completed", params: { turn: { status: "completed" } } });
    const done = await run;
    expect(done.error).toBe("Cancelado");
    expect(doneSpy).toHaveBeenCalledTimes(1);
    expect(h.child.writes.some((message) => message.method === "turn/interrupt" && message.params.threadId === "thread-1")).toBe(true);
    expect(h.child.writes.at(-1)?.method).toBe("thread/unsubscribe");
  });

  it("denies native command and filesystem permission requests", async () => {
    const h = createHarness("hang"); const controller = new AbortController(); const events: any[] = [];
    const run = h.runner.run(base, (event) => events.push(event), controller.signal);
    await until(() => Boolean(h.child.turnParams));
    h.child.send({ id: "approval-1", method: "item/commandExecution/requestApproval", params: { command: "cat ~/.ssh/id_rsa" } });
    h.child.send({ id: "approval-2", method: "item/fileChange/requestApproval", params: {} });
    await until(() => h.child.received.filter((m) => m.id === "approval-1" || m.id === "approval-2").length === 2);
    expect(h.child.received.filter((m) => m.id === "approval-1" || m.id === "approval-2")).toEqual([
      { id: "approval-1", result: { decision: "decline" } },
      { id: "approval-2", result: { decision: "decline" } },
    ]);
    expect(events.filter((event) => event.type === "status" && event.text.includes("la denegó"))).toHaveLength(2);
    controller.abort();
    await run;
  });

  it("handles child process exit during a turn and runs without invented usage", async () => {
    const h = createHarness("exit");
    const done = await h.runner.run(base, () => {}, new AbortController().signal);
    expect(done.ok).toBe(false);
    expect(done.input_tokens).toBe(0);
    expect(done.output_tokens).toBe(0);
  });

  it("does not spawn when already cancelled", async () => {
    const h = createHarness(); const controller = new AbortController(); controller.abort();
    expect((await h.runner.run(base, () => {}, controller.signal)).error).toBe("Cancelado");
    expect(h.spawnCall).toBeUndefined();
  });
});

async function until(condition: () => boolean, timeoutMs = 300) {
  const end = Date.now() + timeoutMs;
  while (!condition() && Date.now() < end) await new Promise((resolve) => setTimeout(resolve, 1));
  if (!condition()) throw new Error("Timed out waiting for the fake app-server state.");
}

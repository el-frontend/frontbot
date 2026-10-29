import { describe, expect, it, vi } from "vitest";
import { CodexRunner } from "../src/codex-runner.js";
import type { OpenAIResponseEvent, OpenAIResponsesRequest, OpenAIResponsesResult } from "../src/openai-responses.js";
import type { RunParams, RunnerContext } from "../src/runner.js";

const base: RunParams = {
  run_id: "run-1", prompt: "hola", model: "gpt-6-astra", provider: "codex",
  agent: { id: "a1", name: "Redactor", instructions: "Escribe claro.", is_default: false },
};

type Transport = (request: OpenAIResponsesRequest, options: { apiKey: string; signal?: AbortSignal }, onEvent?: (event: OpenAIResponseEvent) => void) => Promise<OpenAIResponsesResult>;

function completed(output: Record<string, unknown>[], input = 7, outputTokens = 3): OpenAIResponsesResult {
  return { response: { status: "completed", usage: { input_tokens: input, output_tokens: outputTokens }, output }, output: output as OpenAIResponsesResult["output"] };
}

function runner(transport: Transport, context: RunnerContext = { frontbot: { context: { isDefault: false }, execute: vi.fn() } }) {
  const api = new CodexRunner({ apiKey: "sk-test-key" }, transport);
  return {
    run: (params: RunParams, emit: (event: any) => void, signal: AbortSignal) => api.run(params, emit, signal, context),
  };
}

describe("CodexRunner Responses API", () => {
  it("streams a text-only response through the Frontbot event contract and reports API tokens", async () => {
    const requests: OpenAIResponsesRequest[] = [];
    const events: unknown[] = [];
    const transport: Transport = async (request, _options, onEvent) => {
      requests.push(request);
      onEvent?.({ type: "text_delta", delta: "Hola" });
      onEvent?.({ type: "text_delta", delta: " mundo" });
      return completed([{ type: "message", content: [{ type: "output_text", text: "Hola mundo" }] }]);
    };

    const done = await runner(transport).run(base, (event) => events.push(event), new AbortController().signal);

    expect(done).toEqual({ run_id: "run-1", ok: true, summary: "Hola mundo", input_tokens: 7, output_tokens: 3, cost_usd: null });
    expect(events).toEqual([
      { run_id: "run-1", type: "status", text: "pensando" },
      { run_id: "run-1", type: "text", text: "Hola" },
      { run_id: "run-1", type: "text", text: " mundo" },
    ]);
    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({ model: "gpt-6-astra", input: "hola" });
    expect(requests[0].instructions).toContain("Escribe claro.");
    expect(requests[0].instructions).not.toContain("WebSearch");
    expect(requests[0].instructions).not.toContain("WebFetch");
    expect(requests[0].tools?.map((tool) => tool.name)).toContain("brands_list");
  });

  it("replays every completed output item in order before correlated tool results", async () => {
    const requests: OpenAIResponsesRequest[] = [];
    const execute = vi.fn().mockResolvedValue({ content: [{ type: "text", text: "{\"brands\":[]}" }] });
    const prior = [
      { type: "reasoning", id: "rs_1", encrypted_content: "opaque" },
      { type: "function_call", id: "fc_1", call_id: "call_1", name: "brands_list", arguments: "{}" },
    ];
    const transport: Transport = async (request) => {
      requests.push(request);
      return requests.length === 1
        ? completed(prior)
        : completed([{ type: "message", content: [{ type: "output_text", text: "No hay marcas." }] }], 2, 1);
    };

    const done = await runner(transport, { frontbot: { context: { isDefault: false }, execute } }).run(base, () => {}, new AbortController().signal);

    expect(done).toMatchObject({ ok: true, summary: "No hay marcas.", input_tokens: 9, output_tokens: 4, cost_usd: null });
    expect(execute).toHaveBeenCalledOnce();
    expect(execute).toHaveBeenCalledWith("brands_list", {});
    expect(requests[1].input).toEqual([
      ...prior,
      { type: "function_call_output", call_id: "call_1", output: "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"brands\\\":[]}\"}]}" },
    ]);
  });

  it("executes multiple complete calls once each before continuing", async () => {
    const execute = vi.fn(async (name: string, args: Record<string, unknown>) => ({ content: [{ type: "text", text: `${name}:${args.title ?? ""}` }] }));
    let round = 0;
    const transport: Transport = async () => {
      round += 1;
      return round === 1
        ? completed([
          { type: "function_call", call_id: "a", name: "brands_list", arguments: "{}" },
          { type: "function_call", call_id: "b", name: "tasks_create", arguments: "{\"title\":\"Pagar\"}" },
        ])
        : completed([{ type: "message", content: [{ type: "output_text", text: "Listo" }] }]);
    };

    await expect(runner(transport, { frontbot: { context: { isDefault: false }, execute } }).run(base, () => {}, new AbortController().signal))
      .resolves.toMatchObject({ ok: true, summary: "Listo" });
    expect(execute.mock.calls).toEqual([["brands_list", {}], ["tasks_create", { title: "Pagar" }]]);
  });

  it.each([
    ["malformed arguments", { type: "function_call", call_id: "call_1", name: "brands_list", arguments: "{" }, "argumentos"],
    ["unknown tool", { type: "function_call", call_id: "call_1", name: "shell_exec", arguments: "{}" }, "permitida"],
  ])("rejects %s without invoking Frontbot", async (_name, call, expected) => {
    const execute = vi.fn();
    const done = await runner(async () => completed([call]), { frontbot: { context: { isDefault: false }, execute } })
      .run(base, () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: false, error: expect.stringContaining(expected) });
    expect(execute).not.toHaveBeenCalled();
  });

  it("stops after a bounded number of tool rounds", async () => {
    const execute = vi.fn().mockResolvedValue({ content: [{ type: "text", text: "ok" }] });
    const transport: Transport = async () => completed([{ type: "function_call", call_id: crypto.randomUUID(), name: "brands_list", arguments: "{}" }]);
    const done = await runner(transport, { frontbot: { context: { isDefault: false }, execute } }).run(base, () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: false, error: expect.stringContaining("límite") });
    expect(execute.mock.calls.length).toBeGreaterThan(0);
    expect(execute.mock.calls.length).toBeLessThan(10);
  });

  it("rejects study and workdir runs before contacting OpenAI", async () => {
    const transport = vi.fn<Transport>();
    const api = runner(transport);
    await expect(api.run({ ...base, mode: "study", study: { topic_id: "t", session_id: "s", budget_tokens: 1 } }, () => {}, new AbortController().signal))
      .resolves.toMatchObject({ ok: false, error: expect.stringContaining("estudio") });
    await expect(api.run({ ...base, workdir: { path: "/tmp/project", read_dirs: [] } }, () => {}, new AbortController().signal))
      .resolves.toMatchObject({ ok: false, error: expect.stringContaining("carpeta de trabajo") });
    expect(transport).not.toHaveBeenCalled();
  });

  it("requires a terminal completed response before declaring success", async () => {
    const result = completed([{ type: "message", content: [{ type: "output_text", text: "prematuro" }] }]);
    result.response.status = "in_progress";
    await expect(runner(async () => result).run(base, () => {}, new AbortController().signal))
      .resolves.toMatchObject({ ok: false, error: expect.stringContaining("completó") });
  });

  it("fails safely when the API key is missing or the transport fails", async () => {
    const calls = vi.fn<Transport>();
    const noKey = new CodexRunner({ transport: calls } as never);
    await expect(noKey.run(base, () => {}, new AbortController().signal)).resolves.toMatchObject({ ok: false, error: expect.stringContaining("clave") });
    await expect(runner(async () => { throw new Error("request failed sk-test-key Bearer sk-test-key"); }).run(base, () => {}, new AbortController().signal))
      .resolves.toMatchObject({ ok: false, error: expect.not.stringContaining("sk-test-key") });
    expect(calls).not.toHaveBeenCalled();
  });

  it("returns cancellation without dispatching a completed tool call", async () => {
    const controller = new AbortController();
    const execute = vi.fn();
    const transport: Transport = async () => {
      controller.abort();
      return completed([{ type: "function_call", call_id: "call_1", name: "brands_list", arguments: "{}" }]);
    };
    const done = await runner(transport, { frontbot: { context: { isDefault: false }, execute } }).run(base, () => {}, controller.signal);
    expect(done).toMatchObject({ ok: false, error: "Cancelado" });
    expect(execute).not.toHaveBeenCalled();
  });

  it("cancels an active Responses request through its AbortSignal", async () => {
    const controller = new AbortController();
    const transport: Transport = async (_request, options) => new Promise((_resolve, reject) => {
      options.signal?.addEventListener("abort", () => reject(new Error("network still waiting")), { once: true });
    });
    const running = runner(transport).run(base, () => {}, controller.signal);
    controller.abort();
    await expect(running).resolves.toMatchObject({ ok: false, error: "Cancelado" });
  });
});

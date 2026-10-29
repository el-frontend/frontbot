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
    expect(requests[0]).toMatchObject({ model: "gpt-6-astra", input: [{ role: "user", content: "hola" }] });
    expect(requests[0].instructions).toContain("Escribe claro.");
    expect(requests[0].instructions).not.toContain("WebSearch");
    expect(requests[0].instructions).not.toContain("WebFetch");
    expect(requests[0].tools?.map((tool) => tool.name)).toContain("brands_list");
  });

  it("keeps the original user/history input and every completed output across tool rounds", async () => {
    const requests: OpenAIResponsesRequest[] = [];
    const execute = vi.fn()
      .mockResolvedValueOnce({ content: [{ type: "text", text: "{\"brands\":[]}" }] })
      .mockResolvedValueOnce({ content: [{ type: "text", text: "{\"id\":\"task_1\"}" }] });
    const first = [
      { type: "reasoning", id: "rs_1", encrypted_content: "opaque" },
      { type: "function_call", id: "fc_1", call_id: "call_1", name: "brands_list", arguments: "{}", status: "completed" },
    ];
    const second = [
      { type: "reasoning", id: "rs_2", encrypted_content: "opaque-2" },
      { type: "function_call", id: "fc_2", call_id: "call_2", name: "tasks_create", arguments: "{\"title\":\"Pagar\"}", status: "completed" },
    ];
    const transport: Transport = async (request) => {
      requests.push(request);
      return requests.length === 1
        ? completed(first)
        : requests.length === 2
          ? completed(second)
          : completed([{ type: "message", content: [{ type: "output_text", text: "No hay marcas." }] }], 2, 1);
    };

    const params = { ...base, prompt: "continúa", history: [{ role: "user" as const, text: "¿qué marcas hay?" }, { role: "agent" as const, text: "Una." }] };
    const done = await runner(transport, { frontbot: { context: { isDefault: false }, execute } }).run(params, () => {}, new AbortController().signal);

    expect(done).toMatchObject({ ok: true, summary: "No hay marcas.", input_tokens: 16, output_tokens: 7, cost_usd: null });
    expect(execute.mock.calls).toEqual([["brands_list", {}], ["tasks_create", { title: "Pagar" }]]);
    const user = { role: "user", content: "Conversación hasta ahora:\nUsuario: ¿qué marcas hay?\nRedactor: Una.\n\nMensaje nuevo del usuario:\ncontinúa" };
    const firstOutput = { type: "function_call_output", call_id: "call_1", output: "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"brands\\\":[]}\"}]}" };
    const secondOutput = { type: "function_call_output", call_id: "call_2", output: "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"id\\\":\\\"task_1\\\"}\"}]}" };
    expect(requests[0].input).toEqual([user]);
    expect(requests[1].input).toEqual([
      user, ...first, firstOutput,
    ]);
    expect(requests[2].input).toEqual([
      user, ...first, firstOutput, ...second, secondOutput,
    ]);
  });

  it("executes multiple complete calls once each before continuing", async () => {
    const execute = vi.fn(async (name: string, args: Record<string, unknown>) => ({ content: [{ type: "text", text: `${name}:${args.title ?? ""}` }] }));
    let round = 0;
    const transport: Transport = async () => {
      round += 1;
      return round === 1
        ? completed([
          { type: "function_call", call_id: "a", name: "brands_list", arguments: "{}", status: "completed" },
          { type: "function_call", call_id: "b", name: "tasks_create", arguments: "{\"title\":\"Pagar\"}", status: "completed" },
        ])
        : completed([{ type: "message", content: [{ type: "output_text", text: "Listo" }] }]);
    };

    await expect(runner(transport, { frontbot: { context: { isDefault: false }, execute } }).run(base, () => {}, new AbortController().signal))
      .resolves.toMatchObject({ ok: true, summary: "Listo" });
    expect(execute.mock.calls).toEqual([["brands_list", {}], ["tasks_create", { title: "Pagar" }]]);
  });

  it.each([
    ["malformed arguments", { type: "function_call", call_id: "call_1", name: "brands_list", arguments: "{", status: "completed" }, "argumentos"],
    ["unknown tool", { type: "function_call", call_id: "call_1", name: "shell_exec", arguments: "{}", status: "completed" }, "permitida"],
  ])("rejects %s without invoking Frontbot", async (_name, call, expected) => {
    const execute = vi.fn();
    const done = await runner(async () => completed([call]), { frontbot: { context: { isDefault: false }, execute } })
      .run(base, () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: false, error: expect.stringContaining(expected) });
    expect(execute).not.toHaveBeenCalled();
  });

  it("stops after a bounded number of tool rounds", async () => {
    const execute = vi.fn().mockResolvedValue({ content: [{ type: "text", text: "ok" }] });
    const transport: Transport = async () => completed([{ type: "function_call", call_id: crypto.randomUUID(), name: "brands_list", arguments: "{}", status: "completed" }]);
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

  it.each(["in_progress", undefined])("rejects a function call with %s status before executing it", async (status) => {
    const execute = vi.fn();
    const call: Record<string, unknown> = { type: "function_call", call_id: "call_1", name: "brands_list", arguments: "{}" };
    if (status) call.status = status;
    const done = await runner(async () => completed([call]), { frontbot: { context: { isDefault: false }, execute } })
      .run(base, () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: false, error: expect.stringContaining("completada") });
    expect(execute).not.toHaveBeenCalled();
  });

  it("reuses a duplicate call id result without repeating its Frontbot side effect", async () => {
    const requests: OpenAIResponsesRequest[] = [];
    const execute = vi.fn().mockResolvedValue({ content: [{ type: "text", text: "ok" }] });
    const call = { type: "function_call", call_id: "call_1", name: "brands_list", arguments: "{}", status: "completed" };
    const transport: Transport = async (request) => {
      requests.push(request);
      return requests.length < 3 ? completed([call]) : completed([{ type: "message", content: [{ type: "output_text", text: "Listo" }] }]);
    };
    await expect(runner(transport, { frontbot: { context: { isDefault: false }, execute } }).run(base, () => {}, new AbortController().signal))
      .resolves.toMatchObject({ ok: true, summary: "Listo" });
    expect(execute).toHaveBeenCalledOnce();
    expect(requests[2].input).toEqual(expect.arrayContaining([
      { type: "function_call_output", call_id: "call_1", output: "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}" },
    ]));
  });

  it("rejects a conflicting duplicate call id before any Frontbot side effect", async () => {
    const execute = vi.fn();
    const done = await runner(async () => completed([
      { type: "function_call", call_id: "call_1", name: "tasks_create", arguments: "{\"title\":\"Uno\"}", status: "completed" },
      { type: "function_call", call_id: "call_1", name: "tasks_create", arguments: "{\"title\":\"Dos\"}", status: "completed" },
    ]), { frontbot: { context: { isDefault: false }, execute } }).run(base, () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: false, error: expect.stringContaining("conflicto") });
    expect(execute).not.toHaveBeenCalled();
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
      return completed([{ type: "function_call", call_id: "call_1", name: "brands_list", arguments: "{}", status: "completed" }]);
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

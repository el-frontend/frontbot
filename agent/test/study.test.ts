import { describe, it, expect, vi, afterEach } from "vitest";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { countTokens, TokenMeter, buildStudyPrompt, studyAgents } from "../src/study.js";
import { buildQueryOptions, RealRunner, FakeRunner, type RunParams } from "../src/runner.js";
import { STUDY_TOOL_NAMES } from "../src/tools.js";

const study = { topic_id: "t1", session_id: "s1", question: "¿Funciona el RSI en BTC 4h?", why: "Decidir la estrategia", budget_tokens: 1000, allow_opus: false,
  notebook: { entries: [{ kind: "hypothesis", text: "RSI<30 rebota" }], model_notes: ["Haiku se quedó corto con el análisis"] } };
const agent = { id: "a1", name: "Cripto", instructions: "Sé riguroso.", is_default: false };
const params = (over: Partial<RunParams> = {}): RunParams => ({ run_id: "r", prompt: "estudiar", model: "m", mode: "study", study, agent, ...over });
const server = () => createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
// Como el SDK real: un frame por bloque, mismo message.id, stop_reason null y output_tokens creciente.
const frame = (id: string, input: number, output: number, over: Record<string, unknown> = {}) => ({ type: "assistant", parent_tool_use_id: null, message: { id, model: "claude-sonnet-5-5", stop_reason: null, content: [], usage: { input_tokens: input, output_tokens: output } }, ...over });
const asst = (tokens: number, id = `m${tokens}-${Math.random()}`) => frame(id, tokens, 0);
afterEach(() => { vi.useRealTimers(); });
const mk = (p = params()) => buildQueryOptions(p, server(), new AbortController(), "2026-10-17", undefined, new TokenMeter(p.study?.budget_tokens ?? 0));

describe("token meter", () => {
  it("countTokens weighs cache reads at 10%", () => {
    expect(countTokens({ input_tokens: 1000, output_tokens: 500, cache_creation_input_tokens: 200, cache_read_input_tokens: 10000 })).toBe(2700);
  });
  it("meter dedupes frames by message id, keeps latest usage and counts subagents", () => {
    const m = new TokenMeter(10000);
    m.consume(frame("a", 100, 5) as never);
    m.consume(frame("a", 100, 40) as never);
    m.consume(frame("a", 100, 80) as never);
    expect(m.total).toBe(180);
    m.consume(frame("b", 50, 10, { parent_tool_use_id: "tu1" }) as never);
    m.consume(frame("b", 50, 20, { parent_tool_use_id: "tu1" }) as never);
    expect(m.total).toBe(250);
    expect(m.byModel()).toEqual([{ model: "claude-sonnet-5-5", tokens: 250 }]);
  });
  it("result modelUsage reconciles totals per model without double counting", () => {
    const m = new TokenMeter(10000);
    m.consume(frame("a", 100, 80) as never);
    m.reconcile({ "claude-sonnet-5-5": { inputTokens: 1000, outputTokens: 500, cacheCreationInputTokens: 200, cacheReadInputTokens: 10000 }, "claude-haiku-4-5": { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 } });
    expect(m.total).toBe(2715);
    expect(m.byModel()).toEqual([{ model: "claude-sonnet-5-5", tokens: 2700 }, { model: "claude-haiku-4-5", tokens: 15 }]);
  });
  it("meter warns at 85% and exhausts at 100%", () => {
    const m = new TokenMeter(1000);
    m.add("x", { input_tokens: 849 });
    expect(m.warned).toBe(false);
    m.add("x", { input_tokens: 1 });
    expect(m.warned).toBe(true);
    expect(m.exhausted).toBe(false);
    m.add("y", { output_tokens: 150 });
    expect(m.exhausted).toBe(true);
    expect(m.byModel()).toEqual([{ model: "x", tokens: 850 }, { model: "y", tokens: 150 }]);
  });
});

describe("study prompt and options", () => {
  it("study prompt includes question, notebook and end-session rule", () => {
    const p = buildStudyPrompt(study, agent);
    for (const s of ["¿Funciona el RSI en BTC 4h?", "Decidir la estrategia", "RSI<30 rebota", "Haiku se quedó corto", "lab_end_session", "ayudante", "analista", "Nunca actúas sobre cuentas reales", "Nadie está mirando"]) expect(p).toContain(s);
  });
  it("study options use sonnet main thread and haiku/sonnet subagents", () => {
    const opts = mk();
    expect(opts.model).toBe("claude-sonnet-5-5");
    expect(opts.agents?.ayudante.model).toBe("haiku");
    expect(opts.agents?.analista.model).toBe("sonnet");
    expect(opts.agents?.experto).toBeUndefined();
    expect(opts.forwardSubagentText).toBe(true);
    expect(opts.maxTurns).toBe(60);
    const withOpus = mk(params({ study: { ...study, allow_opus: true } }));
    expect(withOpus.agents?.experto.model).toBe("opus");
    expect(withOpus.agents?.experto.description).toContain("solo una consulta por sesión");
  });
  it("subagent tools stay inside the study allowedTools", () => {
    const opts = mk(params({ study: { ...study, allow_opus: true } }));
    for (const a of Object.values(studyAgents(true))) for (const t of a.tools ?? []) expect(opts.allowedTools).toContain(t);
    expect(STUDY_TOOL_NAMES).toContain("lab_run");
  });
  it("warns once at 85% through a PostToolUse hook", async () => {
    const meter = new TokenMeter(1000);
    const opts = buildQueryOptions(params(), server(), new AbortController(), "2026-10-17", undefined, meter);
    const hook = opts.hooks!.PostToolUse![0].hooks[0];
    const call = () => hook({ hook_event_name: "PostToolUse" } as never, "u", { signal: new AbortController().signal });
    expect(await call()).toEqual({});
    meter.add("m", { input_tokens: 900 });
    expect(await call()).toMatchObject({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: expect.stringContaining("lab_end_session") } });
    expect(await call()).toEqual({});
  });
});

describe("runner", () => {
  it("runner cuts mid-run on streamed frames with growing output (no double counting)", async () => {
    let aborted = false;
    const fakeQuery = ((args: { options: { abortController: AbortController } }) => (async function* () {
      args.options.abortController.signal.addEventListener("abort", () => { aborted = true; });
      yield frame("a", 300, 10); yield frame("a", 300, 100); // 400, no 410; luego 550
      yield frame("s", 100, 50, { parent_tool_use_id: "tu" }); // 550
      yield frame("b", 300, 150); // 1000 -> agotado
      yield frame("c", 5000, 0); // no debe procesarse
    })()) as never;
    const done = await new RealRunner((async () => ({})) as never, fakeQuery).run(params(), () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: true, cut: true, lab_tokens: 1000, summary: "Sesión cortada por límite" });
    expect(aborted).toBe(true);
  });
  const blockUntilAbort = (signal: AbortSignal) => new Promise<void>((resolve) => signal.aborted ? resolve() : signal.addEventListener("abort", () => resolve(), { once: true }));
  it("wall clock cuts a stuck run; a result frame after the abort still reports cut", async () => {
    vi.useFakeTimers();
    const fakeQuery = ((args: { options: { abortController: AbortController } }) => (async function* () {
      yield frame("a", 100, 0);
      await blockUntilAbort(args.options.abortController.signal);
      yield { type: "result", subtype: "error_during_execution", is_error: true, result: "x", usage: {}, modelUsage: {} };
    })()) as never;
    const p = new RealRunner((async () => ({})) as never, fakeQuery).run(params(), () => {}, new AbortController().signal);
    await vi.advanceTimersByTimeAsync(20 * 60 * 1000 + 1);
    expect(await p).toMatchObject({ ok: true, cut: true, lab_tokens: 100 });
  });
  it("wall clock cut also covers a stream that throws on abort", async () => {
    vi.useFakeTimers();
    const fakeQuery = ((args: { options: { abortController: AbortController } }) => (async function* () {
      yield frame("a", 100, 0);
      await blockUntilAbort(args.options.abortController.signal);
      throw new Error("aborted");
    })()) as never;
    const p = new RealRunner((async () => ({})) as never, fakeQuery).run(params(), () => {}, new AbortController().signal);
    await vi.advanceTimersByTimeAsync(20 * 60 * 1000 + 1);
    expect(await p).toMatchObject({ ok: true, cut: true });
  });
  it("a user cancel is still a cancel, not a cut", async () => {
    const ac = new AbortController();
    const fakeQuery = ((args: { options: { abortController: AbortController } }) => (async function* () {
      yield frame("a", 100, 0);
      ac.abort();
      await blockUntilAbort(args.options.abortController.signal);
      throw new Error("aborted");
    })()) as never;
    expect(await new RealRunner((async () => ({})) as never, fakeQuery).run(params(), () => {}, ac.signal)).toMatchObject({ ok: false, error: "Cancelado" });
  });
  it("reports lab tokens on a normal finish", async () => {
    const fakeQuery = (() => (async function* () {
      yield asst(300);
      yield { type: "result", subtype: "success", is_error: false, result: "listo", usage: { input_tokens: 300, output_tokens: 0 }, total_cost_usd: 0.01 };
    })()) as never;
    const done = await new RealRunner((async () => ({})) as never, fakeQuery).run(params(), () => {}, new AbortController().signal);
    expect(done).toMatchObject({ ok: true, summary: "listo", lab_tokens: 300 });
    expect(done.cut).toBeUndefined();
  });
  it("clears the wall clock on a normal finish", async () => {
    vi.useFakeTimers();
    const fakeQuery = (() => (async function* () { yield { type: "result", subtype: "success", is_error: false, result: "ok", usage: {}, modelUsage: {} }; })()) as never;
    await new RealRunner((async () => ({})) as never, fakeQuery).run(params(), () => {}, new AbortController().signal);
    expect(vi.getTimerCount()).toBe(0);
  });
  it("FakeRunner study continues or pauses", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const fake = new FakeRunner((async (m: string, p: Record<string, unknown>) => { calls.push([m, p]); return {}; }) as never);
    const done = await fake.run(params(), () => {}, new AbortController().signal);
    expect(calls[0][0]).toBe("tool.lab_note");
    expect(calls[1]).toEqual(["tool.lab_end_session", expect.objectContaining({ outcome: "continue" })]);
    expect(done).toMatchObject({ ok: true, lab_tokens: 1234, models: [{ model: "claude-haiku-4-5-20251001", tokens: 1234 }] });
    calls.length = 0;
    await fake.run(params({ prompt: "estudiar y pausar" }), () => {}, new AbortController().signal);
    expect(calls[1][1]).toMatchObject({ outcome: "pause" });
  });
});

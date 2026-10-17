import { describe, it, expect } from "vitest";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { countTokens, TokenMeter, buildStudyPrompt, studyAgents } from "../src/study.js";
import { buildQueryOptions, RealRunner, FakeRunner, type RunParams } from "../src/runner.js";
import { STUDY_TOOL_NAMES } from "../src/tools.js";

const study = { topic_id: "t1", session_id: "s1", question: "¿Funciona el RSI en BTC 4h?", why: "Decidir la estrategia", budget_tokens: 1000, allow_opus: false,
  notebook: { entries: [{ kind: "hypothesis", text: "RSI<30 rebota" }], model_notes: ["Haiku se quedó corto con el análisis"] } };
const agent = { id: "a1", name: "Cripto", instructions: "Sé riguroso.", is_default: false };
const params = (over: Partial<RunParams> = {}): RunParams => ({ run_id: "r", prompt: "estudiar", model: "m", mode: "study", study, agent, ...over });
const server = () => createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
const asst = (tokens: number, over: Record<string, unknown> = {}) => ({ type: "assistant", parent_tool_use_id: null, message: { model: "claude-sonnet-5-5", stop_reason: "end_turn", content: [], usage: { input_tokens: tokens, output_tokens: 0 } }, ...over });

describe("token meter", () => {
  it("countTokens weighs cache reads at 10%", () => {
    expect(countTokens({ input_tokens: 1000, output_tokens: 500, cache_creation_input_tokens: 200, cache_read_input_tokens: 10000 })).toBe(2700);
  });
  it("meter ignores partial messages and counts subagents", () => {
    const m = new TokenMeter(1000);
    m.add("a", { input_tokens: 100 });
    expect(m.total).toBe(100);
    const meter = new TokenMeter(1000);
    meter.consume(asst(50, { parent_tool_use_id: "tu1" }) as never);
    meter.consume({ ...asst(900), message: { ...(asst(900).message), stop_reason: null } } as never);
    expect(meter.total).toBe(50);
    expect(meter.byModel()).toEqual([{ model: "claude-sonnet-5-5", tokens: 50 }]);
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
    const opts = buildQueryOptions(params(), server(), new AbortController(), "2026-10-17");
    expect(opts.model).toBe("claude-sonnet-5-5");
    expect(opts.agents?.ayudante.model).toBe("haiku");
    expect(opts.agents?.analista.model).toBe("sonnet");
    expect(opts.agents?.experto).toBeUndefined();
    expect(opts.forwardSubagentText).toBe(true);
    expect(opts.maxTurns).toBe(60);
    const withOpus = buildQueryOptions(params({ study: { ...study, allow_opus: true } }), server(), new AbortController(), "2026-10-17");
    expect(withOpus.agents?.experto.model).toBe("opus");
    expect(withOpus.agents?.experto.description).toContain("solo una consulta por sesión");
  });
  it("subagent tools stay inside the study allowedTools", () => {
    const opts = buildQueryOptions(params({ study: { ...study, allow_opus: true } }), server(), new AbortController(), "2026-10-17");
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
  it("runner cuts the session when budget is exhausted", async () => {
    let aborted = false;
    const fakeQuery = ((args: { options: { abortController: AbortController } }) => (async function* () {
      args.options.abortController.signal.addEventListener("abort", () => { aborted = true; });
      yield asst(600); yield asst(600);
      yield asst(600); // no debe procesarse
    })()) as never;
    const runner = new RealRunner((async () => ({})) as never, fakeQuery);
    const done = await runner.run(params(), () => {}, new AbortController().signal);
    expect(done.cut).toBe(true);
    expect(done.ok).toBe(true);
    expect(done.lab_tokens).toBe(1200);
    expect(done.models).toEqual([{ model: "claude-sonnet-5-5", tokens: 1200 }]);
    expect(done.summary).toBe("Sesión cortada por límite");
    expect(aborted).toBe(true);
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

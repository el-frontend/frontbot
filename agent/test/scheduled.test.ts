import { describe, it, expect } from "vitest";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { buildQueryOptions } from "../src/runner.js";
import { buildTools, allowedToolsFor, TOOL_SPECS } from "../src/tools.js";

const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
const agent = { id: "a1", name: "Crypto Trader", instructions: "x", is_default: false };

describe("scheduled runs", () => {
  it("tell the agent nobody is watching and expose notify_user", () => {
    const opts = buildQueryOptions({ run_id: "r9", prompt: "Revisa BTC", model: "m", agent, mode: "scheduled", task: { name: "Mercado 4h" } }, server, new AbortController(), "2026-10-17");
    expect(opts.systemPrompt).toContain("tarea programada");
    expect(opts.systemPrompt).toContain("Mercado 4h");
    expect(opts.systemPrompt).toContain("notify_user");
    expect(opts.allowedTools).toContain("mcp__frontbot__notify_user");
  });

  it("chat runs have no notify_user", () => {
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", agent }, server, new AbortController(), "2026-10-17");
    expect(opts.allowedTools).not.toContain("mcp__frontbot__notify_user");
  });

  it("notify_user carries the run id injected by the sidecar", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const tools = buildTools(async (m, p) => { calls.push([m, p as Record<string, unknown>]); return { ok: true }; }, { agentId: "a1", isDefault: false, runId: "r9", scheduled: true });
    await tools.find((t) => t.name === "notify_user")!.handler({ title: "Setup en BTC", message: "Long en 60k", run_id: "otro" } as never, {});
    expect(calls[0]).toEqual(["tool.notify_user", { title: "Setup en BTC", message: "Long en 60k", run_id: "r9", agent_id: "a1" }]);
  });

  it("every agent can draft tasks but none can activate them", () => {
    const names = TOOL_SPECS.map((t) => t.name);
    expect(names).toEqual(expect.arrayContaining(["schedule_list", "schedule_create_draft", "schedule_update_draft"]));
    expect(allowedToolsFor({ agentId: "a", isDefault: false }).some((t) => /schedule_(activate|enable|pause|delete)/.test(t))).toBe(false);
  });

  it("scheduled runs cannot run skill scripts (nobody is there to approve them)", () => {
    const opts = buildQueryOptions({ run_id: "r9", prompt: "x", model: "m", agent, mode: "scheduled", task: { name: "t" } }, server, new AbortController(), "2026-10-17");
    expect(opts.allowedTools).not.toContain("mcp__frontbot__skills_run_script");
    expect(buildTools(async () => ({}), { agentId: "a1", isDefault: false, scheduled: true }).map((t) => t.name)).not.toContain("skills_run_script");
  });
});


import { describe, it, expect } from "vitest";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { buildQueryOptions } from "../src/runner.js";

describe("buildQueryOptions", () => {
  it("does not persist sessions to ~/.claude and keeps the tool lockdown", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-13");
    expect(opts.persistSession).toBe(false);
    expect(opts.tools).toEqual(["WebSearch", "WebFetch"]);
    expect(opts.permissionMode).toBe("dontAsk");
    expect(opts.settingSources).toEqual([]);
    expect(opts.strictMcpConfig).toBe(true);
    expect(opts.model).toBe("m");
  });

  it("leaves the user's browser off unless asked", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-13");
    expect(opts.extraArgs).toBeUndefined();
    expect(opts.allowedTools?.some((t) => t.includes("claude-in-chrome"))).toBe(false);
  });

  it("enables Claude in Chrome behind the guard when browser is on", async () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", browser: true }, server, new AbortController(), "2026-10-13");
    expect(opts.extraArgs).toEqual({ chrome: null });
    expect(opts.allowedTools).toContain("mcp__claude-in-chrome__computer");
    expect(opts.allowedTools).not.toContain("mcp__claude-in-chrome__javascript_tool");
    expect(opts.systemPrompt).toContain("Chrome");
    const pre = opts.hooks?.PreToolUse?.[0].hooks[0];
    const out = await pre!({ hook_event_name: "PreToolUse", tool_name: "mcp__claude-in-chrome__javascript_tool", tool_input: {}, tool_use_id: "u", session_id: "s", transcript_path: "", cwd: "" } as never, "u", { signal: new AbortController().signal });
    expect(out).toMatchObject({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny" } });
  });
});

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
});

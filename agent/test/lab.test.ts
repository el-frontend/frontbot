import { describe, it, expect } from "vitest";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { allowedToolsFor, buildTools, STUDY_TOOL_NAMES } from "../src/tools.js";
import { buildMarketTools, type Market, type Network } from "../src/trading.js";
import { buildQueryOptions, toolContext, type RunParams } from "../src/runner.js";

const study = { topic_id: "t1", session_id: "s1", question: "q", why: "w", budget_tokens: 100000, allow_opus: false, notebook: [] };
const agent = { id: "a1", name: "Ana", instructions: "x", is_default: false };
const trading = { network: "testnet" as const, address: "0xabc", mandate: { mode: "auto", max_risk_pct: 1, max_leverage: 3, coins: ["BTC"], max_trades_per_day: 3 } };
const params = (extra: Partial<RunParams> = {}): RunParams => ({ run_id: "r1", prompt: "p", model: "m", agent, mode: "study", study, ...extra });
const server = createSdkMcpServer({ name: "frontbot", version: "0", tools: [] });
const pre = (n: string) => `mcp__frontbot__${n}`;

const FORBIDDEN = ["trade_propose", "account_state", "files_folders", "files_list", "files_read", "files_write", "skills_run_script", "skills_create_draft", "skills_update_draft",
  "schedule_list", "schedule_create_draft", "schedule_update_draft", "agents_create_draft", "notify_user", "posts_create_draft", "posts_update_draft", "brands_write_guide",
  "tasks_create", "tasks_complete", "ideas_create"];

describe("study mode tools", () => {
  it("study mode exposes exactly the study tools", () => {
    const expected = ["brands_list", "brands_get_guide", "brands_list_assets", "posts_list", "tasks_list", "skills_list", "memory_list", "memory_remember",
      "lab_open_topic", "lab_list_topics", "lab_resume_topic", "lab_note", "lab_read_notebook", "lab_write_file", "lab_read_file", "lab_list_files", "lab_run",
      "lab_list_datasets", "lab_fetch_dataset", "lab_end_session", "lab_propose_skill"].map(pre);
    const got = allowedToolsFor(toolContext(params())).filter((t) => t.startsWith("mcp__"));
    expect([...got].sort()).toEqual([...expected].sort());
    expect([...STUDY_TOOL_NAMES].sort()).toEqual(expected.map((t) => t.replace("mcp__frontbot__", "")).sort());
    expect(new Set(got).size).toBe(got.length);
  });

  it("study mode never exposes money or publishing tools", () => {
    const hostile = params({ browser: true, trading, folders: ["/tmp/x"], skills: [{ name: "s", description: "d", body: "b", files: {} } as never] });
    const lists = [allowedToolsFor(toolContext(hostile)), buildQueryOptions(hostile, server, new AbortController(), "2026-10-17").allowedTools ?? []];
    for (const list of lists) {
      for (const name of FORBIDDEN) expect(list).not.toContain(pre(name));
      expect(list.some((t) => /chrome|Read|Bash|Write|Edit|Skill/.test(t))).toBe(false);
    }
    const opts = buildQueryOptions(hostile, server, new AbortController(), "2026-10-17");
    expect(opts.tools).toEqual(["WebSearch", "WebFetch", "Agent"]);
    expect(opts.allowedTools).toContain("Agent");
    expect(opts.allowedTools).toContain(pre("market_price"));
    expect(opts.extraArgs).toBeUndefined();
    expect(opts.plugins).toBeUndefined();
  });

  it("study market tools read mainnet", async () => {
    const seen: Network[] = [];
    const market: Market = {
      marketPrice: async (n) => { seen.push(n); return 1; }, candles: async (n) => { seen.push(n); return []; },
      funding: async (n) => { seen.push(n); return {}; }, book: async (n) => { seen.push(n); return {}; },
      accountState: async () => ({ account_value: 0 }),
    };
    const tools = buildMarketTools(market, "mainnet");
    expect(tools.map((t) => t.name)).toEqual(["market_price", "market_candles", "market_funding", "market_book"]);
    await tools[0].handler({ coin: "BTC" }, {});
    await tools[1].handler({ coin: "BTC", interval: "1h", count: 5 }, {});
    await tools[2].handler({ coin: "BTC" }, {});
    await tools[3].handler({ coin: "BTC" }, {});
    expect(seen).toEqual(["mainnet", "mainnet", "mainnet", "mainnet"]);
  });

  it("lab tools inject topic and session ids", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const tools = buildTools(async (m, p) => { calls.push([m, p]); return {}; }, toolContext(params()));
    await tools.find((t) => t.name === "lab_note")!.handler({ kind: "note", text: "hola", topic_id: "evil", session_id: "evil" }, {});
    expect(calls[0]).toEqual(["tool.lab_note", { kind: "note", text: "hola", agent_id: "a1", topic_id: "t1", session_id: "s1" }]);
    await tools.find((t) => t.name === "lab_read_notebook")!.handler({ topic_id: "t9" }, {});
    expect(calls[1][1].topic_id).toBe("t9");
  });

  it("chat mode gets lab_open_topic but not lab_run", () => {
    const chat = allowedToolsFor(toolContext({ run_id: "r", prompt: "p", model: "m", agent }));
    expect(chat).toContain(pre("lab_open_topic"));
    expect(chat).toContain(pre("lab_list_datasets"));
    expect(chat).not.toContain(pre("lab_run"));
    expect(chat).not.toContain(pre("lab_note"));
    expect(allowedToolsFor(toolContext({ run_id: "r", prompt: "p", model: "m", agent, mode: "summarize" })).some((t) => t.includes("lab_"))).toBe(false);
  });
});

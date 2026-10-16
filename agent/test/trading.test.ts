import { describe, it, expect } from "vitest";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { buildTradingTools, TRADING_TOOL_NAMES, type Market } from "../src/trading.js";
import { buildQueryOptions } from "../src/runner.js";
import { buildSystemPrompt } from "../src/prompt.js";
import { BrowserGuard } from "../src/browserGuard.js";

const market: Market = {
  marketPrice: async () => 60_000,
  candles: async () => [{ t: "x", o: 1, h: 2, l: 0.5, c: 1.5, v: 10 }],
  funding: async (_n, coin) => ({ coin }),
  book: async () => ({ bids: [], asks: [] }),
  accountState: async () => ({ account_value: 1_000, withdrawable: 900, positions: [] }),
};

const trading = { network: "testnet" as const, address: "0xabc", mandate: { mode: "approval", max_risk_pct: 1, max_leverage: 3, coins: ["BTC"], max_trades_per_day: 3 } };

describe("trading tools", () => {
  it("read tools hit the market directly", async () => {
    const tools = buildTradingTools(async () => ({}), { agentId: "a1", trading }, market);
    const price = await tools.find((t) => t.name === "market_price")!.handler({ coin: "btc" }, {});
    expect(JSON.parse(price.content[0].text as string)).toEqual({ coin: "BTC", price: 60_000, network: "testnet" });
    const acct = await tools.find((t) => t.name === "account_state")!.handler({}, {});
    expect(JSON.parse(acct.content[0].text as string).account_value).toBe(1_000);
  });

  it("account_state explains how to connect when there is no address", async () => {
    const tools = buildTradingTools(async () => ({}), { agentId: "a1", trading: { ...trading, address: undefined } }, market);
    const res = await tools.find((t) => t.name === "account_state")!.handler({}, {});
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain("conecte");
  });

  it("trade_propose goes to the app with the agent id and a market snapshot the model cannot fake", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const tools = buildTradingTools(async (m, p) => { calls.push([m, p]); return { status: "proposed" }; }, { agentId: "a1", trading }, market);
    await tools.find((t) => t.name === "trade_propose")!.handler(
      { coin: "BTC", side: "long", size_usd: 500, leverage: 3, entry_type: "market", stop_loss: 58_800, rationale: "r", snapshot: { price: 1 } } as never, {});
    expect(calls[0][0]).toBe("tool.trade_propose");
    expect(calls[0][1]).toMatchObject({ agent_id: "a1", coin: "BTC", snapshot: { price: 60_000, account_value: 1_000, network: "testnet" } });
  });

  it("only agents with trading get the tools and the trading prompt", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const agent = { id: "a1", name: "Crypto Trader", instructions: "x", is_default: false };
    const on = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", agent, trading }, server, new AbortController(), "2026-10-16");
    const off = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", agent }, server, new AbortController(), "2026-10-16");
    for (const name of TRADING_TOOL_NAMES) {
      expect(on.allowedTools).toContain(`mcp__frontbot__${name}`);
      expect(off.allowedTools).not.toContain(`mcp__frontbot__${name}`);
    }
    expect(on.systemPrompt).toContain("trade_propose");
  });
});

describe("trading prompt", () => {
  it("shows the mandate and warns loudly on mainnet", () => {
    const p = buildSystemPrompt({ today: "2026-10-16", trading: { ...trading, network: "mainnet" } });
    expect(p).toContain("MAINNET");
    expect(p).toContain("1%");
    expect(p).toContain("stop loss");
  });
});

describe("guard: exchanges and wallets", () => {
  it("blocks clicks while an exchange or a wallet extension is open, allows TradingView", () => {
    const click = { action: "left_click", coordinate: [1, 1] };
    const after = (text: string) => { const g = new BrowserGuard(); g.afterTool("mcp__claude-in-chrome__tabs_context_mcp", { content: [{ type: "text", text }] }); return g; };
    expect(after("https://app.hyperliquid.xyz/trade").beforeTool("mcp__claude-in-chrome__computer", click).allow).toBe(false);
    expect(after("chrome-extension://bfnaelmomeimhlpmgjnjophhpkkoljpa/popup.html").beforeTool("mcp__claude-in-chrome__computer", click).allow).toBe(false);
    expect(after("https://www.binance.com/en/futures").beforeTool("mcp__claude-in-chrome__computer", click).allow).toBe(false);
    expect(after("https://www.tradingview.com/chart/abc/").beforeTool("mcp__claude-in-chrome__computer", click).allow).toBe(true);
  });
});

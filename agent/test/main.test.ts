import { describe, it, expect, vi } from "vitest";
import { PassThrough } from "node:stream";
import { RpcPeer } from "../src/rpc.js";
import { startServer } from "../src/main.js";
import { FakeRunner, ProviderRunner } from "../src/runner.js";
import { realMarket } from "../src/trading.js";

function setup() {
  const appToAgent = new PassThrough();
  const agentToApp = new PassThrough();
  const app = new RpcPeer(agentToApp, appToAgent);
  const agent = new RpcPeer(appToAgent, agentToApp);
  const fake = () => new FakeRunner((m, p) => agent.request(m, p));
  startServer(agent, new ProviderRunner(fake(), fake()));
  return app;
}

describe("agent server with FakeRunner", () => {
  it("runs, calls back the app, streams events and finishes", async () => {
    const app = setup();
    const calls: string[] = [];
    app.onRequest("tool.brands_list", async () => { calls.push("brands_list"); return { brands: [{ id: "b1" }] }; });
    app.onRequest("tool.posts_create_draft", async (p) => { calls.push(`create:${p.brand_id}`); return { post_id: "p1" }; });
    const events: any[] = [];
    app.onNotification("agent.event", (e) => events.push(e));
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));

    await expect(app.request("agent.run", { run_id: "r1", prompt: "crear post", model: "m", brand: { id: "b1", name: "B", guide: null } }))
      .resolves.toEqual({ accepted: true });
    const result = await done;

    expect(calls).toEqual(["brands_list", "create:b1"]);
    expect(events.map((e) => e.type)).toEqual(["status", "text", "tool_call"]);
    expect(result).toMatchObject({ run_id: "r1", ok: true, summary: "Tienes 1 marca(s)." });
  });

  it("routes provider runs while retaining the same event and done notifications", async () => {
    const app = setup();
    const events: any[] = [];
    app.onNotification("agent.event", (event) => events.push(event));
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));

    await expect(app.request("agent.run", { run_id: "codex-run", prompt: "provider", provider: "codex", model: "gpt-6-astra", agent: { id: "a", name: "A", instructions: "x", is_default: false } }))
      .resolves.toEqual({ accepted: true });
    await expect(done).resolves.toMatchObject({ run_id: "codex-run", ok: true, summary: "codex", input_tokens: 0, output_tokens: 0, cost_usd: 0 });
    expect(events).toEqual([
      { run_id: "codex-run", type: "text", text: "codex" },
      { run_id: "codex-run", type: "text", text: "Modelo: gpt-6-astra" },
    ]);
  });

  it("gives Codex a run-scoped Frontbot callback with its trusted trading snapshot", async () => {
    vi.spyOn(realMarket, "marketPrice").mockResolvedValue(60_000);
    vi.spyOn(realMarket, "accountState").mockResolvedValue({ account_value: 1_000 });
    const appToAgent = new PassThrough();
    const agentToApp = new PassThrough();
    const app = new RpcPeer(agentToApp, appToAgent);
    const agent = new RpcPeer(appToAgent, agentToApp);
    let routedParams: any;
    let context: any;
    let proposals = 0;
    const runner = {
      async run(params: any, _emit: any, _signal: any, runContext: any) {
        routedParams = params;
        context = runContext;
        const args = {
          coin: "btc", side: "long", size_usd: 10, leverage: 2, entry_type: "market", stop_loss: 1, rationale: "test",
        };
        const [result] = await Promise.all([runContext.frontbot.execute("trade_propose", args), runContext.frontbot.execute("trade_propose", args)]);
        return { run_id: params.run_id, ok: true, summary: JSON.stringify(result), input_tokens: 0, output_tokens: 0, cost_usd: 0 };
      },
    };
    app.onRequest("tool.trade_propose", async (params) => { proposals++; return params; });
    startServer(agent, runner);
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await expect(app.request("agent.run", {
      run_id: "codex-direct-run", provider: "codex", prompt: "propose trade", model: "gpt-6-astra",
      agent: { id: "agent-1", name: "A", instructions: "", is_default: false },
      trading: { network: "testnet", address: "0x0000000000000000000000000000000000000000" },
    })).resolves.toEqual({ accepted: true });
    const result = await done;
    expect(result).toMatchObject({ run_id: "codex-direct-run", ok: true });
    expect(JSON.parse(result.summary)).toEqual({ content: [{ type: "text", text: expect.stringContaining('"network":"testnet"') }] });
    expect(routedParams).not.toHaveProperty("frontbot_mcp");
    expect(context.frontbot.context).toMatchObject({ agentId: "agent-1", isDefault: false, trading: { network: "testnet" } });
    expect(proposals).toBe(1);
    vi.restoreAllMocks();
  });

  it("does not start a private MCP bridge for Codex runs", async () => {
    const appToAgent = new PassThrough();
    const agentToApp = new PassThrough();
    const app = new RpcPeer(agentToApp, appToAgent);
    const agent = new RpcPeer(appToAgent, agentToApp);
    let receivedContext: any;
    startServer(agent, {
      async run(_params: any, _emit: any, _signal: any, context: any) {
        receivedContext = context;
        return { run_id: "failed-codex", ok: true, summary: "done", input_tokens: 0, output_tokens: 0, cost_usd: 0 };
      },
    });
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await app.request("agent.run", { run_id: "failed-codex", provider: "codex", prompt: "hola", model: "gpt-6-astra" });
    const result = await done;
    expect(result).toMatchObject({ ok: true, summary: "done" });
    expect(receivedContext.frontbot).toBeDefined();
    expect(JSON.stringify(receivedContext)).not.toContain("socketPath");
    expect(JSON.stringify(receivedContext)).not.toContain("token");
  });

  it("cancels a pending direct Frontbot tool call", async () => {
    const appToAgent = new PassThrough();
    const agentToApp = new PassThrough();
    const app = new RpcPeer(agentToApp, appToAgent);
    const agent = new RpcPeer(appToAgent, agentToApp);
    app.onRequest("tool.brands_list", () => new Promise(() => undefined));
    startServer(agent, {
      async run(params: any, _emit: any, _signal: any, context: any) {
        const result = await context.frontbot.execute("brands_list", {});
        return { run_id: params.run_id, ok: true, summary: result.content[0].text, input_tokens: 0, output_tokens: 0, cost_usd: 0 };
      },
    });
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await app.request("agent.run", { run_id: "cancel-tool", provider: "codex", prompt: "hola", model: "gpt-6-astra" });
    await app.request("agent.cancel", { run_id: "cancel-tool" });
    await expect(done).resolves.toMatchObject({ run_id: "cancel-tool", summary: "Cancelado" });
  });

  it("bounds a pending direct Frontbot tool call", async () => {
    const appToAgent = new PassThrough();
    const agentToApp = new PassThrough();
    const app = new RpcPeer(agentToApp, appToAgent);
    const agent = new RpcPeer(appToAgent, agentToApp);
    app.onRequest("tool.brands_list", () => new Promise(() => undefined));
    startServer(agent, {
      async run(params: any, _emit: any, _signal: any, context: any) {
        const result = await context.frontbot.execute("brands_list", {});
        return { run_id: params.run_id, ok: true, summary: result.content[0].text, input_tokens: 0, output_tokens: 0, cost_usd: 0 };
      },
    }, undefined, { appCallTimeoutMs: 10 });
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await app.request("agent.run", { run_id: "timeout-tool", provider: "codex", prompt: "hola", model: "gpt-6-astra" });
    await expect(done).resolves.toMatchObject({ run_id: "timeout-tool", summary: expect.stringContaining("superó el plazo") });
  });

  it("cancel that arrives before the runner starts waiting still cancels", async () => {
    const app = setup();
    let releaseBrands!: () => void;
    app.onRequest("tool.brands_list", () => new Promise((resolve) => { releaseBrands = () => resolve({ brands: [] }); }));
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await app.request("agent.run", { run_id: "r3", prompt: "lento", model: "m" });
    await app.request("agent.cancel", { run_id: "r3" }); // el runner aún espera brands_list
    releaseBrands();
    await expect(done).resolves.toMatchObject({ run_id: "r3", ok: false, error: "Cancelado" });
  });

  it("cancel stops a slow run with ok=false", async () => {
    const app = setup();
    app.onRequest("tool.brands_list", async () => ({ brands: [] }));
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await app.request("agent.run", { run_id: "r2", prompt: "lento", model: "m" });
    await app.request("agent.cancel", { run_id: "r2" });
    await expect(done).resolves.toMatchObject({ run_id: "r2", ok: false, error: "Cancelado" });
  });
});

import { FakeTrader } from "../src/trader.js";

describe("trade.* RPC (app → sidecar)", () => {
  function setupTrader() {
    const appToAgent = new PassThrough();
    const agentToApp = new PassThrough();
    const app = new RpcPeer(agentToApp, appToAgent);
    const agent = new RpcPeer(appToAgent, agentToApp);
    startServer(agent, new FakeRunner((m, p) => agent.request(m, p)), new FakeTrader());
    return app;
  }

  it("executes, snapshots and closes through the trader", async () => {
    const app = setupTrader();
    await expect(app.request("market.snapshot", { network: "testnet", coin: "BTC", address: "0x1" })).resolves.toEqual({ price: 60_000, account_value: 1_000 });
    await expect(app.request("trade.execute", { network: "testnet", private_key: "k", coin: "BTC", side: "long", size_usd: 500, leverage: 3, entry_type: "market", stop_loss: 58_800 }))
      .resolves.toMatchObject({ status: "open", filledSize: "0.00833" });
    await expect(app.request("trade.close", { network: "testnet", private_key: "k", address: "0x1", coin: "BTC" })).resolves.toEqual({ closed: true, cancelled_orders: 2 });
  });

  it("errors from the exchange reach the app", async () => {
    const app = setupTrader();
    await expect(app.request("trade.execute", { network: "testnet", private_key: "k", coin: "FALLA", side: "long", size_usd: 500, leverage: 3, entry_type: "market", stop_loss: 1 }))
      .rejects.toThrow("Hyperliquid no responde");
  });
});

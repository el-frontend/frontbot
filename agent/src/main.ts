import { fileURLToPath } from "node:url";
import { RpcPeer } from "./rpc.js";
import { createProductionRunner, redactSecrets, toolContext, type Runner, type RunParams } from "./runner.js";
import { HyperliquidTrader, FakeTrader, type Trader } from "./trader.js";
import { createToolBridge } from "./tool-bridge.js";
import { realMarket } from "./trading.js";

// stdout es solo para JSON-RPC; cualquier log va a stderr.

export function startServer(peer: RpcPeer, runner: Runner, trader?: Trader) {
  const active = new Map<string, AbortController>();

  peer.onRequest("agent.run", async (params: RunParams) => {
    const controller = new AbortController();
    active.set(params.run_id, controller);
    let bridge: Awaited<ReturnType<typeof createToolBridge>> | undefined;
    try {
      let routedParams = params;
      if (params.provider === "codex") {
        const call = async (method: string, toolParams: Record<string, unknown>) => {
          if (method === "tool.trade_propose" && params.trading) {
            const coin = String(toolParams.coin ?? "").toUpperCase();
            const [price, account] = await Promise.all([
              realMarket.marketPrice(params.trading.network, coin),
              params.trading.address ? realMarket.accountState(params.trading.network, params.trading.address) : Promise.resolve(null),
            ]);
            return peer.request(method, { ...toolParams, snapshot: { price, account_value: account?.account_value ?? null, network: params.trading.network } });
          }
          return peer.request(method, toolParams);
        };
        bridge = await createToolBridge(call, { ...toolContext(params), trading: Boolean(params.trading) });
        // Private sidecar-only handoff consumed by CodexRunner. Never sent to Swift or logged.
        routedParams = { ...params, frontbot_mcp: { socketPath: bridge.socketPath, token: bridge.token } } as RunParams;
      }
      void runner
        .run(routedParams, (e) => peer.notify("agent.event", e), controller.signal)
        .then((done) => peer.notify("agent.done", done))
        .catch((err: Error) => peer.notify("agent.done", { run_id: params.run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: safeError(err) }))
        .finally(async () => {
          await bridge?.close();
          active.delete(params.run_id);
        });
    } catch (err) {
      await bridge?.close();
      active.delete(params.run_id);
      throw err;
    }
    return { accepted: true };
  });

  // Trading: solo la app llama a estos métodos (tras la aprobación del usuario o su mandato). El agente no los tiene.
  if (trader) {
    peer.onRequest("trade.execute", (p) => trader.execute(p));
    peer.onRequest("trade.close", (p) => trader.close(p));
    peer.onRequest("market.snapshot", (p) => trader.snapshot(p));
    peer.onRequest("account.overview", (p) => trader.overview(p));
  }

  peer.onRequest("agent.cancel", async ({ run_id }: { run_id: string }) => {
    active.get(run_id)?.abort();
    return { ok: true };
  });
}

/** Never reflect configured credentials in the stable JSON-RPC error contract. */
function safeError(error: Error): string {
  return redactSecrets(error?.message || "Error desconocido");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const peer = new RpcPeer(process.stdin, process.stdout);
  const call = (m: string, p: Record<string, unknown>) => peer.request(m, p);
  const fake = process.env.FRONTBOT_FAKE_AGENT === "1";
  const runner = createProductionRunner(call, process.env, fake);
  startServer(peer, runner, fake ? new FakeTrader() : new HyperliquidTrader());
  process.stdin.on("end", () => process.exit(0));
}

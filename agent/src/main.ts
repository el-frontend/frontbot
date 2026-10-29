import { fileURLToPath } from "node:url";
import { RpcPeer } from "./rpc.js";
import { RealRunner, FakeRunner, ProviderRunner, redactSecrets, type Runner, type RunParams } from "./runner.js";
import { HyperliquidTrader, FakeTrader, type Trader } from "./trader.js";

// stdout es solo para JSON-RPC; cualquier log va a stderr.

export function startServer(peer: RpcPeer, runner: Runner, trader?: Trader) {
  const active = new Map<string, AbortController>();

  peer.onRequest("agent.run", async (params: RunParams) => {
    const controller = new AbortController();
    active.set(params.run_id, controller);
    runner
      .run(params, (e) => peer.notify("agent.event", e), controller.signal)
      .then((done) => peer.notify("agent.done", done))
      .catch((err: Error) => peer.notify("agent.done", { run_id: params.run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: safeError(err) }))
      .finally(() => active.delete(params.run_id));
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
  const runner = fake ? new ProviderRunner(new FakeRunner(call), new FakeRunner(call))
    : new ProviderRunner(new RealRunner(call));
  startServer(peer, runner, fake ? new FakeTrader() : new HyperliquidTrader());
  process.stdin.on("end", () => process.exit(0));
}

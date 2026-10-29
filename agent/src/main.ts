import { fileURLToPath } from "node:url";
import { RpcPeer } from "./rpc.js";
import { createProductionRunner, redactSecrets, toolContext, type Runner, type RunParams, type RunnerContext } from "./runner.js";
import { HyperliquidTrader, FakeTrader, type Trader } from "./trader.js";
import { realMarket } from "./trading.js";
import { executeFrontbotTool, type AppCall } from "./tools.js";

/** Matches the former bridge's approval/runtime budget. */
export const APP_CALL_TIMEOUT_MS = 200_000;

function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stableJSON(item)}`).join(",")}}`;
  return JSON.stringify(value);
}

function boundedAppCall(peer: RpcPeer, method: string, params: Record<string, unknown>, signal: AbortSignal, timeoutMs: number): Promise<unknown> {
  const cancelled = () => signal.reason instanceof Error ? signal.reason : new Error("Cancelado");
  if (signal.aborted) return Promise.reject(cancelled());
  const controller = new AbortController();
  const cancel = () => controller.abort(cancelled());
  const timer = setTimeout(() => controller.abort(new Error(`La solicitud ${method} superó el plazo de ${timeoutMs / 1000}s y puede seguir pendiente en Frontbot. No repitas esta acción.`)), timeoutMs);
  signal.addEventListener("abort", cancel, { once: true });
  return peer.request(method, params, { signal: controller.signal }).finally(() => {
    clearTimeout(timer);
    signal.removeEventListener("abort", cancel);
  });
}

// stdout es solo para JSON-RPC; cualquier log va a stderr.

export function startServer(peer: RpcPeer, runner: Runner, trader?: Trader, options: { appCallTimeoutMs?: number } = {}) {
  const active = new Map<string, AbortController>();

  peer.onRequest("agent.run", async (params: RunParams) => {
    const controller = new AbortController();
    active.set(params.run_id, controller);
    try {
      let context: RunnerContext | undefined;
      if (params.provider === "codex") {
        const call: AppCall = async (method, toolParams) => {
          if (method === "tool.trade_propose" && params.trading) {
            const coin = String(toolParams.coin ?? "").toUpperCase();
            const [price, account] = await Promise.all([
              realMarket.marketPrice(params.trading.network, coin),
              params.trading.address ? realMarket.accountState(params.trading.network, params.trading.address) : Promise.resolve(null),
            ]);
            return boundedAppCall(peer, method, { ...toolParams, snapshot: { price, account_value: account?.account_value ?? null, network: params.trading.network } }, controller.signal, options.appCallTimeoutMs ?? APP_CALL_TIMEOUT_MS);
          }
          return boundedAppCall(peer, method, toolParams, controller.signal, options.appCallTimeoutMs ?? APP_CALL_TIMEOUT_MS);
        };
        const tools = toolContext(params);
        const inFlight = new Map<string, ReturnType<typeof executeFrontbotTool>>();
        const execute = (name: string, args: Record<string, unknown>) => {
          const fingerprint = stableJSON([name, args]);
          let execution = inFlight.get(fingerprint);
          if (!execution) {
            execution = executeFrontbotTool(name, args, call, tools);
            inFlight.set(fingerprint, execution);
            void execution.finally(() => { if (inFlight.get(fingerprint) === execution) inFlight.delete(fingerprint); }).catch(() => undefined);
          }
          return execution;
        };
        context = { frontbot: { call, context: tools, execute } };
      }
      void runner
        .run(params, (e) => peer.notify("agent.event", e), controller.signal, context)
        .then((done) => peer.notify("agent.done", done))
        .catch((err: Error) => peer.notify("agent.done", { run_id: params.run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: safeError(err) }))
        .finally(() => {
          active.delete(params.run_id);
        });
    } catch (err) {
      active.delete(params.run_id);
      throw new Error(safeError(err as Error));
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
    active.get(run_id)?.abort(new Error("Cancelado"));
    return { ok: true };
  });
}

/** Never reflect configured credentials in the stable JSON-RPC error contract. */
function safeError(error: Error, bridgeToken?: string): string {
  const message = error?.message || "Error desconocido";
  return redactSecrets(bridgeToken ? message.split(bridgeToken).join("[redacted]") : message);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const peer = new RpcPeer(process.stdin, process.stdout);
  const call = (m: string, p: Record<string, unknown>) => peer.request(m, p);
  const fake = process.env.FRONTBOT_FAKE_AGENT === "1";
  const runner = createProductionRunner(call, process.env, fake);
  startServer(peer, runner, fake ? new FakeTrader() : new HyperliquidTrader());
  process.stdin.on("end", () => process.exit(0));
}

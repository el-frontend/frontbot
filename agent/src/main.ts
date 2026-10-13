import { fileURLToPath } from "node:url";
import { RpcPeer } from "./rpc.js";
import { RealRunner, FakeRunner, type Runner, type RunParams } from "./runner.js";

// stdout es solo para JSON-RPC; cualquier log va a stderr.

export function startServer(peer: RpcPeer, runner: Runner) {
  const active = new Map<string, AbortController>();

  peer.onRequest("agent.run", async (params: RunParams) => {
    const controller = new AbortController();
    active.set(params.run_id, controller);
    runner
      .run(params, (e) => peer.notify("agent.event", e), controller.signal)
      .then((done) => peer.notify("agent.done", done))
      .catch((err: Error) => peer.notify("agent.done", { run_id: params.run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: err.message }))
      .finally(() => active.delete(params.run_id));
    return { accepted: true };
  });

  peer.onRequest("agent.cancel", async ({ run_id }: { run_id: string }) => {
    active.get(run_id)?.abort();
    return { ok: true };
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const peer = new RpcPeer(process.stdin, process.stdout);
  const call = (m: string, p: Record<string, unknown>) => peer.request(m, p);
  const runner = process.env.FRONTBOT_FAKE_AGENT === "1" ? new FakeRunner(call) : new RealRunner(call);
  startServer(peer, runner);
  process.stdin.on("end", () => process.exit(0));
}

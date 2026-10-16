import { fileURLToPath } from "node:url";
import { RpcPeer } from "./rpc.js";
import { RealRunner, FakeRunner, type Runner, type RunParams } from "./runner.js";
import { ChromePublisher, FakePublisher, type Publisher } from "./browser/session.js";

// stdout es solo para JSON-RPC; cualquier log va a stderr.

export function startServer(peer: RpcPeer, runner: Runner, publisher?: Publisher) {
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

  // Publicación asistida: solo la app llama a estos métodos; el agente no tiene herramientas para publicar.
  if (publisher) {
    peer.onRequest("publish.prepare", (params) => publisher.prepare(params));
    peer.onRequest("publish.login", (params) => publisher.login(params));
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const peer = new RpcPeer(process.stdin, process.stdout);
  const call = (m: string, p: Record<string, unknown>) => peer.request(m, p);
  const fake = process.env.FRONTBOT_FAKE_AGENT === "1";
  const runner = fake ? new FakeRunner(call) : new RealRunner(call);
  startServer(peer, runner, fake ? new FakePublisher() : new ChromePublisher());
  process.stdin.on("end", () => process.exit(0));
}

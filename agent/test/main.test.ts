import { describe, it, expect } from "vitest";
import { PassThrough } from "node:stream";
import { RpcPeer } from "../src/rpc.js";
import { startServer } from "../src/main.js";
import { FakeRunner } from "../src/runner.js";

function setup() {
  const appToAgent = new PassThrough();
  const agentToApp = new PassThrough();
  const app = new RpcPeer(agentToApp, appToAgent);
  const agent = new RpcPeer(appToAgent, agentToApp);
  startServer(agent, new FakeRunner((m, p) => agent.request(m, p)));
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

  it("cancel stops a slow run with ok=false", async () => {
    const app = setup();
    app.onRequest("tool.brands_list", async () => ({ brands: [] }));
    const done = new Promise<any>((resolve) => app.onNotification("agent.done", resolve));
    await app.request("agent.run", { run_id: "r2", prompt: "lento", model: "m" });
    await app.request("agent.cancel", { run_id: "r2" });
    await expect(done).resolves.toMatchObject({ run_id: "r2", ok: false, error: "Cancelado" });
  });
});

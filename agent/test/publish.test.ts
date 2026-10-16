import { describe, it, expect } from "vitest";
import { PassThrough } from "node:stream";
import { RpcPeer } from "../src/rpc.js";
import { startServer } from "../src/main.js";
import { FakeRunner } from "../src/runner.js";
import { FakePublisher } from "../src/browser/session.js";

function setup() {
  const appToAgent = new PassThrough();
  const agentToApp = new PassThrough();
  const app = new RpcPeer(agentToApp, appToAgent);
  const agent = new RpcPeer(appToAgent, agentToApp);
  startServer(agent, new FakeRunner((m, p) => agent.request(m, p)), new FakePublisher());
  return app;
}

describe("publish.* RPC", () => {
  it("prepare returns the publisher result", async () => {
    const app = setup();
    await expect(app.request("publish.prepare", { network: "linkedin", body: "hola", media: [], profile_dir: "/tmp/x" }))
      .resolves.toEqual({ mode: "composer", message: "(prueba) compositor listo", url: "https://www.linkedin.com/feed/" });
  });

  it("prepare errors travel as RPC errors", async () => {
    const app = setup();
    await expect(app.request("publish.prepare", { network: "linkedin", body: "falla", media: [], profile_dir: "/tmp/x" }))
      .rejects.toMatchObject({ message: "Chrome no está disponible" });
  });

  it("login opens the network", async () => {
    const app = setup();
    await expect(app.request("publish.login", { network: "instagram", profile_dir: "/tmp/x" })).resolves.toEqual({ ok: true });
  });
});

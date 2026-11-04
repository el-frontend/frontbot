import { afterEach, describe, expect, it } from "vitest";
import { fileURLToPath } from "node:url";
import { AppServer, type Spawn } from "../src/codex/appServer.js";

const FAKE = fileURLToPath(new URL("./fixtures/fake-codex.mjs", import.meta.url));
const spawnFake = (env: NodeJS.ProcessEnv = {}): Spawn => ({ command: process.execPath, args: [FAKE], env: { ...process.env, ...env }, cwd: process.cwd() });

const servers: AppServer[] = [];
const start = (env?: NodeJS.ProcessEnv) => { const s = AppServer.start(spawnFake(env)); servers.push(s); return s; };
afterEach(() => { while (servers.length) servers.pop()!.kill(); });

const turnDone = (s: AppServer) => new Promise<void>((resolve) => s.onNotification((m) => { if (m === "turn/completed") resolve(); }));

describe("AppServer", () => {
  it("request y respuesta", async () => {
    const s = start();
    await s.initialize();
    const models = await s.request<{ data: { id: string }[] }>("model/list", {});
    expect(models.data.map((m) => m.id)).toEqual(["gpt-6-astra", "gpt-6-sol"]);
  });

  it("notificaciones en orden", async () => {
    const s = start();
    const seen: string[] = [];
    s.onNotification((m, p) => { if (m === "item/agentMessage/delta") seen.push(p.delta); if (m === "turn/completed") seen.push("fin"); });
    await s.initialize();
    await s.request("thread/start", {});
    const done = turnDone(s);
    await s.request("turn/start", { threadId: "th-1", input: [{ type: "text", text: "hola" }] });
    await done;
    expect(seen).toEqual(["Ho", "la", "fin"]);
  });

  it("petición del servidor llega al handler y su respuesta vuelve", async () => {
    const s = start();
    const texts: string[] = [];
    s.onServerRequest(async (method, params) => ({ result: { success: true, contentItems: [{ type: "inputText", text: `${method}:${params.tool}` }] } }));
    s.onNotification((m, p) => { if (m === "item/agentMessage/delta") texts.push(p.delta); });
    await s.initialize();
    await s.request("thread/start", {});
    const done = turnDone(s);
    await s.request("turn/start", { threadId: "th-1", input: [{ type: "text", text: "usa brands_list" }] });
    await done;
    expect(texts.join("")).toBe("ok:true:item/tool/call:brands_list");
  });

  it("sin handler responde -32601", async () => {
    const s = start();
    const texts: string[] = [];
    s.onNotification((m, p) => { if (m === "item/agentMessage/delta") texts.push(p.delta); });
    await s.initialize();
    await s.request("thread/start", {});
    const done = turnDone(s);
    await s.request("turn/start", { threadId: "th-1", input: [{ type: "text", text: "permisos" }] });
    await done;
    expect(texts.join("")).toContain("-32601");
  });

  it("salida del proceso rechaza lo pendiente", async () => {
    const s = start();
    await s.initialize();
    await s.request("thread/start", {});
    await s.request("turn/start", { threadId: "th-1", input: [{ type: "text", text: "muere" }] });
    expect(await s.exited).toEqual({ code: 3 });
    await expect(s.request("model/list", {})).rejects.toThrow("Codex se cerró inesperadamente.");
  });

  it("kill es idempotente", async () => {
    const s = start();
    await s.initialize();
    s.kill();
    s.kill();
    await s.exited;
    await expect(s.request("model/list", {})).rejects.toThrow();
  });
});

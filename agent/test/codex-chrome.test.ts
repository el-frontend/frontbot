import { afterEach, describe, expect, it } from "vitest";
import { fileURLToPath } from "node:url";
import { ChromeBridge, claudeChromeCommand } from "../src/codex/chromeBridge.js";

const FAKE = fileURLToPath(new URL("./fixtures/fake-chrome-mcp.mjs", import.meta.url));
const bridges: ChromeBridge[] = [];
afterEach(() => { while (bridges.length) bridges.pop()!.close(); delete process.env.FAKE_CHROME_SOCIAL; delete process.env.FAKE_CHROME_HANG; });

async function start(timeoutMs?: number) {
  const b = await ChromeBridge.start({ command: process.execPath, args: [FAKE] }, timeoutMs);
  if (b) bridges.push(b);
  return b;
}

describe("ChromeBridge", () => {
  it("expone solo herramientas permitidas, con nombre corto", async () => {
    const names = (await start())!.tools.map((t) => t.name);
    expect(names).toEqual(expect.arrayContaining(["navigate", "computer", "tabs_context_mcp", "get_page_text"]));
    expect(names).not.toContain("javascript_tool");
    expect(names).not.toContain("file_upload");
  });

  it("el guardián bloquea un clic sin verificar las pestañas", async () => {
    const r = await (await start())!.call("computer", { action: "left_click" });
    expect(r.success).toBe(false);
    expect(r.text).toContain("Antes de hacer clic o escribir");
  });

  it("bloquea clics con una red social abierta", async () => {
    process.env.FAKE_CHROME_SOCIAL = "1";
    const b = (await start())!;
    expect((await b.call("tabs_context_mcp", {})).success).toBe(true);
    const r = await b.call("computer", { action: "left_click" });
    expect(r.success).toBe(false);
    expect(r.text).toContain("Hay una red social");
  });

  it("scroll pasa aunque haya una red abierta", async () => {
    process.env.FAKE_CHROME_SOCIAL = "1";
    const b = (await start())!;
    await b.call("tabs_context_mcp", {});
    expect(await b.call("computer", { action: "scroll" })).toEqual({ success: true, text: "called:computer" });
  });

  it("navegar a un esquema no web se niega", async () => {
    expect((await (await start())!.call("navigate", { url: "file:///etc/passwd" })).success).toBe(false);
  });

  it("una herramienta no listada se niega sin reenviarla", async () => {
    expect(await (await start())!.call("javascript_tool", { text: "1" })).toEqual({ success: false, text: "Esta herramienta del navegador no está permitida en Frontbot." });
  });

  it("start devuelve null si el servidor no responde", async () => {
    process.env.FAKE_CHROME_HANG = "1";
    expect(await start(300)).toBeNull();
  });

  it("claudeChromeCommand usa FRONTBOT_CLAUDE_BIN", () => {
    expect(claudeChromeCommand({ FRONTBOT_CLAUDE_BIN: "/x/claude" })).toEqual({ command: "/x/claude", args: ["--claude-in-chrome-mcp"] });
    expect(claudeChromeCommand({}).command).toMatch(/claude$/);
  });
});

describe("ChromeBridge · llamadas en paralelo", () => {
  it("un contexto viejo no habilita un clic tras navegar", async () => {
    process.env.FAKE_CHROME_SLOW_CONTEXT = "1";
    const b = (await start())!;
    const context = b.call("tabs_context_mcp", {});
    const nav = b.call("navigate", { url: "https://www.linkedin.com/feed" });
    await Promise.all([context, nav]);
    const click = await b.call("computer", { action: "left_click" });
    expect(click.success).toBe(false);
    expect(click.text).toContain("Antes de hacer clic");
    delete process.env.FAKE_CHROME_SLOW_CONTEXT;
  });
});

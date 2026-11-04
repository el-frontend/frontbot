import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { AppServer, type Spawn } from "../src/codex/appServer.js";
import { CodexAccount, FakeCodexAccount, codexVersionOk, locateCodex, CODEX_CANDIDATES } from "../src/codex/account.js";

const FAKE = fileURLToPath(new URL("./fixtures/fake-codex.mjs", import.meta.url));
const fakeStart = (extra: NodeJS.ProcessEnv = {}) => vi.fn((s: Spawn) => AppServer.start({ ...s, command: process.execPath, args: [FAKE], env: { ...s.env, ...extra } }));
const version = (v: string) => async () => v;
const home = () => join(mkdtempSync(join(tmpdir(), "fb-codex-home-")), "codex-home");

describe("locateCodex", () => {
  it("prefiere FRONTBOT_CODEX_BIN", () => {
    expect(locateCodex({ FRONTBOT_CODEX_BIN: "/x/codex" }, () => true)).toBe("/x/codex");
  });
  it("usa el primer candidato que existe", () => {
    expect(locateCodex({}, (p) => p === CODEX_CANDIDATES[1])).toBe(CODEX_CANDIDATES[1]);
  });
  it("busca en el PATH", () => {
    expect(locateCodex({ PATH: "/a:/b" }, (p) => p === "/b/codex")).toBe("/b/codex");
  });
  it("devuelve null sin candidatos", () => {
    expect(locateCodex({ PATH: "/a" }, () => false)).toBeNull();
  });
});

describe("codexVersionOk", () => {
  it("compara con la mínima 0.158.0", () => {
    expect(codexVersionOk("codex-cli 0.158.0-alpha.2.1")).toBe(true);
    expect(codexVersionOk("codex-cli 0.157.9")).toBe(false);
    expect(codexVersionOk("codex-cli 1.0.0")).toBe(true);
    expect(codexVersionOk("codex-cli 0.159.3\n")).toBe(true);
    expect(codexVersionOk("basura")).toBe(false);
  });
});

describe("CodexAccount", () => {
  const accounts: CodexAccount[] = [];
  afterEach(() => { while (accounts.length) accounts.pop()!.close(); });
  const make = (opts: ConstructorParameters<typeof CodexAccount>[0]) => { const a = new CodexAccount(opts); accounts.push(a); return a; };

  it("sin binario no está instalado", async () => {
    expect(await make({ bin: null, home: home() }).status()).toEqual({ installed: false, compatible: false, version: null, account: null, models: [] });
  });

  it("con versión vieja no arranca el servidor", async () => {
    const start = fakeStart();
    const s = await make({ bin: "/x/codex", home: home(), version: version("codex-cli 0.150.0"), start }).status();
    expect(s).toMatchObject({ installed: true, compatible: false, version: "0.150.0", account: null });
    expect(start).not.toHaveBeenCalled();
  });

  it("conectado devuelve cuenta y modelos", async () => {
    const s = await make({ bin: "/x/codex", home: home(), version: version("codex-cli 0.158.0"), start: fakeStart() }).status();
    expect(s).toEqual({ installed: true, compatible: true, version: "0.158.0", account: { email: "fake@frontbot.test", plan: "pro" }, models: ["gpt-6-astra", "gpt-6-sol"] });
  });

  it("sin cuenta no lista modelos", async () => {
    const s = await make({ bin: "/x/codex", home: home(), version: version("codex-cli 0.158.0"), start: fakeStart({ FAKE_CODEX_NO_ACCOUNT: "1" }) }).status();
    expect(s.account).toBeNull();
    expect(s.models).toEqual([]);
  });

  it("arranca con CODEX_HOME propio y crea la carpeta con modo 700", async () => {
    const h = home();
    const start = fakeStart();
    await make({ bin: "/x/codex", home: h, version: version("codex-cli 0.158.0"), start }).status();
    expect(statSync(h).mode & 0o777).toBe(0o700);
    expect(start.mock.calls[0][0].env.CODEX_HOME).toBe(h);
    expect(start.mock.calls[0][0].args).toContain("mcp_servers={}");
  });

  it("login devuelve la URL y waitLogin espera a que termine", async () => {
    const a = make({ bin: "/x/codex", home: home(), version: version("codex-cli 0.158.0"), start: fakeStart() });
    expect(await a.login()).toEqual({ auth_url: "https://auth.openai.com/fake" });
    expect(await a.waitLogin(2000)).toEqual({ ok: true });
  });

  it("waitLogin sin login pendiente devuelve false", async () => {
    expect(await make({ bin: "/x/codex", home: home(), version: version("codex-cli 0.158.0"), start: fakeStart() }).waitLogin(100)).toEqual({ ok: false });
  });
});

describe("FakeCodexAccount", () => {
  it("refleja la sesión simulada", async () => {
    expect((await new FakeCodexAccount(true).status()).account?.email).toBe("fake@frontbot.test");
    expect((await new FakeCodexAccount(false).status()).account).toBeNull();
  });
});

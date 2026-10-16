import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { chromium, type Browser } from "playwright-core";
import { COMPOSERS, type Network } from "./composers.js";
import { preparePost, type PrepareParams, type PrepareResult } from "./prepare.js";

export interface Publisher {
  prepare(params: PrepareParams & { profile_dir: string }): Promise<PrepareResult>;
  login(params: { network: Network; profile_dir: string }): Promise<{ ok: true }>;
}

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/**
 * Chrome con perfil propio de Frontbot, lanzado como proceso independiente y controlado por CDP.
 * Así la ventana (con el post a medio preparar) sobrevive aunque el sidecar se reinicie, y un
 * sidecar nuevo se reconecta al mismo Chrome en vez de lanzar otro sobre el mismo perfil.
 */
export class ChromePublisher implements Publisher {
  /** PID del Chrome que lanzó esta instancia (undefined si se reconectó a uno existente). */
  launchedPid?: number;
  private connected?: Browser;
  private connecting?: Promise<Browser>;

  constructor(private opts: { headless?: boolean; chromePath?: string } = {}) {}

  /** Una sola conexión aunque lleguen varias llamadas a la vez. */
  browser(profileDir: string): Promise<Browser> {
    if (this.connected?.isConnected()) return Promise.resolve(this.connected);
    this.connecting ??= this.connect(profileDir)
      .then((b) => {
        this.connected = b;
        b.on("disconnected", () => { if (this.connected === b) this.connected = undefined; });
        return b;
      })
      .finally(() => { this.connecting = undefined; });
    return this.connecting;
  }

  /** Suelta la conexión sin cerrar Chrome. */
  async disconnect(): Promise<void> {
    const b = this.connected;
    this.connected = undefined;
    await b?.close().catch(() => {});
  }

  private async tryConnect(profileDir: string): Promise<Browser | null> {
    try {
      const port = readFileSync(join(profileDir, "DevToolsActivePort"), "utf8").split("\n")[0].trim();
      return await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: 2000 });
    } catch {
      return null;
    }
  }

  private async connect(profileDir: string): Promise<Browser> {
    const existing = await this.tryConnect(profileDir);
    if (existing) return existing;
    const chromePath = this.opts.chromePath ?? CHROME;
    if (!existsSync(chromePath)) throw new Error("No encontré Google Chrome en /Applications. Instálalo para publicar desde Frontbot.");
    mkdirSync(profileDir, { recursive: true });
    rmSync(join(profileDir, "DevToolsActivePort"), { force: true }); // puede quedar de un Chrome que ya murió
    const args = [`--user-data-dir=${profileDir}`, "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check"];
    if (this.opts.headless) args.push("--headless=new");
    const child = spawn(chromePath, [...args, "about:blank"], { detached: true, stdio: "ignore" });
    child.unref();
    this.launchedPid = child.pid;
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      const b = await this.tryConnect(profileDir);
      if (b) return b;
      await new Promise((r) => setTimeout(r, 250));
    }
    throw new Error("No pude abrir la ventana de Chrome de Frontbot. Si ya hay una abierta con otro programa, ciérrala y vuelve a intentar.");
  }

  private async newPage(profileDir: string) {
    const b = await this.browser(profileDir);
    const ctx = b.contexts()[0] ?? (await b.newContext());
    return ctx.newPage();
  }

  async prepare(params: PrepareParams & { profile_dir: string }): Promise<PrepareResult> {
    return preparePost(await this.newPage(params.profile_dir), params);
  }

  async login(params: { network: Network; profile_dir: string }): Promise<{ ok: true }> {
    const page = await this.newPage(params.profile_dir);
    await page.goto(COMPOSERS[params.network].startUrl, { waitUntil: "domcontentloaded", timeout: 30_000 });
    await page.bringToFront().catch(() => {});
    return { ok: true };
  }
}

/** Sin navegador: para probar la app de punta a punta. */
export class FakePublisher implements Publisher {
  async prepare(params: PrepareParams & { profile_dir: string }): Promise<PrepareResult> {
    if (params.body === "falla") throw new Error("Chrome no está disponible");
    if (params.body === "lento") await new Promise((r) => setTimeout(r, 5000));
    const url = COMPOSERS[params.network].startUrl;
    if (params.body === "manual") return { mode: "manual", message: "(prueba) modo manual", url };
    return { mode: "composer", message: "(prueba) compositor listo", url };
  }

  async login(): Promise<{ ok: true }> {
    return { ok: true };
  }
}

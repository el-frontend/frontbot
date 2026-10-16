import { chromium, type BrowserContext } from "playwright-core";
import { COMPOSERS, type Network } from "./composers.js";
import { preparePost, type PrepareParams, type PrepareResult } from "./prepare.js";

export interface Publisher {
  prepare(params: PrepareParams & { profile_dir: string }): Promise<PrepareResult>;
  login(params: { network: Network; profile_dir: string }): Promise<{ ok: true }>;
}

/** Chrome con perfil propio de Frontbot. Se reutiliza entre preparaciones; si el usuario lo cierra, se relanza. */
export class ChromePublisher implements Publisher {
  private context?: BrowserContext;

  private async ctx(profileDir: string): Promise<BrowserContext> {
    if (!this.context) {
      const ctx = await chromium.launchPersistentContext(profileDir, { channel: "chrome", headless: false, viewport: null });
      ctx.on("close", () => { if (this.context === ctx) this.context = undefined; });
      this.context = ctx;
    }
    return this.context;
  }

  async prepare(params: PrepareParams & { profile_dir: string }): Promise<PrepareResult> {
    const page = await (await this.ctx(params.profile_dir)).newPage();
    return preparePost(page, params);
  }

  async login(params: { network: Network; profile_dir: string }): Promise<{ ok: true }> {
    const page = await (await this.ctx(params.profile_dir)).newPage();
    await page.goto(COMPOSERS[params.network].startUrl, { waitUntil: "domcontentloaded" });
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

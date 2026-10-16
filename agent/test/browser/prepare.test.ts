import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { chromium, type Browser } from "playwright-core";
import { preparePost } from "../../src/browser/prepare.js";
import { COMPOSERS } from "../../src/browser/composers.js";

const hasChrome = existsSync("/Applications/Google Chrome.app");
let browser: Browser;
const fast = { timeoutMs: 1500, optionalTimeoutMs: 200 };

function fixture(relPath: string, html: string): string {
  const dir = mkdtempSync(join(tmpdir(), "fb-"));
  const file = join(dir, relPath);
  mkdirSync(join(file, ".."), { recursive: true });
  writeFileSync(file, `<meta charset="utf-8">${html}`); // sin charset, file:// no lee bien los acentos
  return pathToFileURL(file).href;
}

function image(): string {
  const file = join(mkdtempSync(join(tmpdir(), "fb-")), "a.png");
  writeFileSync(file, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  return file;
}

// Imita el flujo web de Instagram: Crear → subir → Siguiente → Siguiente → pie de foto.
const instagramLike = `
<a aria-label="Nueva publicación" href="#" onclick="document.getElementById('up').style.display='block';return false">+</a>
<div id="up" style="display:none">
  <input type="file" accept="image/jpeg,image/png" multiple style="display:none"
    onchange="document.getElementById('n1').style.display='block'">
</div>
<div role="button" id="n1" style="display:none" onclick="this.style.display='none';document.getElementById('n2').style.display='block'">Siguiente</div>
<div role="button" id="n2" style="display:none" onclick="this.style.display='none';document.getElementById('cap').style.display='block'">Siguiente</div>
<div id="cap" aria-label="Escribe un pie de foto..." role="textbox" contenteditable="true" style="display:none"></div>
<button id="share" onclick="document.body.dataset.shared='yes'">Compartir</button>`;

describe("composers", () => {
  it("instagram requires media; linkedin does not", () => {
    expect(COMPOSERS.instagram.requiresMedia).toBe(true);
    expect(COMPOSERS.linkedin.requiresMedia).toBe(false);
  });

  it("no step ever clicks a publish/share button", () => {
    for (const c of Object.values(COMPOSERS)) {
      for (const s of c.steps) {
        expect(s.candidates.join(" ")).not.toMatch(/Share|Compartir|Publicar|Publish/);
      }
    }
  });
});

describe.skipIf(!hasChrome)("preparePost", () => {
  beforeAll(async () => { browser = await chromium.launch({ channel: "chrome", headless: true }); });
  afterAll(async () => { await browser?.close(); });

  it("fills the instagram-like composer and stops before sharing", async () => {
    const page = await browser.newPage();
    const url = fixture("ig/index.html", instagramLike);
    const res = await preparePost(page, { network: "instagram", body: "Hola ☕️", media: [image()], start_url: url }, fast);
    expect(res.mode).toBe("composer");
    expect(await page.locator("#cap").innerText()).toBe("Hola ☕️");
    expect(await page.evaluate(() => (document.querySelector("input[type=file]") as HTMLInputElement).files!.length)).toBe(1);
    expect(await page.evaluate(() => document.body.dataset.shared)).toBeUndefined();
  });

  it("detects a login redirect quickly and goes manual", async () => {
    const page = await browser.newPage();
    const url = fixture("accounts/login/index.html", "<form>login</form>");
    const started = Date.now();
    const res = await preparePost(page, { network: "instagram", body: "x", media: [image()], start_url: url }, fast);
    expect(res).toMatchObject({ mode: "manual", message: "Inicia sesión en Instagram en la ventana de Frontbot y vuelve a intentar." });
    expect(Date.now() - started).toBeLessThan(1000);
  });

  it("goes manual naming the step when the UI changed", async () => {
    const page = await browser.newPage();
    const url = fixture("feed/index.html", "<p>interfaz nueva</p>");
    const res = await preparePost(page, { network: "linkedin", body: "x", media: [], start_url: url }, fast);
    expect(res.mode).toBe("manual");
    expect(res.message).toBe('No pude completar el paso "Empezar una publicación". Pega el texto (ya está en el portapapeles) y sube las imágenes a mano.');
  });

  it("rejects instagram without images", async () => {
    const page = await browser.newPage();
    await expect(preparePost(page, { network: "instagram", body: "x", media: [] }, fast)).rejects.toThrow("Instagram necesita al menos una imagen.");
  });
});

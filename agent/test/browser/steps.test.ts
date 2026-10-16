import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium, type Browser, type Page } from "playwright-core";
import { runSteps, StepError, type Step } from "../../src/browser/steps.js";

const hasChrome = existsSync("/Applications/Google Chrome.app");
let browser: Browser;

async function pageWith(html: string): Promise<Page> {
  const page = await browser.newPage();
  await page.setContent(html);
  return page;
}

describe.skipIf(!hasChrome)("runSteps", () => {
  beforeAll(async () => { browser = await chromium.launch({ channel: "chrome", headless: true }); });
  afterAll(async () => { await browser?.close(); });

  const fast = { timeoutMs: 1500, optionalTimeoutMs: 300 };

  it("clicks the first visible candidate", async () => {
    const page = await pageWith(`<button id="a" style="display:none">A</button><button id="b" onclick="document.body.dataset.done='b'">B</button>`);
    await runSteps(page, [{ kind: "click", label: "botón", candidates: ["#a", "#b"] }], { body: "", media: [] }, fast);
    expect(await page.evaluate(() => document.body.dataset.done)).toBe("b");
  });

  it("picks the visible element when a selector matches a hidden one first", async () => {
    const page = await pageWith(`<button class="n" style="display:none">Siguiente</button><button class="n" onclick="document.body.dataset.done='2'">Siguiente</button>`);
    await runSteps(page, [{ kind: "click", label: "Siguiente", candidates: [".n"] }], { body: "", media: [] }, fast);
    expect(await page.evaluate(() => document.body.dataset.done)).toBe("2");
  });

  it("fills a contenteditable with unicode", async () => {
    const page = await pageWith(`<div id="t" role="textbox" contenteditable="true"></div>`);
    await runSteps(page, [{ kind: "fill", label: "texto", candidates: ["#t"] }], { body: "Lunes de café ☕️ #cafe", media: [] }, fast);
    expect(await page.locator("#t").innerText()).toBe("Lunes de café ☕️ #cafe");
  });

  it("uploads to a hidden file input", async () => {
    const dir = mkdtempSync(join(tmpdir(), "fb-"));
    const img = join(dir, "a.png");
    writeFileSync(img, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    const page = await pageWith(`<input id="f" type="file" multiple style="display:none">`);
    await runSteps(page, [{ kind: "upload", label: "imágenes", candidates: ["#f"] }], { body: "", media: [img] }, fast);
    expect(await page.evaluate(() => (document.getElementById("f") as HTMLInputElement).files!.length)).toBe(1);
  });

  it("throws StepError naming the missing step", async () => {
    const page = await pageWith(`<p>nada</p>`);
    const err = await runSteps(page, [{ kind: "click", label: "Crear", candidates: ["#nope"] }], { body: "", media: [] }, fast).catch((e) => e);
    expect(err).toBeInstanceOf(StepError);
    expect(err.message).toBe('No encontré el paso "Crear".');
  });

  it("skips optional and media-only steps when they do not apply", async () => {
    const page = await pageWith(`<button id="b" onclick="document.body.dataset.done='ok'">B</button>`);
    const steps: Step[] = [
      { kind: "click", label: "menú", candidates: ["#menu"], optional: true },
      { kind: "upload", label: "imágenes", candidates: ["#f"], onlyIfMedia: true },
      { kind: "click", label: "botón", candidates: ["#b"] },
    ];
    await runSteps(page, steps, { body: "", media: [] }, fast);
    expect(await page.evaluate(() => document.body.dataset.done)).toBe("ok");
  });
});

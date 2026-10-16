# Frontbot Fase 3 — Publicación asistida (Instagram y LinkedIn) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Desde un post aprobado, el usuario pulsa "Preparar publicación": Frontbot abre un Chrome con perfil propio, rellena el compositor de Instagram o LinkedIn (imágenes + texto) y se detiene; el usuario pulsa Publicar/Programar en la red y confirma en Frontbot. Si algo falla, modo manual: texto al portapapeles e imágenes en Finder.

**Architecture:** El sidecar gana un motor de pasos sobre Playwright (`playwright-core`, usando el Chrome instalado) y dos compositores declarativos (listas de selectores candidatos por paso, para arreglar cambios de las redes tocando solo datos). La app lo invoca por JSON-RPC (`publish.prepare`, `publish.login`) — **nunca** como herramienta del agente. En Swift, `PublishingService` orquesta estados (`approved → preparing → published|scheduled`, o vuelta a `approved`) contra un protocolo `PublicationPreparer` que implementa `AgentClient`.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit (NSPasteboard, NSWorkspace), GRDB, XCTest · Node 24, TypeScript, playwright-core 1.x, vitest.

**Spec:** `docs/superpowers/specs/2026-10-13-frontbot-design.md` (secciones 3.1 `PublishingProvider`, 4.1, 5.5, 7, 8).

**Fuera de esta fase:** APIs oficiales de las redes (v2), notch y empaquetado `.app` (Fase 4).

## Global Constraints

- Las de Fases 1–2. En particular: **nunca se pulsa Publicar automáticamente**; el agente no tiene herramientas de publicación (los métodos `publish.*` los llama solo la app).
- Perfil de Chrome dedicado: `~/Library/Application Support/Frontbot/browser-profile/`. Nunca el Chrome personal.
- Chrome se lanza con `channel: "chrome"` (el instalado en `/Applications`), `headless: false`, `viewport: null`. El contexto persistente se reutiliza entre preparaciones; si el usuario cierra la ventana, la siguiente preparación lo relanza.
- Cada paso del compositor espera como máximo **8 s** (pasos opcionales **1,5 s**). La llamada `publish.prepare` desde Swift tiene un límite de **120 s**.
- Instagram exige al menos una imagen: `"Instagram necesita al menos una imagen."`.
- URL de publicación confirmada: opcional; si se da, debe empezar con `http://` o `https://`: `"La URL debe empezar con https://."`.
- Mensajes al usuario en español.

## Review Focus

1. **El usuario no ha iniciado sesión** en la red — la página redirige al login: modo manual con "Inicia sesión en Instagram en la ventana de Frontbot y vuelve a intentar.", sin quedarse esperando 8 s por paso. Test en Task 2.
2. **La red cambió su interfaz** (un selector ya no existe) — modo manual que nombra el paso que falló; el post queda en `preparing` para que el usuario confirme o cancele. Test en Task 2.
3. **El sidecar o Chrome fallan durante la preparación** (Chrome no instalado, proceso muerto) — el post vuelve a `approved` con un error legible; nunca queda atascado en `preparing`. Tests en Tasks 4 y 5.
4. **Post de Instagram sin imágenes o post no aprobado** — se rechaza antes de abrir el navegador. Test en Task 4.
5. **Respuesta RPC que nunca llega** — `call` falla por tiempo con "El agente no respondió a tiempo." y no deja continuaciones colgadas. Test en Task 5.

---

## Estructura de archivos

```
agent/src/browser/
├── steps.ts        # NUEVO: motor de pasos (click/upload/fill, candidatos, opcionales)
├── composers.ts    # NUEVO: definiciones de Instagram y LinkedIn
├── prepare.ts      # NUEVO: navegar, detectar login, correr pasos, modo manual
└── session.ts      # NUEVO: contexto persistente de Chrome + Publisher real/falso
agent/src/main.ts   # MOD: publish.prepare / publish.login
agent/test/browser/*.test.ts, agent/test/publish.test.ts
app/Sources/FrontbotCore/
├── Publishing/PublishingService.swift   # NUEVO: protocolo PublicationPreparer + orquestación
├── Store/Repositories.swift             # MOD: markPublished(id:url:)
├── Store/AppPaths.swift                 # MOD: browserProfile
└── Agent/AgentClient.swift              # MOD: call(_:params:timeout:), PublicationPreparer
app/Sources/FrontbotApp/
├── AppModel.swift, PostEditorView.swift, SettingsView.swift   # MOD
```

---

### Task 1: Motor de pasos del navegador

**Files:**
- Modify: `agent/package.json` (dependencia `playwright-core`)
- Create: `agent/src/browser/steps.ts`
- Test: `agent/test/browser/steps.test.ts`

**Interfaces:**
- Produces:
  - `type Step = { kind: "click" | "upload" | "fill"; label: string; candidates: string[]; optional?: boolean; onlyIfMedia?: boolean }`
  - `type StepInput = { body: string; media: string[] }`
  - `class StepError extends Error { step: string }` — mensaje `No encontré el paso "<label>".`
  - `runSteps(page: Page, steps: Step[], input: StepInput, opts?: { timeoutMs?: number; optionalTimeoutMs?: number }): Promise<void>`
- Reglas: para cada paso, se prueban los candidatos en orden cada 200 ms hasta el límite; `click`/`fill` exigen el elemento **visible**, `upload` solo que exista (los `input[type=file]` suelen estar ocultos). `fill` hace click en el elemento y escribe con `page.keyboard.insertText(body)` (sirve para `textarea` y `contenteditable`). `onlyIfMedia` se salta si `media` está vacío. `optional` se salta si no aparece en `optionalTimeoutMs`.
- Los tests usan Chrome headless real (`channel: "chrome"`) y se saltan si no existe `/Applications/Google Chrome.app`.

- [ ] **Step 1: Instalar dependencia** — `cd agent && npm install playwright-core@^1` (ya instalado si `node_modules/playwright-core` existe).

- [ ] **Step 2: Escribir el test que falla**

```ts
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
```

- [ ] **Step 3: Correr y verificar que falla**

Run: `cd agent && npx vitest run test/browser/steps.test.ts`
Expected: FAIL — `Cannot find module '../../src/browser/steps.js'`.

- [ ] **Step 4: Implementar** `agent/src/browser/steps.ts`:

```ts
import type { Locator, Page } from "playwright-core";

export type Step = {
  kind: "click" | "upload" | "fill";
  label: string;
  candidates: string[];
  optional?: boolean;
  onlyIfMedia?: boolean;
};

export type StepInput = { body: string; media: string[] };

export class StepError extends Error {
  constructor(public step: string) {
    super(`No encontré el paso "${step}".`);
  }
}

async function find(page: Page, step: Step, timeoutMs: number): Promise<Locator | null> {
  const deadline = Date.now() + timeoutMs;
  do {
    for (const selector of step.candidates) {
      const loc = page.locator(selector).first();
      const ok = step.kind === "upload"
        ? (await loc.count().catch(() => 0)) > 0
        : await loc.isVisible().catch(() => false);
      if (ok) return loc;
    }
    await page.waitForTimeout(200);
  } while (Date.now() < deadline);
  return null;
}

/** Ejecuta los pasos de un compositor. Nunca pulsa "Publicar": eso lo hace el usuario. */
export async function runSteps(page: Page, steps: Step[], input: StepInput, opts: { timeoutMs?: number; optionalTimeoutMs?: number } = {}): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 8000;
  const optionalTimeoutMs = opts.optionalTimeoutMs ?? 1500;
  for (const step of steps) {
    if (step.onlyIfMedia && input.media.length === 0) continue;
    const loc = await find(page, step, step.optional ? optionalTimeoutMs : timeoutMs);
    if (!loc) {
      if (step.optional) continue;
      throw new StepError(step.label);
    }
    if (step.kind === "click") await loc.click();
    if (step.kind === "upload") await loc.setInputFiles(input.media);
    if (step.kind === "fill") {
      await loc.click();
      await page.keyboard.insertText(input.body);
    }
  }
}
```

- [ ] **Step 5: Correr y verificar que pasa**

Run: `cd agent && npx vitest run test/browser/steps.test.ts && npm run typecheck`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add agent/package.json agent/package-lock.json agent/src/browser agent/test/browser
git commit -m "feat: add browser step engine for assisted publishing"
```

---

### Task 2: Compositores de Instagram y LinkedIn, y preparación con modo manual

**Files:**
- Create: `agent/src/browser/composers.ts`, `agent/src/browser/prepare.ts`
- Test: `agent/test/browser/prepare.test.ts`

**Interfaces:**
- Consumes: `runSteps`, `StepError`, `Step` (Task 1).
- Produces:
  - `type Network = "instagram" | "linkedin"`
  - `type Composer = { network: Network; name: string; startUrl: string; loginPatterns: RegExp[]; requiresMedia: boolean; steps: Step[] }`
  - `const COMPOSERS: Record<Network, Composer>`
  - `type PrepareParams = { network: Network; body: string; media: string[]; start_url?: string }`
  - `type PrepareResult = { mode: "composer" | "manual"; message: string; url: string }`
  - `preparePost(page: Page, params: PrepareParams, opts?: { timeoutMs?: number; optionalTimeoutMs?: number }): Promise<PrepareResult>`
- Mensajes:
  - composer: `"Listo: revisa el post en la ventana de Chrome de Frontbot y publícalo o prográmalo tú."`
  - login: `"Inicia sesión en <Instagram|LinkedIn> en la ventana de Frontbot y vuelve a intentar."`
  - paso fallido: `"No pude completar el paso \"<label>\". Pega el texto (ya está en el portapapeles) y sube las imágenes a mano."`
  - no se pudo abrir: `"No pude abrir <name>: <error>"`
  - sin imagen en IG: lanza `Error("Instagram necesita al menos una imagen.")`
- `url` del resultado es `page.url()` al terminar (o la URL de inicio si `goto` falló).

- [ ] **Step 1: Escribir el test que falla**

```ts
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
  writeFileSync(file, html);
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
<button id="share">Compartir</button>`;

describe("composers", () => {
  it("instagram requires media; linkedin does not", () => {
    expect(COMPOSERS.instagram.requiresMedia).toBe(true);
    expect(COMPOSERS.linkedin.requiresMedia).toBe(false);
  });

  it("no step ever clicks a publish/share button", () => {
    for (const c of Object.values(COMPOSERS)) {
      for (const s of c.steps) {
        expect(s.candidates.join(" ")).not.toMatch(/Share|Compartir|Post\b|Publicar|Publish/);
      }
    }
  });
});

describe.skipIf(!hasChrome)("preparePost", () => {
  beforeAll(async () => { browser = await chromium.launch({ channel: "chrome", headless: true }); });
  afterAll(async () => { await browser?.close(); });

  it("fills the instagram-like composer and stops before sharing", async () => {
    const page = await browser.newPage();
    await page.exposeFunction("noop", () => {});
    const url = fixture("ig/index.html", instagramLike);
    const res = await preparePost(page, { network: "instagram", body: "Hola ☕️", media: [image()], start_url: url }, fast);
    expect(res.mode).toBe("composer");
    expect(await page.locator("#cap").innerText()).toBe("Hola ☕️");
    expect(await page.evaluate(() => (document.querySelector("input[type=file]") as HTMLInputElement).files!.length)).toBe(1);
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
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd agent && npx vitest run test/browser/prepare.test.ts`
Expected: FAIL — `Cannot find module '../../src/browser/prepare.js'`.

- [ ] **Step 3: Implementar** `agent/src/browser/composers.ts`:

```ts
import type { Step } from "./steps.js";

export type Network = "instagram" | "linkedin";

export type Composer = {
  network: Network;
  name: string;
  startUrl: string;
  loginPatterns: RegExp[];
  requiresMedia: boolean;
  steps: Step[];
};

const next = ['div[role="button"]:text-is("Next")', 'div[role="button"]:text-is("Siguiente")', 'button:text-is("Next")', 'button:text-is("Siguiente")'];

/**
 * Selectores candidatos por paso (inglés y español). Si una red cambia su interfaz,
 * se arregla aquí. Ningún paso pulsa Compartir/Publicar: eso lo hace el usuario.
 */
export const COMPOSERS: Record<Network, Composer> = {
  instagram: {
    network: "instagram",
    name: "Instagram",
    startUrl: "https://www.instagram.com/",
    loginPatterns: [/\/accounts\/login/, /\/challenge\//],
    requiresMedia: true,
    steps: [
      { kind: "click", label: "Crear", candidates: ['[aria-label="New post"]', '[aria-label="Nueva publicación"]', 'svg[aria-label="New post"]', 'svg[aria-label="Nueva publicación"]', 'a:has-text("Create")', 'a:has-text("Crear")'] },
      { kind: "click", label: "Publicación", optional: true, candidates: ['a:has(span:text-is("Post"))', 'a:has(span:text-is("Publicación"))', '[role="menuitem"]:has-text("Post")', '[role="menuitem"]:has-text("Publicación")'] },
      { kind: "upload", label: "Seleccionar imágenes", candidates: ['input[type="file"][accept*="image"]', 'input[type="file"]'] },
      { kind: "click", label: "Siguiente (recorte)", candidates: next },
      { kind: "click", label: "Siguiente (filtros)", candidates: next },
      { kind: "fill", label: "Pie de foto", candidates: ['[aria-label="Write a caption..."]', '[aria-label="Escribe un pie de foto..."]', 'div[role="textbox"][contenteditable="true"]', 'textarea'] },
    ],
  },
  linkedin: {
    network: "linkedin",
    name: "LinkedIn",
    startUrl: "https://www.linkedin.com/feed/",
    loginPatterns: [/\/login/, /\/checkpoint\//, /\/authwall/, /\/uas\/login/],
    requiresMedia: false,
    steps: [
      { kind: "click", label: "Empezar una publicación", candidates: ['button:has-text("Start a post")', 'button:has-text("Empezar una publicación")', 'button:has-text("Crear publicación")', '.share-box-feed-entry__trigger'] },
      { kind: "click", label: "Añadir multimedia", onlyIfMedia: true, candidates: ['button[aria-label="Add media"]', 'button[aria-label="Añadir contenido multimedia"]', 'button[aria-label="Añadir multimedia"]'] },
      { kind: "upload", label: "Seleccionar imágenes", onlyIfMedia: true, candidates: ['input[type="file"]'] },
      { kind: "click", label: "Siguiente (multimedia)", onlyIfMedia: true, candidates: ['button:has-text("Next")', 'button:has-text("Siguiente")'] },
      { kind: "fill", label: "Texto del post", candidates: ['div.ql-editor[contenteditable="true"]', 'div[role="textbox"][contenteditable="true"]'] },
    ],
  },
};
```

`agent/src/browser/prepare.ts`:
```ts
import type { Page } from "playwright-core";
import { COMPOSERS, type Network } from "./composers.js";
import { runSteps, StepError } from "./steps.js";

export type PrepareParams = { network: Network; body: string; media: string[]; start_url?: string };
export type PrepareResult = { mode: "composer" | "manual"; message: string; url: string };

/** Abre el compositor de la red y lo rellena. Se detiene antes de publicar. */
export async function preparePost(page: Page, params: PrepareParams, opts: { timeoutMs?: number; optionalTimeoutMs?: number } = {}): Promise<PrepareResult> {
  const composer = COMPOSERS[params.network];
  if (!composer) throw new Error(`Red no soportada: ${params.network}`);
  if (composer.requiresMedia && params.media.length === 0) throw new Error(`${composer.name} necesita al menos una imagen.`);
  const startUrl = params.start_url ?? composer.startUrl;
  const manual = (message: string): PrepareResult => ({ mode: "manual", message, url: page.url() === "about:blank" ? startUrl : page.url() });

  try {
    await page.goto(startUrl, { waitUntil: "domcontentloaded" });
  } catch (err) {
    return manual(`No pude abrir ${composer.name}: ${(err as Error).message}`);
  }
  await page.bringToFront().catch(() => {});
  if (composer.loginPatterns.some((p) => p.test(page.url()))) {
    return manual(`Inicia sesión en ${composer.name} en la ventana de Frontbot y vuelve a intentar.`);
  }
  try {
    await runSteps(page, composer.steps, { body: params.body, media: params.media }, opts);
  } catch (err) {
    if (err instanceof StepError) {
      return manual(`No pude completar el paso "${err.step}". Pega el texto (ya está en el portapapeles) y sube las imágenes a mano.`);
    }
    return manual(`Algo falló al preparar ${composer.name}: ${(err as Error).message}`);
  }
  return { mode: "composer", message: "Listo: revisa el post en la ventana de Chrome de Frontbot y publícalo o prográmalo tú.", url: page.url() };
}
```

Nota: el test de Instagram (`fixture` con `aria-label="Nueva publicación"` en un `<a>`) y el `<button>Compartir</button>` del fixture comprueban que el flujo se detiene sin pulsar Compartir. Quitar la línea `await page.exposeFunction("noop", () => {});` del test si molesta; no es necesaria.

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd agent && npx vitest run test/browser && npm run typecheck`
Expected: PASS (steps 5 + prepare 6).

- [ ] **Step 5: Commit**

```bash
git add agent/src/browser agent/test/browser
git commit -m "feat: add Instagram and LinkedIn composers with manual fallback"
```

---

### Task 3: Sesión de Chrome y métodos RPC `publish.*` en el sidecar

**Files:**
- Create: `agent/src/browser/session.ts`
- Modify: `agent/src/main.ts`
- Test: `agent/test/publish.test.ts`

**Interfaces:**
- Consumes: `preparePost`, `COMPOSERS`, `PrepareParams`, `PrepareResult` (Task 2); `RpcPeer`, `startServer` (Fase 1).
- Produces:
  - `interface Publisher { prepare(params: PrepareParams & { profile_dir: string }): Promise<PrepareResult>; login(params: { network: Network; profile_dir: string }): Promise<{ ok: true }> }`
  - `class ChromePublisher implements Publisher` — mantiene un `BrowserContext` persistente (`chromium.launchPersistentContext(profile_dir, { channel: "chrome", headless: false, viewport: null })`); lo relanza si se cerró; cada `prepare` abre una página nueva.
  - `class FakePublisher implements Publisher` — `prepare` devuelve `{ mode: "composer", message: "(prueba) compositor listo", url: COMPOSERS[network].startUrl }`; si `body === "manual"` devuelve `mode: "manual"`; si `body === "falla"` lanza `Error("Chrome no está disponible")`; si `body === "lento"` espera 5 s antes de responder. `login` devuelve `{ ok: true }`.
  - `startServer(peer, runner, publisher?: Publisher)` registra `publish.prepare` y `publish.login` (requests; los errores viajan como error RPC). `main.ts` usa `FakePublisher` si `FRONTBOT_FAKE_AGENT=1`, si no `ChromePublisher`.

- [ ] **Step 1: Escribir el test que falla** `agent/test/publish.test.ts`:

```ts
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
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd agent && npx vitest run test/publish.test.ts`
Expected: FAIL — `Cannot find module '../src/browser/session.js'`.

- [ ] **Step 3: Implementar** `agent/src/browser/session.ts`:

```ts
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
```

En `agent/src/main.ts`:
- Imports: `import { ChromePublisher, FakePublisher, type Publisher } from "./browser/session.js";`
- Firma: `export function startServer(peer: RpcPeer, runner: Runner, publisher?: Publisher) {`
- Al final de `startServer`:
```ts
  if (publisher) {
    peer.onRequest("publish.prepare", (params) => publisher.prepare(params));
    peer.onRequest("publish.login", (params) => publisher.login(params));
  }
```
- En el bloque de arranque: `const fake = process.env.FRONTBOT_FAKE_AGENT === "1";` y `startServer(peer, runner, fake ? new FakePublisher() : new ChromePublisher());` (y `runner` usa `fake`).

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd agent && npx vitest run && npm run typecheck && npm run build`
Expected: PASS (toda la suite TS, +3).

- [ ] **Step 5: Commit**

```bash
git add agent/src agent/test
git commit -m "feat: expose publish.prepare and publish.login from the sidecar"
```

---

### Task 4: `PublishingService` en Swift (estados y validaciones)

**Files:**
- Create: `app/Sources/FrontbotCore/Publishing/PublishingService.swift`
- Modify: `app/Sources/FrontbotCore/Store/Repositories.swift` (`markPublished`)
- Test: `app/Tests/FrontbotCoreTests/PublishingServiceTests.swift`

**Interfaces:**
- Consumes: `transitionPost`, `asset(id:)`, `PostStateMachine` (Fases 1–2).
- Produces:
  - `struct PreparationResult: Equatable, Sendable { enum Mode: String, Sendable { case composer, manual }; let mode: Mode; let message: String; let url: String }`
  - `protocol PublicationPreparer: Sendable { func preparePublication(network: Network, body: String, mediaPaths: [String]) async throws -> PreparationResult; func openLogin(network: Network) async throws }`
  - `AppDatabase.markPublished(id: String, url: String?) throws -> Post` — transición de usuario a `published` (desde `preparing` o `scheduled`) y guarda `publishedUrl`; URL vacía = nil; URL sin `http(s)://` → `"La URL debe empezar con https://."`.
  - `struct PublishingService: Sendable { init(db: AppDatabase, preparer: any PublicationPreparer); func prepare(postId: String) async throws -> (Post, PreparationResult); func confirmPublished(postId: String, url: String?) throws -> Post; func confirmScheduled(postId: String) throws -> Post; func cancelPreparation(postId: String) throws -> Post }`
  - `prepare`: post en `approved` o `"Solo se pueden preparar posts aprobados."`; Instagram sin media → `"Instagram necesita al menos una imagen."`; resuelve rutas absolutas de media; pasa a `preparing`; llama al preparer; si lanza, vuelve a `approved` y relanza.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class FakePreparer: PublicationPreparer, @unchecked Sendable {
    var calls: [(Network, String, [String])] = []
    var result = PreparationResult(mode: .composer, message: "ok", url: "https://www.instagram.com/")
    var error: Error?

    func preparePublication(network: Network, body: String, mediaPaths: [String]) async throws -> PreparationResult {
        calls.append((network, body, mediaPaths))
        if let error { throw error }
        return result
    }

    func openLogin(network: Network) async throws {}
}

final class PublishingServiceTests: XCTestCase {
    var db: AppDatabase!
    var brand: Brand!
    var image: BrandAsset!
    var root: URL!
    var preparer: FakePreparer!
    var service: PublishingService!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        brand = try db.createBrand(workspaceId: ws.id, name: "B", industry: "", networks: [.instagram, .linkedin])
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = root.appendingPathComponent("x.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        image = try AssetImporter(db: db, paths: AppPaths(root: root)).importImage(from: png, brandId: brand.id)
        preparer = FakePreparer()
        service = PublishingService(db: db, preparer: preparer)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func approved(_ network: Network, media: [String]) throws -> Post {
        let p = try db.createDraft(brandId: brand.id, network: network, body: "hola", media: media, scheduledFor: nil)
        return try db.transitionPost(id: p.id, to: .approved, actor: .user)
    }

    func testPrepareMovesToPreparingAndPassesAbsolutePaths() async throws {
        let post = try approved(.instagram, media: [image.id])
        let (updated, result) = try await service.prepare(postId: post.id)
        XCTAssertEqual(updated.status, .preparing)
        XCTAssertEqual(result.mode, .composer)
        XCTAssertEqual(preparer.calls.first?.2, [image.path])
        XCTAssertEqual(preparer.calls.first?.1, "hola")
    }

    func testRejectsDraftAndInstagramWithoutImages() async throws {
        let draft = try db.createDraft(brandId: brand.id, network: .linkedin, body: "hola", media: [], scheduledFor: nil)
        do { _ = try await service.prepare(postId: draft.id); XCTFail() } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Solo se pueden preparar posts aprobados.")
        }
        let ig = try approved(.instagram, media: [])
        do { _ = try await service.prepare(postId: ig.id); XCTFail() } catch let e as ValidationError {
            XCTAssertEqual(e.message, "Instagram necesita al menos una imagen.")
        }
        XCTAssertTrue(preparer.calls.isEmpty)
    }

    func testPreparerFailureRevertsToApproved() async throws {
        preparer.error = ValidationError("Chrome no está disponible")
        let post = try approved(.linkedin, media: [])
        do { _ = try await service.prepare(postId: post.id); XCTFail() } catch {}
        XCTAssertEqual(try db.posts(brandId: brand.id, status: nil).first { $0.id == post.id }?.status, .approved)
    }

    func testConfirmPublishedWithUrlAndValidation() async throws {
        let post = try approved(.linkedin, media: [])
        _ = try await service.prepare(postId: post.id)
        XCTAssertThrowsError(try service.confirmPublished(postId: post.id, url: "linkedin.com/x")) { error in
            XCTAssertEqual((error as? ValidationError)?.message, "La URL debe empezar con https://.")
        }
        let done = try service.confirmPublished(postId: post.id, url: " https://www.linkedin.com/feed/update/1 ")
        XCTAssertEqual(done.status, .published)
        XCTAssertEqual(done.publishedUrl, "https://www.linkedin.com/feed/update/1")
    }

    func testScheduledThenPublishedWithoutUrl() async throws {
        let post = try approved(.linkedin, media: [])
        _ = try await service.prepare(postId: post.id)
        XCTAssertEqual(try service.confirmScheduled(postId: post.id).status, .scheduled)
        let done = try service.confirmPublished(postId: post.id, url: "")
        XCTAssertEqual(done.status, .published)
        XCTAssertNil(done.publishedUrl)
    }

    func testCancelPreparationReturnsToApproved() async throws {
        let post = try approved(.linkedin, media: [])
        _ = try await service.prepare(postId: post.id)
        XCTAssertEqual(try service.cancelPreparation(postId: post.id).status, .approved)
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd app && swift test --filter PublishingServiceTests`
Expected: FAIL — `cannot find type 'PublicationPreparer' in scope`.

- [ ] **Step 3: Implementar**

En `Repositories.swift` (sección Posts):
```swift
    public func markPublished(id: String, url: String?) throws -> Post {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let clean, !(clean.hasPrefix("https://") || clean.hasPrefix("http://")) {
            throw ValidationError("La URL debe empezar con https://.")
        }
        return try writer.write { db in
            guard var post = try Post.fetchOne(db, key: id) else { throw notFound("post", id) }
            try PostStateMachine.checkTransition(from: post.status, to: .published, actor: .user)
            post.status = .published
            post.publishedUrl = clean
            post.updatedAt = .dbNow()
            try post.update(db)
            return post
        }
    }
```

`app/Sources/FrontbotCore/Publishing/PublishingService.swift`:
```swift
import Foundation

public struct PreparationResult: Equatable, Sendable {
    public enum Mode: String, Sendable { case composer, manual }
    public let mode: Mode
    public let message: String
    public let url: String

    public init(mode: Mode, message: String, url: String) {
        self.mode = mode
        self.message = message
        self.url = url
    }
}

/// Quien abre el navegador y rellena el compositor (el sidecar vía `AgentClient`).
public protocol PublicationPreparer: Sendable {
    func preparePublication(network: Network, body: String, mediaPaths: [String]) async throws -> PreparationResult
    func openLogin(network: Network) async throws
}

/// Publicación asistida: Frontbot deja el post listo en la red; publicar lo hace siempre el usuario.
public struct PublishingService: Sendable {
    let db: AppDatabase
    let preparer: any PublicationPreparer

    public init(db: AppDatabase, preparer: any PublicationPreparer) {
        self.db = db
        self.preparer = preparer
    }

    public func prepare(postId: String) async throws -> (Post, PreparationResult) {
        guard let post = try db.posts(brandId: nil, status: nil).first(where: { $0.id == postId }) else {
            throw ValidationError("No existe post con id \(postId).")
        }
        guard post.status == .approved else { throw ValidationError("Solo se pueden preparar posts aprobados.") }
        if post.network == .instagram && post.media.isEmpty { throw ValidationError("Instagram necesita al menos una imagen.") }
        let paths = try post.media.map { id -> String in
            guard let asset = try db.asset(id: id) else { throw ValidationError("La imagen \(id) ya no existe.") }
            return asset.path
        }
        let preparing = try db.transitionPost(id: post.id, to: .preparing, actor: .user)
        do {
            let result = try await preparer.preparePublication(network: post.network, body: post.body, mediaPaths: paths)
            return (preparing, result)
        } catch {
            _ = try? db.transitionPost(id: post.id, to: .approved, actor: .user)
            throw error
        }
    }

    public func confirmPublished(postId: String, url: String?) throws -> Post {
        try db.markPublished(id: postId, url: url)
    }

    public func confirmScheduled(postId: String) throws -> Post {
        try db.transitionPost(id: postId, to: .scheduled, actor: .user)
    }

    public func cancelPreparation(postId: String) throws -> Post {
        try db.transitionPost(id: postId, to: .approved, actor: .user)
    }
}
```

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd app && swift test --filter PublishingServiceTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat: add publishing service for assisted publication states"
```

---

### Task 5: `AgentClient` — llamadas con respuesta y `PublicationPreparer`

**Files:**
- Modify: `app/Sources/FrontbotCore/Agent/AgentClient.swift`, `app/Sources/FrontbotCore/Store/AppPaths.swift`
- Test: `app/Tests/FrontbotCoreTests/AgentClientCallTests.swift`

**Interfaces:**
- Consumes: `PublicationPreparer`, `PreparationResult` (Task 4); `publish.prepare` / `publish.login` y `FakePublisher` (Task 3).
- Produces:
  - `AppPaths.browserProfile: URL` = `root/browser-profile/`.
  - `AgentConfig` gana `browserProfileDir: String` (último parámetro del init, por defecto `""`).
  - `AgentClientError` gana `.remote(String)` (mensaje = el del error remoto) y `.timeout` ("El agente no respondió a tiempo.").
  - `AgentClient.call(_ method: String, params: JSONValue, timeout: Duration = .seconds(120)) async throws -> JSONValue` — arranca el proceso si hace falta (no exige API key), guarda una continuación por id, la resuelve con `.response`, `.error` (→ `.remote`), timeout (→ `.timeout`) o salida del proceso (→ `.remote("El agente se detuvo inesperadamente.")`).
  - `extension AgentClient: PublicationPreparer` — `preparePublication` llama `publish.prepare` con `{network, body, media, profile_dir}` y parsea `PreparationResult`; `openLogin` llama `publish.login`.

- [ ] **Step 1: Escribir el test que falla**

```swift
import XCTest
@testable import FrontbotCore

final class AgentClientCallTests: XCTestCase {
    func makeClient() throws -> AgentClient {
        let db = try AppDatabase.inMemory()
        let ws = try db.ensureDefaultWorkspace()
        let node = ProcessInfo.processInfo.environment["FRONTBOT_NODE"] ?? "/opt/homebrew/bin/node"
        let script = AgentClientTests.repoRoot.appendingPathComponent("agent/dist/main.js").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: node), "usa FRONTBOT_NODE=$(which node)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = AgentConfig(nodePath: node, scriptPath: script, apiKey: nil, model: "m", fakeAgent: true, browserProfileDir: root.path)
        return AgentClient(config: config, db: db, files: BrandFiles(paths: AppPaths(root: root)), workspaceId: ws.id)
    }

    func testPreparePublicationWithoutApiKey() async throws {
        let client = try makeClient()
        let result = try await client.preparePublication(network: .linkedin, body: "hola", mediaPaths: [])
        XCTAssertEqual(result, PreparationResult(mode: .composer, message: "(prueba) compositor listo", url: "https://www.linkedin.com/feed/"))
        await client.stop()
    }

    func testRemoteErrorsPropagate() async throws {
        let client = try makeClient()
        do {
            _ = try await client.preparePublication(network: .linkedin, body: "falla", mediaPaths: [])
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("Chrome no está disponible"))
            XCTAssertEqual(error.localizedDescription, "Chrome no está disponible")
        }
        await client.stop()
    }

    func testUnknownMethodReturnsRemoteError() async throws {
        let client = try makeClient()
        do {
            _ = try await client.call("no.existe", params: [:], timeout: .seconds(5))
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("Método desconocido: no.existe"))
        }
        await client.stop()
    }

    func testCallTimesOut() async throws {
        let client = try makeClient()
        let params: JSONValue = ["network": "linkedin", "body": "lento", "media": [], "profile_dir": "/tmp/x"]
        do {
            _ = try await client.call("publish.prepare", params: params, timeout: .milliseconds(300))
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .timeout)
            XCTAssertEqual(error.localizedDescription, "El agente no respondió a tiempo.")
        }
        await client.stop()
    }

    func testPendingCallFailsWhenSidecarStops() async throws {
        let client = try makeClient()
        let params: JSONValue = ["network": "linkedin", "body": "lento", "media": [], "profile_dir": "/tmp/x"]
        async let pending = client.call("publish.prepare", params: params, timeout: .seconds(30))
        try await Task.sleep(for: .milliseconds(500)) // la llamada ya está en vuelo
        await client.stop()
        do {
            _ = try await pending
            XCTFail("debió fallar")
        } catch let error as AgentClientError {
            XCTAssertEqual(error, .remote("El agente se detuvo inesperadamente."))
        }
    }
}
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd agent && npm run build && cd ../app && FRONTBOT_NODE=$(which node) swift test --filter AgentClientCallTests`
Expected: FAIL — `extra argument 'browserProfileDir' in call` / `has no member 'preparePublication'`.

- [ ] **Step 3: Implementar**

`AppPaths.swift`: `public var browserProfile: URL { root.appendingPathComponent("browser-profile", isDirectory: true) }`

En `AgentClient.swift`:
- `AgentConfig`: añadir `public var browserProfileDir: String` y el parámetro `browserProfileDir: String = ""` al final del init.
- `AgentClientError`: añadir `case remote(String)` y `case timeout`, con descripciones `why` y `"El agente no respondió a tiempo."`.
- Estado: `private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]`.
- Método:
```swift
    public func call(_ method: String, params: JSONValue, timeout: Duration = .seconds(120)) async throws -> JSONValue {
        try ensureProcess()
        let id = takeId()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.request(id: id, method: method, params: params))
            } catch {
                resolve(id, with: .failure(error))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolve(id, with: .failure(AgentClientError.timeout))
            }
        }
    }

    private func resolve(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }
```
- En `handle(_:)`, añadir antes de `default`:
```swift
        case .response(let id, let result):
            resolve(id, with: .success(result))
        case .error(let id, _, let message):
            resolve(id, with: .failure(AgentClientError.remote(message)))
```
- En `handleExit()`, además de fallar los runs: `for id in Array(pending.keys) { resolve(id, with: .failure(AgentClientError.remote("El agente se detuvo inesperadamente."))) }`.
- Conformidad (al final del archivo):
```swift
extension AgentClient: PublicationPreparer {
    public func preparePublication(network: Network, body: String, mediaPaths: [String]) async throws -> PreparationResult {
        let result = try await call("publish.prepare", params: [
            "network": .string(network.rawValue), "body": .string(body),
            "media": .array(mediaPaths.map(JSONValue.string)), "profile_dir": .string(config.browserProfileDir),
        ])
        guard let mode = result["mode"]?.stringValue.flatMap(PreparationResult.Mode.init(rawValue:)) else {
            throw AgentClientError.remote("Respuesta inválida del agente.")
        }
        return PreparationResult(mode: mode, message: result["message"]?.stringValue ?? "", url: result["url"]?.stringValue ?? "")
    }

    public func openLogin(network: Network) async throws {
        _ = try await call("publish.login", params: ["network": .string(network.rawValue), "profile_dir": .string(config.browserProfileDir)])
    }
}
```
Nota: `stop()` llama a `handleExit()`, que también resuelve las llamadas pendientes; por eso `testPendingCallFailsWhenSidecarStops` es determinista.

- [ ] **Step 4: Correr y verificar que pasa**

Run: `cd agent && npm run build && cd ../app && FRONTBOT_NODE=$(which node) swift test`
Expected: PASS — toda la suite Swift.

- [ ] **Step 5: Commit**

```bash
git add app agent/src
git commit -m "feat: add request/response calls to the agent client for publishing"
```

---

### Task 6: UI — preparar, confirmar, modo manual e inicio de sesión

**Files:**
- Modify: `app/Sources/FrontbotApp/AppModel.swift`, `PostEditorView.swift`, `SettingsView.swift`

**Interfaces:**
- Consumes: `PublishingService`, `PreparationResult`, `AgentClient` como `PublicationPreparer`, `AppPaths.browserProfile`.
- `AppModel` gana:
  - `var preparingPostId: String?`, `var preparationMessage: String?`
  - `func preparePublication(_ post: Post)` — llama al servicio; si el resultado es `manual`, copia el texto al portapapeles (`NSPasteboard`) y muestra las imágenes en Finder (`NSWorkspace.shared.activateFileViewerSelecting`); guarda el mensaje; errores a `errorMessage`.
  - `func confirmPublished(_ post: Post, url: String)`, `func confirmScheduled(_ post: Post)`, `func cancelPreparation(_ post: Post)`, `func openLogin(_ network: Network)`
  - `makeConfig` pasa `browserProfileDir: AppPaths.standard().browserProfile.path`.
- `PostEditorView` lee el post **actual** desde `model.posts` (no el valor capturado al abrir la hoja), para que los botones sigan el estado.

- [ ] **Step 1: `AppModel`** — añadir `import AppKit` y:

```swift
    var preparingPostId: String?
    var preparationMessage: String?
    private var publishing: PublishingService { PublishingService(db: db, preparer: client) }

    func preparePublication(_ post: Post) {
        preparingPostId = post.id
        preparationMessage = nil
        Task {
            defer { preparingPostId = nil }
            do {
                let (_, result) = try await publishing.prepare(postId: post.id)
                if result.mode == .manual {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(post.body, forType: .string)
                    let files = post.media.compactMap { try? db.asset(id: $0)?.path }.map { URL(fileURLWithPath: $0) }
                    if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
                }
                preparationMessage = result.message
            } catch let e as ValidationError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
            reloadContent()
        }
    }

    func confirmPublished(_ post: Post, url: String) {
        perform { _ = try publishing.confirmPublished(postId: post.id, url: url) }
        preparationMessage = nil
        reloadContent()
    }

    func confirmScheduled(_ post: Post) {
        perform { _ = try publishing.confirmScheduled(postId: post.id) }
        preparationMessage = nil
        reloadContent()
    }

    func cancelPreparation(_ post: Post) {
        perform { _ = try publishing.cancelPreparation(postId: post.id) }
        preparationMessage = nil
        reloadContent()
    }

    func openLogin(_ network: Network) {
        Task {
            do { try await client.openLogin(network: network) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func currentPost(_ id: String) -> Post? { posts.first { $0.id == id } }
```

En `makeConfig`, añadir el argumento final `browserProfileDir: AppPaths.standard().browserProfile.path`.

- [ ] **Step 2: `PostEditorView`** — usar el post actual y añadir la sección de publicación.

- Añadir `@State private var publishedUrl = ""` y `private var current: Post { model.currentPost(post.id) ?? post }`.
- Reemplazar todos los usos de `post.status` en `body`, `editable` y `statusLabel` por `current.status`.
- Debajo del `DatePicker`, añadir:
```swift
            if current.status == .approved {
                Divider()
                Button(model.preparingPostId == post.id ? "Preparando…" : "Preparar publicación en \(post.network == .instagram ? "Instagram" : "LinkedIn")") {
                    model.preparePublication(current)
                }
                .disabled(model.preparingPostId != nil)
            }
            if current.status == .preparing || current.status == .scheduled {
                Divider()
                if let message = model.preparationMessage { Text(message).font(.callout) }
                Text(current.status == .preparing
                     ? "Publica o programa el post en la ventana de Chrome y confírmalo aquí."
                     : "Programado en la red. Confírmalo cuando se publique.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("URL del post publicado (opcional)", text: $publishedUrl)
                HStack {
                    Button("Ya se publicó") { model.confirmPublished(current, url: publishedUrl) }
                    if current.status == .preparing {
                        Button("Lo programé en la red") { model.confirmScheduled(current) }
                        Spacer()
                        Button("Cancelar preparación") { model.cancelPreparation(current) }
                    }
                }
            }
            if current.status == .published, let url = current.publishedUrl, let link = URL(string: url) {
                Link("Ver publicación", destination: link)
            }
```

- [ ] **Step 3: `SettingsView`** — tras el botón Guardar:
```swift
            Divider()
            Text("Redes (inicia sesión una vez en la ventana de Chrome de Frontbot)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Abrir Instagram") { model.openLogin(.instagram) }
                Button("Abrir LinkedIn") { model.openLogin(.linkedin) }
            }
```

- [ ] **Step 4: Compilar, suite y arranque de humo**

Run: `cd app && swift build && FRONTBOT_NODE=$(which node) swift test`
Expected: compila sin errores; suite verde.

- [ ] **Step 5: Verificación manual**

Con el agente falso (sin red):
```bash
cd agent && npm run build && cd ../app
FRONTBOT_FAKE_AGENT=1 FRONTBOT_NODE=$(which node) FRONTBOT_AGENT_SCRIPT=$(cd ../agent && pwd)/dist/main.js swift run FrontbotApp
```
- [ ] Aprobar un post de LinkedIn → "Preparar publicación" → mensaje "(prueba) compositor listo" y estado Preparando (punto azul en el calendario).
- [ ] "Lo programé en la red" → Programado; "Ya se publicó" con URL `https://…` → Publicado y enlace "Ver publicación".
- [ ] Con texto `manual`: el texto queda en el portapapeles y Finder muestra las imágenes.
- [ ] Con texto `falla`: alerta "Chrome no está disponible" y el post vuelve a Aprobado.
- [ ] Un post de Instagram sin imágenes: "Instagram necesita al menos una imagen."

Con Chrome real (sin `FRONTBOT_FAKE_AGENT`, requiere API key guardada solo para el chat; publicar no la necesita):
- [ ] Ajustes › "Abrir Instagram" / "Abrir LinkedIn": se abre una ventana de Chrome **separada** de la personal; iniciar sesión.
- [ ] Preparar un post de LinkedIn con texto e imagen: queda el compositor con ambos, **sin publicar**.
- [ ] Preparar un post de Instagram con imagen: llega al pie de foto con el texto, **sin compartir**.
- [ ] Si algún paso falla, el mensaje nombra el paso; anotar cuál para actualizar `agent/src/browser/composers.ts`.

- [ ] **Step 6: Commit**

```bash
git add app
git commit -m "feat: prepare, confirm and fall back to manual publishing from the post editor"
```

---

## Self-review

- **Cobertura del spec (Fase 3):** perfil dedicado y login una vez (7 → Tasks 3, 6), compositor con texto e imágenes que se detiene antes de publicar (7 → Tasks 1–2), clic final del usuario y confirmación publicado/programado con URL opcional (4.1, 7 → Tasks 4, 6), modo manual con portapapeles + Finder (7, 8 → Tasks 2, 6), `PublishingProvider` como interfaz (3.1 → `PublicationPreparer`, Task 4), errores (8 → Tasks 2, 4, 5).
- **Nombres consistentes:** `publish.prepare`/`publish.login` con `{network, body, media, profile_dir}` iguales en TS (Task 3) y Swift (Task 5); `PreparationResult.Mode` = `"composer" | "manual"` en ambos lados; `FakePublisher` responde `"(prueba) compositor listo"` en Tasks 3 y 5.
- **Límite conocido:** los selectores reales de Instagram y LinkedIn no se pueden probar automáticamente; están aislados en `composers.ts` y el modo manual cubre su rotura.

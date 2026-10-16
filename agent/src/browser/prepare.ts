import type { Page } from "playwright-core";
import { COMPOSERS, type Composer, type Network } from "./composers.js";
import { runSteps, StepError } from "./steps.js";

export type PrepareParams = { network: Network; body: string; media: string[]; start_url?: string };
export type PrepareResult = { mode: "composer" | "manual"; message: string; url: string };
export type PrepareOptions = { timeoutMs?: number; optionalTimeoutMs?: number; deadlineMs?: number };

const MANUAL_HINT = "Pega el texto (ya está en el portapapeles) y sube las imágenes a mano.";

/**
 * ¿La página pide iniciar sesión? Gana lo que aparezca antes: un formulario de login
 * o el primer elemento del compositor. Sin ninguno de los dos, se asume que no.
 */
async function needsLogin(page: Page, composer: Composer, timeoutMs: number): Promise<boolean> {
  if (composer.loginPatterns.some((p) => p.test(page.url()))) return true;
  const first = composer.steps.find((s) => !s.optional && !s.onlyIfMedia)?.candidates ?? [];
  const deadline = Date.now() + timeoutMs;
  do {
    for (const sel of composer.loginSelectors) {
      if ((await page.locator(sel).count().catch(() => 0)) > 0) return true;
    }
    for (const sel of first) {
      if ((await page.locator(sel).filter({ visible: true }).count().catch(() => 0)) > 0) return false;
    }
    await page.waitForTimeout(150);
  } while (Date.now() < deadline);
  return false;
}

/** Abre el compositor de la red y lo rellena. Se detiene antes de publicar. */
export async function preparePost(page: Page, params: PrepareParams, opts: PrepareOptions = {}): Promise<PrepareResult> {
  const composer = COMPOSERS[params.network];
  if (!composer) throw new Error(`Red no soportada: ${params.network}`);
  if (composer.requiresMedia && params.media.length === 0) throw new Error(`${composer.name} necesita al menos una imagen.`);
  const timeoutMs = opts.timeoutMs ?? 8000;
  // Muy por debajo de los 120 s que espera la app, para que nunca responda tarde.
  const deadlineMs = opts.deadlineMs ?? 90_000;
  const startUrl = params.start_url ?? composer.startUrl;
  const manual = (message: string): PrepareResult => ({ mode: "manual", message, url: page.url() === "about:blank" ? startUrl : page.url() });

  const work = async (): Promise<PrepareResult> => {
    try {
      await page.goto(startUrl, { waitUntil: "domcontentloaded", timeout: Math.min(30_000, deadlineMs) });
    } catch (err) {
      return manual(`No pude abrir ${composer.name}: ${(err as Error).message.split("\n")[0]}`);
    }
    await page.bringToFront().catch(() => {});
    if (await needsLogin(page, composer, Math.min(3000, timeoutMs))) {
      return manual(`Inicia sesión en ${composer.name} en la ventana de Frontbot y vuelve a intentar.`);
    }
    try {
      await runSteps(page, composer.steps, { body: params.body, media: params.media }, opts);
    } catch (err) {
      if (err instanceof StepError) return manual(`No pude completar el paso "${err.step}". ${MANUAL_HINT}`);
      return manual(`Algo falló al preparar ${composer.name}: ${(err as Error).message.split("\n")[0]}`);
    }
    return { mode: "composer", message: "Listo: revisa el post en la ventana de Chrome de Frontbot y publícalo o prográmalo tú.", url: page.url() };
  };

  let timer: NodeJS.Timeout | undefined;
  const late = new Promise<PrepareResult>((resolve) => {
    timer = setTimeout(() => resolve(manual(`${composer.name} tardó demasiado. ${MANUAL_HINT}`)), deadlineMs);
  });
  const running = work();
  running.catch(() => {}); // si gana el plazo, el trabajo restante se descarta sin rechazos sueltos
  try {
    return await Promise.race([running, late]);
  } finally {
    clearTimeout(timer);
  }
}

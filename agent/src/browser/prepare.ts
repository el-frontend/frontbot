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

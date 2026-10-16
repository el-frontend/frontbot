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
      // click/fill: solo elementos visibles (las redes dejan botones duplicados ocultos en el DOM).
      // upload: los input[type=file] suelen estar ocultos, basta con que existan.
      const loc = step.kind === "upload"
        ? page.locator(selector).first()
        : page.locator(selector).filter({ visible: true }).first();
      const ok = (await loc.count().catch(() => 0)) > 0;
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
    try {
      // Mismo límite que la búsqueda: sin él, Playwright espera 30 s (p. ej. si un aviso tapa el botón).
      if (step.kind === "click") await loc.click({ timeout: timeoutMs });
      if (step.kind === "upload") await loc.setInputFiles(input.media, { timeout: timeoutMs });
      if (step.kind === "fill") {
        await loc.click({ timeout: timeoutMs });
        await page.keyboard.insertText(input.body);
      }
    } catch {
      throw new StepError(step.label);
    }
  }
}

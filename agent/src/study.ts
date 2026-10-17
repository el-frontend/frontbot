// Sesión de estudio del laboratorio: prompt, subagentes y medidor de tokens.
import type { AgentDefinition } from "@anthropic-ai/claude-agent-sdk";
import type { RunStudy } from "./lab.js";

export type Usage = { input_tokens?: number; output_tokens?: number; cache_creation_input_tokens?: number; cache_read_input_tokens?: number };

/** input + cache_creation + output + 0,1 × cache_read, redondeado hacia abajo. */
export const countTokens = (u: Usage): number =>
  Math.floor((u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.output_tokens ?? 0) + 0.1 * (u.cache_read_input_tokens ?? 0));

export class TokenMeter {
  // Un mensaje del asistente llega en varios frames con el mismo message.id (uno por bloque, stop_reason null,
  // uso parcial): se guarda el último uso por id, sin duplicar. Los subagentes cuentan igual.
  private byId = new Map<string, { model: string; usage: Usage }>();
  private reconciled: Map<string, number> | undefined;
  private anon = 0;
  constructor(private budget: number) {}

  add(model: string, usage: Usage, id?: string) {
    const key = id ?? `anon-${this.anon++}`;
    const prev = this.byId.get(key)?.usage;
    const max = (k: keyof Usage) => Math.max(prev?.[k] ?? 0, usage[k] ?? 0);
    this.byId.set(key, { model, usage: { input_tokens: max("input_tokens"), output_tokens: max("output_tokens"), cache_creation_input_tokens: max("cache_creation_input_tokens"), cache_read_input_tokens: max("cache_read_input_tokens") } });
  }

  consume(msg: { type?: string; message?: { id?: string; model?: string; usage?: Usage } }) {
    if (msg.type !== "assistant" || !msg.message?.usage) return;
    this.add(msg.message.model ?? "desconocido", msg.message.usage, msg.message.id);
  }

  /** El mensaje `result` trae el uso total por modelo (con subagentes): sustituye la cuenta parcial. */
  reconcile(modelUsage: Record<string, { inputTokens?: number; outputTokens?: number; cacheReadInputTokens?: number; cacheCreationInputTokens?: number }> | undefined) {
    if (!modelUsage || Object.keys(modelUsage).length === 0) return;
    this.reconciled = new Map(Object.entries(modelUsage).map(([m, u]) => [m, countTokens({ input_tokens: u.inputTokens, output_tokens: u.outputTokens, cache_creation_input_tokens: u.cacheCreationInputTokens, cache_read_input_tokens: u.cacheReadInputTokens })]));
  }

  get total(): number { let t = 0; for (const v of this.perModel().values()) t += v; return t; }
  get warned(): boolean { return this.total >= this.budget * 0.85; }
  get exhausted(): boolean { return this.total >= this.budget; }
  get inputTokens(): number { let t = 0; for (const e of this.byId.values()) t += e.usage.input_tokens ?? 0; return t; }
  get outputTokens(): number { let t = 0; for (const e of this.byId.values()) t += e.usage.output_tokens ?? 0; return t; }
  byModel(): { model: string; tokens: number }[] { return [...this.perModel()].map(([model, tokens]) => ({ model, tokens })); }

  private perModel(): Map<string, number> {
    if (this.reconciled) return this.reconciled;
    const out = new Map<string, number>();
    for (const e of this.byId.values()) out.set(e.model, (out.get(e.model) ?? 0) + countTokens(e.usage));
    return out;
  }
}

export const STUDY_WARNING = "Te queda poco presupuesto de tokens en esta sesión: anota lo que tengas y llama a lab_end_session.";

const SUBAGENT_TOOLS = ["WebSearch", "WebFetch", ...["lab_read_file", "lab_list_files", "lab_run", "lab_note", "lab_list_datasets"].map((t) => `mcp__frontbot__${t}`)];

export function studyAgents(allowOpus: boolean): Record<string, AgentDefinition> {
  return {
    ayudante: {
      description: "Tareas mecánicas y baratas: descargar y ordenar datos, ejecutar y resumir pruebas, formatear notas, clasificar ejemplos.",
      prompt: "Eres el ayudante de un agente que estudia un tema. Haz solo la tarea concreta que te piden, sin inventar datos, y devuelve un resumen corto con lo que encontraste y dónde quedó cada archivo.",
      tools: SUBAGENT_TOOLS, model: "haiku",
    },
    analista: {
      description: "Un segundo razonamiento acotado: revisar un resultado, buscar fallos en una prueba o comparar explicaciones.",
      prompt: "Eres el analista de un agente que estudia un tema. Razona con cuidado sobre lo que te piden, señala supuestos y fallos posibles y di qué tan fuerte es la evidencia. Responde breve.",
      tools: SUBAGENT_TOOLS, model: "sonnet",
    },
    ...(allowOpus ? { experto: {
      description: "Consulta experta con Opus: solo una consulta por sesión y solo si Sonnet ya falló.",
      prompt: "Eres un experto al que se consulta una sola vez en una sesión de estudio, porque el análisis anterior no bastó. Da la mejor respuesta razonada que puedas, con sus límites.",
      tools: SUBAGENT_TOOLS, model: "opus",
    } } : {}),
  };
}

const text = (v: unknown) => typeof v === "string" ? v : JSON.stringify(v, null, 2);

export function buildStudyPrompt(study: RunStudy, agent: { name: string }): string {
  const nb = study.notebook as { model_notes?: unknown[] } | null | undefined;
  const modelNotes = Array.isArray(nb?.model_notes) ? nb.model_notes : [];
  return [
    `Sesión de estudio del laboratorio de ${agent.name}.`,
    "",
    `Pregunta: ${study.question}`,
    `Por qué importa: ${study.why}`,
    "",
    "Cuaderno del tema:",
    text(study.notebook ?? "(vacío)"),
    "",
    "Notas sobre modelos (de todos tus temas):",
    modelNotes.length ? modelNotes.map((n) => `- ${text(n)}`).join("\n") : "(ninguna)",
    "",
    "Reglas:",
    "- Nadie está mirando: no pidas aclaraciones, decide tú.",
    "- Anota en el cuaderno (lab_note) mientras trabajas, no al final.",
    "- Cada conclusión lleva evidencia (evidence: weak, medium o strong) y sus fuentes.",
    "- Termina siempre llamando a lab_end_session(outcome, summary, conclusion?).",
    "- Nunca actúas sobre cuentas reales: aquí solo estudias, no operas ni publicas.",
    "",
    "Cuándo delegar:",
    "- ayudante (Haiku): descargar y ordenar datos, ejecutar y resumir pruebas, formatear notas, clasificar ejemplos.",
    "- analista (Sonnet): un segundo razonamiento acotado sobre un resultado dudoso.",
    ...(study.allow_opus ? ["- experto (Opus): una sola consulta por sesión y solo si Sonnet ya falló."] : []),
    "- Si un modelo se quedó corto o sobró, regístralo con lab_note de kind model_note.",
    "",
    `Presupuesto: unos ${study.budget_tokens} tokens. Cuando te avisen de que queda poco, anota y cierra.`,
  ].join("\n");
}

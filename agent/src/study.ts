// Sesión de estudio del laboratorio: prompt, subagentes y medidor de tokens.
import type { AgentDefinition } from "@anthropic-ai/claude-agent-sdk";
import type { RunStudy } from "./lab.js";

export type Usage = { input_tokens?: number; output_tokens?: number; cache_creation_input_tokens?: number; cache_read_input_tokens?: number };

/** input + cache_creation + output + 0,1 × cache_read, redondeado hacia abajo. */
export const countTokens = (u: Usage): number =>
  Math.floor((u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.output_tokens ?? 0) + 0.1 * (u.cache_read_input_tokens ?? 0));

export class TokenMeter {
  private models = new Map<string, number>();
  private sum = { input: 0, output: 0 };
  constructor(private budget: number) {}

  add(model: string, usage: Usage) {
    this.models.set(model, (this.models.get(model) ?? 0) + countTokens(usage));
    this.sum.input += usage.input_tokens ?? 0;
    this.sum.output += usage.output_tokens ?? 0;
  }

  /** Solo cuenta mensajes `assistant` completos (stop_reason no nulo): los parciales no traen el uso final.
   *  Incluye los de subagentes (parent_tool_use_id no nulo). */
  consume(msg: { type?: string; message?: { model?: string; stop_reason?: string | null; usage?: Usage } }) {
    if (msg.type !== "assistant" || !msg.message?.usage) return;
    if (msg.message.stop_reason === null || msg.message.stop_reason === undefined) return;
    this.add(msg.message.model ?? "desconocido", msg.message.usage);
  }

  get total(): number { let t = 0; for (const v of this.models.values()) t += v; return t; }
  get warned(): boolean { return this.total >= this.budget * 0.85; }
  get exhausted(): boolean { return this.total >= this.budget; }
  get inputTokens(): number { return this.sum.input; }
  get outputTokens(): number { return this.sum.output; }
  byModel(): { model: string; tokens: number }[] { return [...this.models].map(([model, tokens]) => ({ model, tokens })); }
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

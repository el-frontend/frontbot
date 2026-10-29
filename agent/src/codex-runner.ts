import { z } from "zod";
import { streamOpenAIResponse, type OpenAIResponseEvent, type OpenAIResponsesRequest, type OpenAIResponsesResult } from "./openai-responses.js";
import { buildSummaryPrompt, buildSystemPrompt, buildUserPrompt, localToday, timeZoneLabel } from "./prompt.js";
import type { OpenAIAPIConfig, RunDone, RunEvent, RunParams, Runner, RunnerContext } from "./runner.js";
import { frontbotToolSpecs } from "./tools.js";

const MAX_TOOL_ROUNDS = 8;

type ResponsesTransport = (request: OpenAIResponsesRequest, options: { apiKey: string; signal?: AbortSignal }, onEvent?: (event: OpenAIResponseEvent) => void) => Promise<OpenAIResponsesResult>;

const cancelled = (runId: string): RunDone => ({
  run_id: runId, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: null, error: "Cancelado",
});

const failure = (runId: string, error: string, inputTokens = 0, outputTokens = 0): RunDone => ({
  run_id: runId, ok: false, summary: "", input_tokens: inputTokens, output_tokens: outputTokens, cost_usd: null, error,
});

function runPrompt(params: RunParams): string {
  if (params.mode === "summarize") return buildSummaryPrompt(params.history ?? [], params.agent?.name ?? "Frontbot");
  if (params.mode === "scheduled") return `Ejecución de la tarea programada «${params.task?.name ?? "tarea"}». Instrucción:\n${params.prompt}`;
  return buildUserPrompt(params.history ?? [], params.prompt, params.agent?.name);
}

function messageText(output: OpenAIResponsesResult["output"]): string {
  return output.flatMap((item) => {
    if (item.type !== "message" || !Array.isArray(item.content)) return [];
    return item.content.flatMap((content) => content && typeof content === "object" && !Array.isArray(content)
      && (content as Record<string, unknown>).type === "output_text" && typeof (content as Record<string, unknown>).text === "string"
      ? [(content as Record<string, string>).text]
      : []);
  }).join("");
}

function usage(response: OpenAIResponsesResult["response"]): { input: number; output: number } {
  const value = response.usage;
  if (!value || typeof value !== "object") return { input: 0, output: 0 };
  const raw = value as Record<string, unknown>;
  return {
    input: typeof raw.input_tokens === "number" ? raw.input_tokens : 0,
    output: typeof raw.output_tokens === "number" ? raw.output_tokens : 0,
  };
}

function safeError(error: unknown, apiKey: string): string {
  const message = error instanceof Error ? error.message : "OpenAI no pudo completar la solicitud.";
  return message.split(apiKey).join("[redacted]").replace(/Bearer\s+[^\s]+/gi, "Bearer [redacted]").slice(0, 1000);
}

type FunctionCall = { callId: string; name: string; args: Record<string, unknown>; fingerprint: string };
type FunctionResult = { fingerprint: string; output: string };

function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stableJSON(item)}`).join(",")}}`;
  return JSON.stringify(value);
}

function functionCalls(output: OpenAIResponsesResult["output"], allowed: Set<string>): FunctionCall[] | string {
  const calls: FunctionCall[] = [];
  for (const item of output) {
    if (item.type !== "function_call") continue;
    const callId = typeof item.call_id === "string" ? item.call_id : undefined;
    const name = typeof item.name === "string" ? item.name : undefined;
    if (!callId || !name || !allowed.has(name)) return "La herramienta solicitada no está permitida.";
    if (item.status !== "completed") return "La llamada de herramienta no está completada.";
    if (typeof item.arguments !== "string") return "Los argumentos de la herramienta no son válidos.";
    let parsed: unknown;
    try { parsed = JSON.parse(item.arguments); } catch { return "Los argumentos de la herramienta no son JSON válido."; }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return "Los argumentos de la herramienta no son válidos.";
    const args = parsed as Record<string, unknown>;
    calls.push({ callId, name, args, fingerprint: stableJSON([name, args]) });
  }
  return calls;
}

export class CodexRunner implements Runner {
  constructor(
    readonly config: OpenAIAPIConfig,
    private readonly transport: ResponsesTransport = streamOpenAIResponse,
  ) {}

  async run(params: RunParams, emit: (event: RunEvent) => void, signal: AbortSignal, context?: RunnerContext): Promise<RunDone> {
    if (signal.aborted) return cancelled(params.run_id);
    if (params.mode === "study") return failure(params.run_id, "Codex no está disponible para sesiones de estudio.");
    if (params.workdir) return failure(params.run_id, "Codex no está disponible para runs con carpeta de trabajo.");
    const apiKey = this.config.apiKey?.trim();
    if (!apiKey) return failure(params.run_id, "Falta la clave de OpenAI para ejecutar Codex.");
    const frontbot = context?.frontbot;
    if (!frontbot) return failure(params.run_id, "No se pudo preparar el contexto seguro de herramientas de Frontbot.");

    const specs = frontbotToolSpecs(frontbot.context);
    const allowed = new Set(specs.map((spec) => spec.name));
    const tools = specs.map((spec) => ({
      type: "function" as const,
      name: spec.name,
      description: spec.description,
      parameters: z.toJSONSchema(z.object(spec.shape)) as Record<string, unknown>,
      strict: false,
    }));
    const instructions = buildSystemPrompt({
      today: localToday(), timeZone: timeZoneLabel(), brand: params.brand, agent: params.agent,
      trading: params.mode === "summarize" ? undefined : params.trading,
      folders: params.mode === "summarize" ? undefined : params.folders,
      scheduledTask: params.mode === "scheduled" ? params.task?.name ?? "tarea" : undefined,
      browser: false, web: false,
    });
    const transcript: unknown[] = [{ role: "user", content: runPrompt(params) }];
    const priorResults = new Map<string, FunctionResult>();
    let inputTokens = 0;
    let outputTokens = 0;
    let summary = "";
    emit({ run_id: params.run_id, type: "status", text: "pensando" });

    try {
      for (let round = 0; round < MAX_TOOL_ROUNDS; round += 1) {
        if (signal.aborted) return cancelled(params.run_id);
        const result = await this.transport({ model: params.model, input: [...transcript], instructions, tools }, { apiKey, signal }, (event) => {
          if (event.type === "text_delta") emit({ run_id: params.run_id, type: "text", text: event.delta });
        });
        const count = usage(result.response);
        inputTokens += count.input;
        outputTokens += count.output;
        if (signal.aborted) return cancelled(params.run_id);
        if (result.response.status !== "completed") {
          return failure(params.run_id, "OpenAI no completó la respuesta.", inputTokens, outputTokens);
        }
        const text = messageText(result.output);
        if (text) summary = text;
        const calls = functionCalls(result.output, allowed);
        if (typeof calls === "string") return failure(params.run_id, calls, inputTokens, outputTokens);
        if (calls.length === 0) {
          return { run_id: params.run_id, ok: true, summary, input_tokens: inputTokens, output_tokens: outputTokens, cost_usd: null };
        }
        if (round === MAX_TOOL_ROUNDS - 1) return failure(params.run_id, "Codex alcanzó el límite de rondas de herramientas.", inputTokens, outputTokens);
        const roundCalls = new Map<string, string>();
        for (const call of calls) {
          const prior = priorResults.get(call.callId);
          const seen = roundCalls.get(call.callId);
          if ((prior && prior.fingerprint !== call.fingerprint) || (seen && seen !== call.fingerprint)) {
            return failure(params.run_id, "La llamada de herramienta reutiliza un identificador en conflicto.", inputTokens, outputTokens);
          }
          roundCalls.set(call.callId, call.fingerprint);
        }
        const results: Record<string, unknown>[] = [];
        for (const call of calls) {
          if (signal.aborted) return cancelled(params.run_id);
          let prior = priorResults.get(call.callId);
          if (!prior) {
            emit({ run_id: params.run_id, type: "tool_call", text: call.name });
            const output = await frontbot.execute(call.name, call.args);
            if (signal.aborted) return cancelled(params.run_id);
            prior = { fingerprint: call.fingerprint, output: JSON.stringify(output) };
            priorResults.set(call.callId, prior);
          }
          results.push({ type: "function_call_output", call_id: call.callId, output: prior.output });
        }
        transcript.push(...result.output, ...results);
      }
      return failure(params.run_id, "Codex alcanzó el límite de rondas de herramientas.", inputTokens, outputTokens);
    } catch (error) {
      if (signal.aborted) return cancelled(params.run_id);
      return failure(params.run_id, safeError(error, apiKey), inputTokens, outputTokens);
    }
  }
}

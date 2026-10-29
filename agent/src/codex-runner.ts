import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import type { ChildProcess, SpawnOptions } from "node:child_process";
import { buildSystemPrompt, buildUserPrompt, buildSummaryPrompt, localToday, timeZoneLabel } from "./prompt.js";
import { createCodexAppServer, redactSecrets, type CodexRuntimeConfig } from "./runner.js";
import { CodexAppServer } from "./codex-app-server.js";
import type { RunDone, RunEvent, RunParams, Runner } from "./runner.js";

const CANCEL_GRACE_MS = 1500;
const THREAD_START_TIMEOUT_MS = 45_000;
const TURN_TIMEOUT_MS = 20 * 60_000;

export type CodexRunnerOptions = {
  spawn?: (command: string, args: string[], options: SpawnOptions) => ChildProcess;
  mcpEntrypoint?: string;
  cwd?: string;
  cancelGraceMs?: number;
  requestTimeoutMs?: number;
};

type Completion = { status: "completed" | "interrupted" | "failed"; error?: string };

function result(runId: string, ok: boolean, summary = "", error?: string, inputTokens = 0, outputTokens = 0): RunDone {
  return { run_id: runId, ok, summary, input_tokens: inputTokens, output_tokens: outputTokens, cost_usd: 0, ...(error ? { error } : {}) };
}

function promptFor(params: RunParams): string {
  if (params.mode === "summarize") return buildSummaryPrompt(params.history ?? [], params.agent?.name ?? "Frontbot");
  const content = buildUserPrompt(params.history ?? [], params.prompt, params.agent?.name);
  if (params.mode === "scheduled") return `Ejecución de la tarea programada «${params.task?.name ?? "tarea"}». Instrucción:\n${content}`;
  return content;
}

function instructionsFor(params: RunParams): string {
  const system = buildSystemPrompt({
    today: localToday(), timeZone: timeZoneLabel(), agent: params.agent,
    brand: params.brand, browser: false, folders: params.folders,
    scheduledTask: params.mode === "scheduled" ? params.task?.name ?? "tarea" : undefined,
    trading: params.trading,
  });
  return `${system}\n\nRestricciones de seguridad de Frontbot:\n- Usa únicamente las herramientas MCP de Frontbot disponibles en esta conversación.\n- No invoques herramientas nativas de shell, terminal ni cambios directos de archivos. Frontbot las bloquea.\n- Cada operación que requiera aprobación debe pasar por la herramienta de Frontbot correspondiente.`;
}

function safeError(message: string, apiKey?: string, bridgeToken?: string): string {
  let value = apiKey ? message.split(apiKey).join("[redacted]") : message;
  if (bridgeToken) value = value.split(bridgeToken).join("[redacted]");
  const general = redactSecrets(value);
  if (/unauthorized|invalid[_ -]?api[_ -]?key|authentication|not authenticated|sign in/i.test(general)) {
    return "Codex no pudo autenticarse. Inicia sesión en Codex CLI o revisa la API key de OpenAI en Ajustes.";
  }
  if (/unknown model|unsupported model|model .*not found|invalid model/i.test(general)) {
    return "Codex no reconoce el modelo configurado. Elige un modelo Codex compatible en los ajustes del agente.";
  }
  if (/mcp|frontbot.*server/i.test(general)) return "No se pudo iniciar o conectar la herramienta MCP de Frontbot.";
  return general || "Codex no pudo completar la solicitud.";
}

/** Codex app-server is isolated per Frontbot run; Frontbot remains the history and tool owner. */
export class CodexRunner implements Runner {
  constructor(readonly config: CodexRuntimeConfig, private readonly options: CodexRunnerOptions = {}) {}

  async run(params: RunParams, emit: (event: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (signal.aborted) return result(params.run_id, false, "", "Cancelado");
    const bridge = (params as RunParams & { frontbot_mcp?: { socketPath?: string; token?: string } }).frontbot_mcp;
    if (!bridge?.socketPath || !bridge.token) return result(params.run_id, false, "", "No se pudo iniciar o conectar la herramienta MCP de Frontbot.");
    // app-server's workspaceWrite/readOnly policies cannot express Frontbot's protected paths,
    // separate read roots, network allowlist and per-write Swift approval contract.
    if (params.workdir) {
      return result(params.run_id, false, "", "La carpeta de trabajo todavía no está disponible con Codex: sus permisos no se pueden limitar a la política de Frontbot.");
    }

    let child: ChildProcess;
    try {
      child = createCodexAppServer(this.config, { spawn: this.options.spawn });
    } catch (error) {
      return result(params.run_id, false, "", safeError((error as Error).message, this.config.apiKey, bridge?.token));
    }

    const appServer = new CodexAppServer(child, this.options.requestTimeoutMs ?? THREAD_START_TIMEOUT_MS);
    let threadId: string | undefined;
    let inputTokens = 0;
    let outputTokens = 0;
    let accumulated = "";
    let doneResolve: ((completion: Completion) => void) | undefined;
    let finished = false;
    let cancelTimer: NodeJS.Timeout | undefined;
    const completed = new Promise<Completion>((resolve) => { doneResolve = resolve; });
    const finish = (completion: Completion) => {
      if (finished) return;
      finished = true;
      if (cancelTimer) clearTimeout(cancelTimer);
      doneResolve?.(completion);
    };
    const removeEvent = appServer.onEvent((event) => {
      if (event.type === "text") {
        accumulated += event.text;
        emit({ run_id: params.run_id, type: "text", text: event.text });
      } else if (event.type === "tool_call") {
        emit({ run_id: params.run_id, type: "tool_call", text: event.text });
      } else if (event.type === "status") {
        emit({ run_id: params.run_id, type: "status", text: event.text });
      } else if (event.type === "approval_request") {
        emit({ run_id: params.run_id, type: "status", text: "Codex solicitó acceso a una acción nativa; Frontbot la denegó." });
      } else if (event.type === "usage") {
        inputTokens = event.inputTokens;
        outputTokens = event.outputTokens;
      } else if (event.type === "completed") {
        finish(event);
      }
    });
    const removeError = appServer.onError((error) => finish({ status: "failed", error: error.message }));
    const onAbort = () => {
      void appServer.interrupt();
      cancelTimer = setTimeout(() => {
        finish({ status: "interrupted" });
        if (child.exitCode === null) child.kill("SIGTERM");
      }, this.options.cancelGraceMs ?? CANCEL_GRACE_MS);
    };
    signal.addEventListener("abort", onAbort, { once: true });

    try {
      await appServer.initialize();
      if (signal.aborted) return result(params.run_id, false, "", "Cancelado");
      const cwd = this.options.cwd ?? tmpdir();
      const mcpEntrypoint = this.options.mcpEntrypoint ?? fileURLToPath(new URL("./frontbot-mcp.js", import.meta.url));
      threadId = await appServer.startThread({
        model: params.model,
        modelProvider: "openai",
        cwd,
        runtimeWorkspaceRoots: [cwd],
        approvalPolicy: "untrusted",
        sandbox: "read-only",
        ephemeral: true,
        historyMode: "legacy",
        developerInstructions: instructionsFor(params),
        config: {
          mcp_servers: {
            frontbot: {
              command: process.execPath,
              args: [mcpEntrypoint],
              env: {
                FRONTBOT_MCP_SOCKET: bridge.socketPath,
                FRONTBOT_MCP_TOKEN: bridge.token,
              },
              enabled: true,
              required: true,
            },
          },
        },
      }, this.options.requestTimeoutMs ?? THREAD_START_TIMEOUT_MS);
      if (signal.aborted) return result(params.run_id, false, "", "Cancelado");
      emit({ run_id: params.run_id, type: "status", text: "Conectando con Codex…" });
      await appServer.startTurn({
        threadId,
        input: [{ type: "text", text: promptFor(params), text_elements: [] }],
        model: params.model,
        approvalPolicy: "untrusted",
        sandboxPolicy: { type: "readOnly", networkAccess: false },
      }, TURN_TIMEOUT_MS);

      const completion = await Promise.race([
        completed,
        new Promise<Completion>((resolve) => {
          const timer = setTimeout(() => resolve({ status: "failed", error: "Codex superó el tiempo máximo de ejecución." }), TURN_TIMEOUT_MS);
          void completed.finally(() => clearTimeout(timer));
        }),
      ]);
      if (completion.status === "interrupted" || signal.aborted) return result(params.run_id, false, accumulated.trim(), "Cancelado", inputTokens, outputTokens);
      if (completion.status === "completed") return result(params.run_id, true, accumulated.trim(), undefined, inputTokens, outputTokens);
      return result(params.run_id, false, accumulated.trim(), safeError(completion.error ?? "Codex terminó con error.", this.config.apiKey, bridge.token), inputTokens, outputTokens);
    } catch (error) {
      const message = safeError((error as Error).message || "Codex no pudo completar la solicitud.", this.config.apiKey, bridge.token);
      return result(params.run_id, false, accumulated.trim(), signal.aborted ? "Cancelado" : message, inputTokens, outputTokens);
    } finally {
      signal.removeEventListener("abort", onAbort);
      if (cancelTimer) clearTimeout(cancelTimer);
      removeEvent();
      removeError();
      await appServer.close();
    }
  }
}

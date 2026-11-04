// Runner de Codex con la sesión de ChatGPT: un `codex app-server` por run, con el CODEX_HOME de Frontbot.
// Las herramientas de Frontbot (y las de Chrome, tras el guardián) van como herramientas dinámicas:
// Codex las pide y el sidecar las ejecuta. Lo que el modo no da no existe en el proceso.
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { AppServer, type ServerReply, type Spawn } from "./codex/appServer.js";
import { codexEnv, codexVersionOk, ensureCodexHome } from "./codex/account.js";
import { codexArgs, codexCaps, codexMaxToolCalls, codexThreadParams, type CodexCaps, type DynamicTool } from "./codex/launch.js";
import { ChromeBridge, claudeChromeCommand } from "./codex/chromeBridge.js";
import { localToday } from "./prompt.js";
import { prepareSkillPlugin, readGuard, type SkillPlugin } from "./skills.js";
import { STUDY_WARNING, TokenMeter, buildStudyPrompt } from "./study.js";
import { alwaysDenied, validateWorkdir, workdirDecision } from "./workdir.js";
import { frontbotToolSpecs, type AppCall } from "./tools.js";
import { redactSecrets, runSystemPrompt, toolCallText, userPrompt, type RunDone, type RunEvent, type RunParams, type Runner, type RunnerContext } from "./runner.js";

export type ChromeLike = Pick<ChromeBridge, "tools" | "has" | "call" | "close">;

export type CodexAppRunnerOptions = {
  bin: string | null;
  home: string;
  version?: () => Promise<string>;
  start?: (s: Spawn) => AppServer;
  startChrome?: () => Promise<ChromeLike | null>;
};

const NOT_INSTALLED = "Codex no está instalado. Instálalo o conecta solo la API key en Ajustes.";
const OUTDATED = "Actualiza Codex para usarlo en Frontbot.";
const MODEL_UNAVAILABLE = "Elige un modelo disponible en la ficha del agente.";
const CRASHED = "Codex se cerró inesperadamente.";
const TOOL_LIMIT = "Codex alcanzó el límite de herramientas de este run.";
const NOT_ALLOWED = "La herramienta solicitada no está permitida.";

const STUDY_WALL_CLOCK_MS = 20 * 60 * 1000;
const SKILL_READ_MAX = 256 * 1024;
const SKILLS_READ_DENIED = "skills_read solo puede leer archivos de tus skills.";
const SKILLS_READ_TOOL: DynamicTool = {
  type: "function", name: "skills_read",
  description: "Lee un archivo de uno de tus skills (SKILL.md o sus archivos de apoyo). path: ruta absoluta que aparece en la lista de skills.",
  inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"], additionalProperties: false },
};

/** ¿El comando nombra una ruta que nunca se toca (~/.ssh, el llavero, los datos de Frontbot…)? */
export function mentionsProtected(command: string, home: string): boolean {
  return alwaysDenied(home).some((p) => command.includes(p) || command.includes("~/" + p.slice(home.length + 1)) || command.includes("$HOME/" + p.slice(home.length + 1)));
}

function skillsSection(plugin: SkillPlugin): string {
  if (!plugin.dirs.length) return "";
  const lines = plugin.skillNames.map((name, i) => `- ${name.split(":").pop()}: ${join(plugin.dirs[i], "SKILL.md")}`);
  return `\n\nSkills disponibles (léelos con skills_read antes de usarlos):\n${lines.join("\n")}`;
}

const result = (text: string, success = true): ServerReply => ({ result: { success, contentItems: [{ type: "inputText", text }] } });

/** Una tubería para cerrar el run una sola vez, venga de donde venga el final. */
class Finish {
  private done?: (d: RunDone) => void;
  readonly promise = new Promise<RunDone>((r) => { this.done = r; });
  private settled = false;
  settle(d: RunDone) { if (!this.settled) { this.settled = true; this.done!(d); } }
  get isSettled() { return this.settled; }
}

export class CodexAppRunner implements Runner {
  private readonly version: () => Promise<string>;
  private readonly start: (s: Spawn) => AppServer;
  private readonly startChrome: () => Promise<ChromeLike | null>;

  constructor(private opts: CodexAppRunnerOptions) {
    this.version = opts.version ?? (async () => "");
    this.start = opts.start ?? AppServer.start;
    this.startChrome = opts.startChrome ?? (() => ChromeBridge.start(claudeChromeCommand(process.env)));
  }

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal, context?: RunnerContext): Promise<RunDone> {
    const empty = { run_id: params.run_id, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: null, runtime: "session" as const };
    const fail = (error: string, tokens = { input: 0, output: 0 }): RunDone => ({ ...empty, ok: false, error, input_tokens: tokens.input, output_tokens: tokens.output });
    if (signal.aborted) return fail("Cancelado");
    if (!this.opts.bin || !this.opts.home) return fail(NOT_INSTALLED);
    if (!codexVersionOk(await this.version())) return fail(OUTDATED);
    const frontbot = context?.frontbot;
    if (!frontbot) return fail("No se pudo preparar el contexto seguro de herramientas de Frontbot.");

    const caps = codexCaps(params);
    if (caps.shell) { const bad = validateWorkdir(params.workdir!); if (bad) return fail(bad); }
    if (params.mode === "study" && (!params.study || !params.agent)) return { ...fail("Sesión de estudio sin tema o sin agente"), lab_tokens: 0, models: [] };
    const ownCwd = caps.shell ? undefined : mkdtempSync(join(tmpdir(), "frontbot-codex-"));
    const cwd = ownCwd ?? params.workdir!.path;
    let server: AppServer | undefined;
    let bridge: ChromeLike | null = null;
    const plugin = caps.skills ? prepareSkillPlugin(params.skills ?? []) : undefined;
    const canReadSkill = plugin ? readGuard(plugin.dirs, plugin.path) : undefined;
    const meter = params.mode === "study" ? new TokenMeter(params.study?.budget_tokens ?? 0) : undefined;
    let warned = false;
    let clock: NodeJS.Timeout | undefined;
    /** itemId de un fileChange → rutas que toca (la petición de aprobación no las trae). */
    const fileChanges = new Map<string, string[]>();
    const finish = new Finish();
    const tokens = { input: 0, output: 0 };
    let summary = "";
    let calls = 0;
    const maxCalls = codexMaxToolCalls(params);
    let threadId = "";
    let turnId = "";

    const lab = () => (meter ? { lab_tokens: meter.total, models: meter.byModel() } : {});
    /** Corte del estudio por límite: no es un fallo del usuario. */
    const cut = (reason: "tokens" | "clock") => {
      if (finish.isSettled) return;
      if (server && threadId && turnId) void server.request("turn/interrupt", { threadId, turnId }).catch(() => undefined);
      finish.settle({ ...empty, ok: true, summary: "Sesión cortada por límite", input_tokens: tokens.input, output_tokens: tokens.output, cut: true, cut_reason: reason, ...lab() });
    };
    const interruptAndFail = (error: string) => {
      if (finish.isSettled) return;
      if (server && threadId && turnId) void server.request("turn/interrupt", { threadId, turnId }).catch(() => undefined);
      finish.settle({ ...fail(error, tokens), ...lab() });
    };
    const onAbort = () => interruptAndFail("Cancelado");
    signal.addEventListener("abort", onAbort, { once: true });

    try {
      ensureCodexHome(this.opts.home);
      server = this.start({ command: this.opts.bin, args: codexArgs(caps, params.workdir ? { wd: params.workdir, home: process.env.HOME ?? "" } : undefined), env: codexEnv(this.opts.home), cwd });
      void server.exited.then(() => finish.settle(fail(CRASHED, tokens)));
      await server.initialize();
      const list = await server.request<{ data?: { id?: string }[] }>("model/list", {});
      if (!(list?.data ?? []).some((m) => m.id === params.model)) return fail(MODEL_UNAVAILABLE);

      if (caps.browser) bridge = await this.startChrome();
      const specs = frontbotToolSpecs(frontbot.context);
      const allowed = new Set<string>(specs.map((s) => s.name));
      const tools: DynamicTool[] = [
        ...specs.map((s): DynamicTool => ({ type: "function", name: s.name, description: s.description, inputSchema: z.toJSONSchema(z.object(s.shape)) as Record<string, unknown> })),
        ...(bridge?.tools ?? []),
        ...(plugin ? [SKILLS_READ_TOOL] : []),
      ];

      server.onServerRequest(async (method, p) => {
        if (method === "item/tool/call") {
          if (++calls > maxCalls) { interruptAndFail(TOOL_LIMIT); return result(TOOL_LIMIT, false); }
          const name = String(p.tool ?? "");
          const args = p.arguments && typeof p.arguments === "object" && !Array.isArray(p.arguments) ? p.arguments as Record<string, unknown> : {};
          if (allowed.has(name)) return result(JSON.stringify(await frontbot.execute(name, args)));
          if (bridge?.has(name)) { const r = await bridge.call(name, args); return result(r.text, r.success); }
          if (name === "skills_read" && canReadSkill) return this.readSkill(String(args.path ?? ""), canReadSkill);
          return result(NOT_ALLOWED, false);
        }
        if (params.workdir && caps.shell && method === "item/commandExecution/requestApproval") return this.approveCommand(String(p.command ?? ""), params, frontbot.call);
        if (params.workdir && caps.shell && method === "item/fileChange/requestApproval") return this.approveFiles(p.grantRoot ? undefined : fileChanges.get(String(p.itemId ?? "")), params, frontbot.call);
        return this.decline(method);
      });

      server.onNotification((method, p) => {
        if (method === "item/agentMessage/delta" && typeof p.delta === "string") emit({ run_id: params.run_id, type: "text", text: p.delta });
        else if (method === "item/started") {
          const item = p.item ?? {};
          if (item.type === "fileChange" && Array.isArray(item.changes)) fileChanges.set(String(item.id ?? ""), item.changes.map((c: { path?: unknown }) => String(c?.path ?? "")));
          if (item.type === "dynamicToolCall") emit({ run_id: params.run_id, type: "tool_call", text: toolCallText(String(item.tool ?? ""), item.arguments) });
          else if (item.type === "commandExecution") {
            if (++calls > maxCalls) interruptAndFail(TOOL_LIMIT);
            emit({ run_id: params.run_id, type: "tool_call", text: `Bash · ${String(item.command ?? "").slice(0, 120)}` });
          } else if (item.type === "webSearch") emit({ run_id: params.run_id, type: "tool_call", text: "web" });
        } else if (method === "item/completed" && p.item?.type === "agentMessage" && typeof p.item.text === "string") summary = p.item.text;
        else if (method === "thread/tokenUsage/updated") {
          const total = p.tokenUsage?.total ?? {};
          tokens.input = Number(total.inputTokens ?? 0);
          tokens.output = Number(total.outputTokens ?? 0);
          if (meter) {
            const cached = Number(total.cachedInputTokens ?? 0);
            meter.add(params.model, { input_tokens: tokens.input - cached, cache_read_input_tokens: cached, output_tokens: tokens.output }, "codex-thread");
            if (meter.exhausted) cut("tokens");
            else if (meter.warned && !warned && threadId && turnId) {
              warned = true;
              void server!.request("turn/steer", { threadId, expectedTurnId: turnId, input: [{ type: "text", text: STUDY_WARNING, text_elements: [] }] }).catch(() => undefined);
            }
          }
        } else if (method === "error") {
          const message = String(p.error?.message ?? p.message ?? "Codex no pudo completar el turno.");
          finish.settle(fail(redactSecrets(message), tokens));
        } else if (method === "turn/completed") {
          const status = p.turn?.status;
          if (status === "completed") finish.settle({ ...empty, ok: true, summary, input_tokens: tokens.input, output_tokens: tokens.output, ...lab() });
          else finish.settle(fail("Codex no completó el turno.", tokens));
        }
      });

      emit({ run_id: params.run_id, type: "status", text: "pensando" });
      const instructions = runSystemPrompt(params, { today: localToday(), browser: bridge !== null, web: caps.web, codex: true }) + (plugin ? skillsSection(plugin) : "");
      const prompt = params.mode === "study" ? buildStudyPrompt(params.study!, params.agent!, { delegate: false }) : userPrompt(params);
      const thread = await server.request<{ thread?: { id?: string } }>("thread/start", codexThreadParams({ params, caps, instructions, tools, cwd }));
      threadId = String(thread?.thread?.id ?? "");
      const turn = await server.request<{ turn?: { id?: string } }>("turn/start", { threadId, input: [{ type: "text", text: prompt, text_elements: [] }] });
      turnId = String(turn?.turn?.id ?? "");
      if (meter) clock = setTimeout(() => cut("clock"), STUDY_WALL_CLOCK_MS);
      return await finish.promise;
    } catch (e) {
      if (signal.aborted) return fail("Cancelado", tokens);
      return finish.isSettled ? await finish.promise : fail(redactSecrets((e as Error).message || CRASHED), tokens);
    } finally {
      signal.removeEventListener("abort", onAbort);
      clearTimeout(clock);
      plugin?.cleanup();
      server?.kill();
      bridge?.close();
      if (ownCwd) rmSync(ownCwd, { recursive: true, force: true });
    }
  }

  private readSkill(path: string, allowed: (p: string) => boolean): ServerReply {
    if (!path || !allowed(path)) return result(SKILLS_READ_DENIED, false);
    try {
      if (statSync(path).size > SKILL_READ_MAX) return result("El archivo es demasiado grande para leerlo (máx. 256 KB).", false);
      return result(readFileSync(path, "utf8"));
    } catch {
      return result("No se pudo leer el archivo.", false);
    }
  }

  /** Aceptar una aprobación saca el comando de la sandbox: lo protegido nunca, el resto lo decide el usuario. */
  private async approveCommand(command: string, params: RunParams, call: AppCall): Promise<ServerReply> {
    const wd = params.workdir!;
    if (!command || mentionsProtected(command, homedir())) return { result: { decision: "decline" } };
    const d = workdirDecision("Bash", { command, dangerouslyDisableSandbox: true }, wd);
    if (d.kind === "deny" || d.kind === "allow") return { result: { decision: "decline" } };
    return { result: { decision: await this.ask(call, { run_id: params.run_id, ...d.ask }) ? "accept" : "decline" } };
  }

  private async approveFiles(paths: string[] | undefined, params: RunParams, call: AppCall): Promise<ServerReply> {
    if (!paths?.length) return { result: { decision: "decline" } };
    for (const path of paths) {
      const d = workdirDecision("Write", { file_path: path, content: "" }, params.workdir!);
      if (d.kind === "deny") return { result: { decision: "decline" } };
      if (d.kind === "ask" && !(await this.ask(call, { run_id: params.run_id, ...d.ask }))) return { result: { decision: "decline" } };
    }
    return { result: { decision: "accept" } };
  }

  private async ask(call: AppCall, ask: Record<string, unknown>): Promise<boolean> {
    try { return ((await call("workdir.approve", ask)) as { allow?: boolean })?.allow === true; } catch { return false; }
  }

  /** Nunca se acepta algo que el run no previó: aprobaciones, permisos, preguntas al usuario o MCP. */
  private async decline(method: string): Promise<ServerReply> {
    if (method.endsWith("requestApproval") || method === "applyPatchApproval" || method === "execCommandApproval") return { result: { decision: "decline" } };
    return { error: { code: -32601, message: `Frontbot no admite ${method}.` } };
  }
}

export type { CodexCaps };

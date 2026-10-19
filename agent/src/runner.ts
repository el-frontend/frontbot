import { homedir } from "node:os";
import { dirname, relative, isAbsolute } from "node:path";
import { query, createSdkMcpServer, type Options } from "@anthropic-ai/claude-agent-sdk";
import { buildTools, allowedToolsFor, type AppCall, type ToolContext } from "./tools.js";
import { BrowserGuard, BROWSER_ALLOWED_TOOLS } from "./browserGuard.js";
import { buildTradingTools, buildMarketTools, realMarket, TRADING_TOOL_NAMES, type RunTrading } from "./trading.js";
import type { RunStudy } from "./lab.js";
import { TokenMeter, buildStudyPrompt, studyAgents, STUDY_WARNING } from "./study.js";
import { prepareSkillPlugin, readGuard, type RunSkill, type SkillPlugin } from "./skills.js";
import { WORKDIR_TOOLS, isProtectedPath, sandboxSettings, validateWorkdir, workdirDecision, type RunWorkdir } from "./workdir.js";
import { buildSystemPrompt, buildUserPrompt, buildSummaryPrompt, type MemoryNote, localToday, timeZoneLabel, type HistoryTurn } from "./prompt.js";

export type Brand = { id: string; name: string; guide: string | null };
export type RunAgent = { id: string; name: string; instructions: string; is_default: boolean; memory?: MemoryNote[] };
/** mode "summarize": run en segundo plano que solo actualiza la memoria del agente.
 *  mode "scheduled": tarea programada, sin nadie mirando; puede avisar con notify_user. */
export type RunParams = { run_id: string; prompt: string; model: string; agent?: RunAgent; brand?: Brand; history?: HistoryTurn[]; browser?: boolean; mode?: "chat" | "summarize" | "scheduled" | "study"; study?: RunStudy; skills?: RunSkill[]; trading?: RunTrading; task?: { name: string };
  /** Carpetas del usuario autorizadas para este agente (rutas reales). */
  folders?: string[];
  /** Carpeta de trabajo del chat: herramientas de Claude Code dentro de la sandbox. Se ignora fuera de runs de chat. */
  workdir?: RunWorkdir };

const STUDY_MODEL = "claude-sonnet-5-5";
const STUDY_WALL_CLOCK_MS = 20 * 60 * 1000;
const MARKET_TOOL_NAMES = ["market_price", "market_candles", "market_funding", "market_book"];

/** Sin agente (clientes viejos o tests), el run es de Frontbot. */
export const toolContext = (params: RunParams): ToolContext => ({
  agentId: params.agent?.id, isDefault: params.agent?.is_default ?? true, memoryOnly: params.mode === "summarize",
  runId: params.run_id, scheduled: params.mode === "scheduled", files: (params.folders?.length ?? 0) > 0,
  // Cerrado por defecto: en estudio la lista de estudio rige aunque falte el tema (RealRunner lo rechaza antes).
  study: params.mode === "study" ? { topicId: params.study?.topic_id ?? "", sessionId: params.study?.session_id ?? "" } : undefined,
});

const userPrompt = (params: RunParams) => params.mode === "study" && params.study
  ? buildStudyPrompt(params.study, params.agent ?? { name: "Frontbot" })
  : params.mode === "summarize"
  ? buildSummaryPrompt(params.history ?? [], params.agent?.name ?? "Frontbot")
  : params.mode === "scheduled"
    ? `Ejecución de la tarea programada «${params.task?.name ?? "tarea"}». Instrucción:\n${params.prompt}`
    : buildUserPrompt(params.history ?? [], params.prompt, params.agent?.name);
export type RunEvent = { run_id: string; type: "text" | "tool_call" | "status"; text: string };
export type RunDone = { run_id: string; ok: boolean; summary: string; input_tokens: number; output_tokens: number; cost_usd: number; error?: string;
  /** Solo en estudio: cortada por límite, tokens contados con la métrica del laboratorio y desglose por modelo. */
  cut?: boolean; cut_reason?: "tokens" | "clock"; lab_tokens?: number; models?: { model: string; tokens: number }[] };

export interface Runner {
  run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone>;
}

const cancelled = (run_id: string): RunDone => ({ run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: "Cancelado" });

type Hooks = NonNullable<Options["hooks"]>;

/** Une los hooks de varios guardianes (cada uno añade sus matchers). */
function mergeHooks(...all: (Hooks | undefined)[]): Hooks | undefined {
  const out: Hooks = {};
  for (const h of all) {
    if (!h) continue;
    for (const [event, matchers] of Object.entries(h) as [keyof Hooks, Hooks[keyof Hooks]][]) {
      out[event] = [...(out[event] ?? []), ...(matchers ?? [])];
    }
  }
  return Object.keys(out).length ? out : undefined;
}

/** `Read` solo para los archivos de los skills del run. */
function skillReadHooks(plugin: SkillPlugin): Hooks {
  const allowed = readGuard(plugin.dirs, plugin.path);
  return {
    PreToolUse: [{ matcher: "Read", hooks: [async (input) => {
      if (input.hook_event_name !== "PreToolUse") return {};
      const path = String((input.tool_input as { file_path?: unknown })?.file_path ?? "");
      if (allowed(path)) return {};
      return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "Read solo puede leer archivos de tus skills." } };
    }] }],
  };
}

/** Dónde se instala el Node de la app y los navegadores: la sandbox de Bash los necesita para leer. */
const toolPaths = () => [dirname(process.execPath), "/Applications/Google Chrome.app", "/Applications/Chromium.app", "/opt/homebrew", "/usr/local"];

/** Todas las herramientas pasan por aquí: lo protegido se deniega, lo de fuera pide aprobación a la app.
 *  Con skills, `Read` también vale para sus archivos (salvo rutas protegidas). */
function workdirHooks(wd: RunWorkdir, runId: string, call: AppCall | undefined, skillRead: ((p: string) => boolean) | undefined): Hooks {
  const deny = (reason: string) => ({ hookSpecificOutput: { hookEventName: "PreToolUse" as const, permissionDecision: "deny" as const, permissionDecisionReason: reason } });
  return {
    PreToolUse: [{ hooks: [async (input) => {
      if (input.hook_event_name !== "PreToolUse") return {};
      const ti = (input.tool_input ?? {}) as Record<string, unknown>;
      if (input.tool_name === "Read" && skillRead) {
        const path = String(ti.file_path ?? "");
        if (path && skillRead(path) && !isProtectedPath(path, wd)) return {};
      }
      const d = workdirDecision(input.tool_name, ti, wd);
      if (d.kind === "allow") return {};
      if (d.kind === "deny") return deny(d.reason);
      if (!call) return deny("No se pudo pedir la aprobación al usuario.");
      try {
        const res = (await call("workdir.approve", { run_id: runId, ...d.ask })) as { allow?: boolean };
        // Aprobado: allow explícito, porque en dontAsk un `{}` deja a Bash sin sandbox sin permiso.
        return res?.allow === true ? { hookSpecificOutput: { hookEventName: "PreToolUse" as const, permissionDecision: "allow" as const, permissionDecisionReason: "Aprobado por el usuario" } } : deny("El usuario lo denegó; no insistas.");
      } catch (err) {
        return deny(`No se pudo pedir la aprobación: ${(err as Error).message}`);
      }
    }] }],
  };
}

/** Hooks que pasan cada herramienta del navegador por el guardián (no publicar en redes). */
function browserHooks(guard: BrowserGuard): Hooks {
  return {
    PreToolUse: [{ hooks: [async (input) => {
      if (input.hook_event_name !== "PreToolUse") return {};
      const decision = guard.beforeTool(input.tool_name, input.tool_input);
      if (decision.allow) return {};
      return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: decision.reason } };
    }] }],
    PostToolUse: [{ hooks: [async (input) => {
      if (input.hook_event_name === "PostToolUse") guard.afterTool(input.tool_name, input.tool_response);
      return {};
    }] }],
  };
}

/** Opciones del SDK: solo web + herramientas propias, sin settings del usuario y sin guardar sesiones en ~/.claude.
 *  Con `browser`, añade el Chrome del usuario (Claude in Chrome) detrás del guardián. */
export function buildQueryOptions(params: RunParams, server: ReturnType<typeof createSdkMcpServer>, abortController: AbortController, today: string, plugin?: SkillPlugin, meter: TokenMeter | undefined = undefined, call?: AppCall): Options {
  const summarize = params.mode === "summarize";
  // En estudio nadie mira: sin Chrome, sin plugin de skills y sin Read, aunque el run los pida.
  const study = params.mode === "study";
  const browser = params.browser === true && !summarize && !study;
  const skills = !summarize && !study && plugin && plugin.skillNames.length > 0 ? plugin : undefined;
  // La carpeta de trabajo solo existe en el chat; en el resto de modos se ignora aunque llegue.
  const workdir = (params.mode === undefined || params.mode === "chat") ? params.workdir : undefined;
  const hooks = mergeHooks(browser ? browserHooks(new BrowserGuard()) : undefined,
    // Con carpeta, el hook de carpeta absorbe el Read de los skills (dos hooks de Read se estorbarían).
    workdir ? workdirHooks(workdir, params.run_id, call, skills ? readGuard(skills.dirs, skills.path) : undefined) : skills ? skillReadHooks(skills) : undefined);
  let warned = false;
  if (study && !meter) throw new Error("El modo study necesita un TokenMeter");
  const studyMeter = study ? meter : undefined;
  const studyHooks: Hooks | undefined = studyMeter ? { PostToolUse: [{ hooks: [async (input) => {
    if (input.hook_event_name !== "PostToolUse" || warned || !studyMeter.warned) return {};
    warned = true;
    return { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: STUDY_WARNING } };
  }] }] } : undefined;
  return {
    // El hilo principal del estudio siempre corre en Sonnet (§8); los subagentes eligen el suyo.
    model: study ? STUDY_MODEL : params.model,
    systemPrompt: buildSystemPrompt({ today, timeZone: timeZoneLabel(), brand: params.brand, browser, agent: params.agent, trading: summarize ? undefined : params.trading, folders: summarize || study ? undefined : params.folders, workdir, scheduledTask: params.mode === "scheduled" ? params.task?.name ?? "tarea" : undefined, study }),
    tools: [...new Set(summarize ? [] : study ? ["WebSearch", "WebFetch", "Agent"] : ["WebSearch", "WebFetch", ...(skills ? ["Skill", "Read"] : []), ...(workdir ? WORKDIR_TOOLS : [])])],
    allowedTools: [...new Set([...allowedToolsFor(toolContext(params)), ...(browser ? BROWSER_ALLOWED_TOOLS : []), ...(skills ? ["Skill", "Read"] : []), ...(workdir ? WORKDIR_TOOLS : []),
      // En estudio solo se lee el mercado: ni account_state ni trade_propose.
      ...(params.trading && !summarize ? (study ? MARKET_TOOL_NAMES : TRADING_TOOL_NAMES).map((t) => `mcp__frontbot__${t}`) : []),
      ...(study ? ["Agent"] : [])])],
    ...(workdir ? { cwd: workdir.path, sandbox: sandboxSettings(workdir, homedir(), toolPaths()) } : {}),
    ...(browser ? { extraArgs: { chrome: null } } : {}),
    ...(hooks || studyHooks ? { hooks: mergeHooks(hooks, studyHooks) } : {}),
    ...(study ? { agents: studyAgents(params.study?.allow_opus === true), forwardSubagentText: true } : {}),
    ...(skills ? {
      plugins: [{ type: "local" as const, path: skills.path }], skills: skills.skillNames,
      // Un skill de terceros no puede ejecutar comandos incrustados (`!cmd`): solo la sandbox con aprobación.
      settings: { disableSkillShellExecution: true },
    } : {}),
    mcpServers: { frontbot: server },
    strictMcpConfig: true,
    settingSources: [],
    permissionMode: "dontAsk",
    persistSession: false,
    maxTurns: summarize ? 6 : study ? 60 : workdir ? 150 : 30,
    abortController,
  };
}

/** Texto del evento tool_call. Las integradas de la carpeta de trabajo llevan su detalle ("Bash · ls"). */
export function toolCallText(name: string, input: unknown, wd?: RunWorkdir): string {
  if (wd && WORKDIR_TOOLS.includes(name)) {
    const i = (input ?? {}) as Record<string, unknown>;
    const s = (v: unknown) => (typeof v === "string" ? v : "");
    const rel = (f: string) => { const r = isAbsolute(f) ? relative(wd.path, f) : f; return r === ".." || r.startsWith("../") ? f : r; };
    const detail = name === "Bash" ? s(i.command)
      : name === "Read" || name === "Write" || name === "Edit" ? rel(s(i.file_path))
      : name === "Glob" || name === "Grep" ? s(i.pattern) : "";
    return detail ? `${name} · ${detail.slice(0, 120)}` : name;
  }
  return name.replace("mcp__frontbot__", "").replace("mcp__claude-in-chrome__", "chrome · ");
}

export class RealRunner implements Runner {
  constructor(private call: AppCall, private queryFn: typeof query = query) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (signal.aborted) return cancelled(params.run_id);
    if (params.mode === "study" && (!params.study || !params.agent)) return { ...cancelled(params.run_id), error: "Sesión de estudio sin tema o sin agente", lab_tokens: 0, models: [] };
    if ((params.mode === undefined || params.mode === "chat") && params.workdir) {
      const bad = validateWorkdir(params.workdir);
      if (bad) return { ...cancelled(params.run_id), error: bad };
    }
    const abortController = new AbortController();
    signal.addEventListener("abort", () => abortController.abort(), { once: true });
    const plugin = params.skills?.length && params.mode !== "study" ? prepareSkillPlugin(params.skills) : undefined;
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [
      ...buildTools(this.call, { ...toolContext(params), skillPlugin: plugin }),
      ...(params.trading && params.mode === "study" ? buildMarketTools(realMarket, "mainnet") : []),
      ...(params.trading && params.mode !== "summarize" && params.mode !== "study" ? buildTradingTools(this.call, { agentId: params.agent?.id, trading: params.trading }) : []),
    ] });
    const today = localToday();
    const isStudy = params.mode === "study";
    const meter = isStudy ? new TokenMeter(params.study?.budget_tokens ?? 0) : undefined;
    // Corte por límite (tokens o reloj): no es una cancelación del usuario. El de reloj cuenta como fallo en la app.
    let cut: "tokens" | "clock" | undefined;
    // En estudio, todo final (también cancelado o con error) lleva lo gastado: la app lo descuenta del límite diario.
    const spent = () => meter ? { input_tokens: meter.inputTokens, output_tokens: meter.outputTokens, lab_tokens: meter.total, models: meter.byModel() } : {};
    const ended = (done: RunDone): RunDone => ({ ...done, ...spent() });
    const cutDone = (): RunDone => ended({ run_id: params.run_id, ok: true, summary: "Sesión cortada por límite", input_tokens: 0, output_tokens: 0, cost_usd: 0, cut: true, cut_reason: cut });
    const clock = isStudy ? setTimeout(() => { cut = "clock"; abortController.abort(); }, STUDY_WALL_CLOCK_MS) : undefined;
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    try {
      const stream = this.queryFn({ prompt: userPrompt(params), options: buildQueryOptions(params, server, abortController, today, plugin, meter, this.call) });
      for await (const msg of stream) {
        if (meter) {
          meter.consume(msg as never);
          if (meter.exhausted) { cut = "tokens"; abortController.abort(); return cutDone(); }
        }
        if (msg.type === "assistant") {
          // El texto de los subagentes viaja en el flujo (forwardSubagentText) pero no se muestra como del agente.
          if (msg.parent_tool_use_id) continue;
          for (const block of msg.message.content) {
            if (block.type === "text") emit({ run_id: params.run_id, type: "text", text: block.text });
            if (block.type === "tool_use") emit({ run_id: params.run_id, type: "tool_call", text: toolCallText(block.name, block.input, params.workdir) });
          }
        } else if (msg.type === "result") {
          meter?.reconcile(msg.modelUsage);
          if (cut) return cutDone();
          const usage = msg.usage as { input_tokens?: number; output_tokens?: number };
          const base = { run_id: params.run_id, input_tokens: usage.input_tokens ?? 0, output_tokens: usage.output_tokens ?? 0, cost_usd: msg.total_cost_usd ?? 0 };
          const lab = meter ? { lab_tokens: meter.total, models: meter.byModel() } : {};
          if (msg.subtype === "success" && !msg.is_error) return { ...base, ...lab, ok: true, summary: msg.result };
          return { ...base, ...lab, ok: false, summary: "", error: msg.subtype === "success" ? msg.result : msg.subtype };
        }
      }
      if (cut) return cutDone();
      return ended(signal.aborted ? cancelled(params.run_id) : { ...cancelled(params.run_id), error: "El agente terminó sin resultado" });
    } catch (err) {
      if (cut) return cutDone();
      if (signal.aborted) return ended(cancelled(params.run_id));
      return ended({ ...cancelled(params.run_id), error: (err as Error).message });
    } finally {
      clearTimeout(clock);
      plugin?.cleanup();
    }
  }
}

/** Runner guionado, sin red: para probar la app de punta a punta sin gastar tokens. */
export class FakeRunner implements Runner {
  constructor(private call: AppCall) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (params.prompt === "crash") process.exit(1);
    if (params.prompt.includes("escribir") && params.folders?.length) {
      // Para los tests de la app: escribe un archivo en la primera carpeta (o cuenta por qué no pudo).
      const text = await this.call("tool.files_write", { agent_id: params.agent?.id, run_id: params.run_id, path: `${params.folders[0]}/fake.txt`, content: "hola" })
        .then(() => "Escrito", (err: Error) => `No escrito: ${err.message}`);
      emit({ run_id: params.run_id, type: "text", text });
      return { run_id: params.run_id, ok: true, summary: text, input_tokens: 0, output_tokens: 0, cost_usd: 0 };
    }
    if (params.mode === "study") {
      const ids = { agent_id: params.agent?.id, topic_id: params.study?.topic_id, session_id: params.study?.session_id };
      const models = (tokens: number) => [{ model: "claude-sonnet-5-5", tokens }];
      if (params.prompt.includes("lento")) {
        // Espera a que la cancelen (el usuario o el watchdog) y cuenta lo gastado.
        await new Promise<void>((resolve) => signal.aborted ? resolve() : signal.addEventListener("abort", () => resolve(), { once: true }));
        return { ...cancelled(params.run_id), lab_tokens: 777, models: models(777) };
      }
      if (params.prompt.includes("colgado")) await new Promise(() => {}); // nunca termina e ignora cancel
      if (params.prompt.includes("cortar")) {
        if (params.prompt.includes("tras cerrar")) await this.call("tool.lab_end_session", { ...ids, outcome: "pause", summary: "Cerrada antes del corte" });
        return { run_id: params.run_id, ok: true, summary: "Sesión cortada por límite", input_tokens: 0, output_tokens: 0, cost_usd: 0, cut: true,
          cut_reason: params.prompt.includes("reloj") ? "clock" : "tokens", lab_tokens: 5000, models: models(5000) };
      }
      await this.call("tool.lab_note", { ...ids, kind: "note", text: "nota de prueba" });
      emit({ run_id: params.run_id, type: "tool_call", text: "lab_note" });
      await this.call("tool.lab_end_session", { ...ids, outcome: params.prompt.includes("pausar") ? "pause" : "continue", summary: "Sesión de prueba" });
      emit({ run_id: params.run_id, type: "tool_call", text: "lab_end_session" });
      return { run_id: params.run_id, ok: true, summary: "Sesión de prueba", input_tokens: 0, output_tokens: 0, cost_usd: 0, lab_tokens: 1234, models: [{ model: "claude-haiku-4-5-20251001", tokens: 1234 }] };
    }
    if (params.mode === "scheduled") {
      if (params.prompt.includes("avisar")) await this.call("tool.notify_user", { agent_id: params.agent?.id, run_id: params.run_id, title: "Aviso de prueba", message: params.prompt });
      emit({ run_id: params.run_id, type: "text", text: `Tarea hecha: ${params.task?.name ?? ""}` });
      return { run_id: params.run_id, ok: true, summary: `Tarea hecha: ${params.task?.name ?? ""}`, input_tokens: 0, output_tokens: 0, cost_usd: 0.001 };
    }
    if (params.mode === "summarize") {
      await this.call("tool.memory_remember", { agent_id: params.agent?.id, text: `Resumen de prueba: ${params.history?.length ?? 0} turnos` });
      return { run_id: params.run_id, ok: true, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0 };
    }
    if (params.prompt.startsWith("lab_run:")) {
      // Para los tests de la app: un chat intenta lab_run con la sesión de estudio indicada (debe rechazarse).
      const text = await this.call("tool.lab_run", { agent_id: params.agent?.id, session_id: params.prompt.slice("lab_run:".length), topic_id: "x", script: "a.py" })
        .then(() => "Ejecutado", (err: Error) => `No ejecutado: ${err.message}`);
      emit({ run_id: params.run_id, type: "text", text });
      return { run_id: params.run_id, ok: true, summary: text, input_tokens: 0, output_tokens: 0, cost_usd: 0 };
    }
    if (params.prompt === "memoria") emit({ run_id: params.run_id, type: "text", text: `Memoria: ${params.agent?.memory?.map((m) => m.text).join(" | ") ?? "sin"}` });
    if (params.prompt === "colgado") await new Promise(() => {}); // nunca termina e ignora cancel
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    const { brands } = (await this.call("tool.brands_list", {})) as { brands: unknown[] };
    const summary = `Tienes ${brands.length} marca(s).`;
    emit({ run_id: params.run_id, type: "text", text: summary });
    if (params.prompt === "proponer trade") {
      const r = await this.call("tool.trade_propose", {
        agent_id: params.agent?.id, coin: "BTC", side: "long", size_usd: 450, leverage: 3, entry_type: "market",
        stop_loss: 58_800, take_profit: 63_000, rationale: "Prueba", snapshot: { price: 60_000, account_value: 1_000, network: "testnet" },
      }) as { status: string };
      emit({ run_id: params.run_id, type: "text", text: `Propuesta: ${r.status}` });
    }
    if (params.prompt === "agente") emit({ run_id: params.run_id, type: "text", text: `Agente: ${params.agent?.name ?? "ninguno"}` });
    if (params.prompt === "modelo") emit({ run_id: params.run_id, type: "text", text: `Modelo: ${params.model}` });
    if (params.browser) emit({ run_id: params.run_id, type: "text", text: "Navegador: activado" });
    if (params.history?.length) emit({ run_id: params.run_id, type: "text", text: `Historial: ${params.history.length}` });
    if (params.prompt.includes("crear post") && params.brand) {
      await this.call("tool.posts_create_draft", { brand_id: params.brand.id, network: "instagram", body: "Post de prueba" });
      emit({ run_id: params.run_id, type: "tool_call", text: "posts_create_draft" });
    }
    if (params.prompt.includes("lento")) {
      const aborted = signal.aborted || await new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), 5000);
        signal.addEventListener("abort", () => { clearTimeout(timer); resolve(true); });
      });
      if (aborted) return cancelled(params.run_id);
    }
    return { run_id: params.run_id, ok: true, summary, input_tokens: 0, output_tokens: 0, cost_usd: 0 };
  }
}

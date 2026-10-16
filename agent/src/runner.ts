import { query, createSdkMcpServer, type Options } from "@anthropic-ai/claude-agent-sdk";
import { buildTools, allowedToolsFor, type AppCall, type ToolContext } from "./tools.js";
import { BrowserGuard, BROWSER_ALLOWED_TOOLS } from "./browserGuard.js";
import { buildTradingTools, TRADING_TOOL_NAMES, type RunTrading } from "./trading.js";
import { prepareSkillPlugin, readGuard, type RunSkill, type SkillPlugin } from "./skills.js";
import { buildSystemPrompt, buildUserPrompt, buildSummaryPrompt, type MemoryNote, localToday, timeZoneLabel, type HistoryTurn } from "./prompt.js";

export type Brand = { id: string; name: string; guide: string | null };
export type RunAgent = { id: string; name: string; instructions: string; is_default: boolean; memory?: MemoryNote[] };
/** mode "summarize": run en segundo plano que solo actualiza la memoria del agente. */
export type RunParams = { run_id: string; prompt: string; model: string; agent?: RunAgent; brand?: Brand; history?: HistoryTurn[]; browser?: boolean; mode?: "chat" | "summarize"; skills?: RunSkill[]; trading?: RunTrading };

/** Sin agente (clientes viejos o tests), el run es de Frontbot. */
export const toolContext = (params: RunParams): ToolContext => ({
  agentId: params.agent?.id, isDefault: params.agent?.is_default ?? true, memoryOnly: params.mode === "summarize",
});

const userPrompt = (params: RunParams) => params.mode === "summarize"
  ? buildSummaryPrompt(params.history ?? [], params.agent?.name ?? "Frontbot")
  : buildUserPrompt(params.history ?? [], params.prompt, params.agent?.name);
export type RunEvent = { run_id: string; type: "text" | "tool_call" | "status"; text: string };
export type RunDone = { run_id: string; ok: boolean; summary: string; input_tokens: number; output_tokens: number; cost_usd: number; error?: string };

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
export function buildQueryOptions(params: RunParams, server: ReturnType<typeof createSdkMcpServer>, abortController: AbortController, today: string, plugin?: SkillPlugin): Options {
  const summarize = params.mode === "summarize";
  const browser = params.browser === true && !summarize;
  const skills = !summarize && plugin && plugin.skillNames.length > 0 ? plugin : undefined;
  const hooks = mergeHooks(browser ? browserHooks(new BrowserGuard()) : undefined, skills ? skillReadHooks(skills) : undefined);
  return {
    model: params.model,
    systemPrompt: buildSystemPrompt({ today, timeZone: timeZoneLabel(), brand: params.brand, browser, agent: params.agent, trading: summarize ? undefined : params.trading }),
    tools: summarize ? [] : ["WebSearch", "WebFetch", ...(skills ? ["Skill", "Read"] : [])],
    allowedTools: [...allowedToolsFor(toolContext(params)), ...(browser ? BROWSER_ALLOWED_TOOLS : []), ...(skills ? ["Skill", "Read"] : []),
      ...(params.trading && !summarize ? TRADING_TOOL_NAMES.map((t) => `mcp__frontbot__${t}`) : [])],
    ...(browser ? { extraArgs: { chrome: null } } : {}),
    ...(hooks ? { hooks } : {}),
    ...(skills ? { plugins: [{ type: "local" as const, path: skills.path }], skills: skills.skillNames } : {}),
    mcpServers: { frontbot: server },
    strictMcpConfig: true,
    settingSources: [],
    permissionMode: "dontAsk",
    persistSession: false,
    maxTurns: summarize ? 6 : 30,
    abortController,
  };
}

export class RealRunner implements Runner {
  constructor(private call: AppCall) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (signal.aborted) return cancelled(params.run_id);
    const abortController = new AbortController();
    signal.addEventListener("abort", () => abortController.abort());
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [
      ...buildTools(this.call, toolContext(params)),
      ...(params.trading && params.mode !== "summarize" ? buildTradingTools(this.call, { agentId: params.agent?.id, trading: params.trading }) : []),
    ] });
    const today = localToday();
    const plugin = params.skills?.length ? prepareSkillPlugin(params.skills) : undefined;
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    try {
      const stream = query({ prompt: userPrompt(params), options: buildQueryOptions(params, server, abortController, today, plugin) });
      for await (const msg of stream) {
        if (msg.type === "assistant") {
          for (const block of msg.message.content) {
            if (block.type === "text") emit({ run_id: params.run_id, type: "text", text: block.text });
            if (block.type === "tool_use") emit({ run_id: params.run_id, type: "tool_call", text: block.name.replace("mcp__frontbot__", "").replace("mcp__claude-in-chrome__", "chrome · ") });
          }
        } else if (msg.type === "result") {
          const usage = msg.usage as { input_tokens?: number; output_tokens?: number };
          const base = { run_id: params.run_id, input_tokens: usage.input_tokens ?? 0, output_tokens: usage.output_tokens ?? 0, cost_usd: msg.total_cost_usd ?? 0 };
          if (msg.subtype === "success" && !msg.is_error) return { ...base, ok: true, summary: msg.result };
          return { ...base, ok: false, summary: "", error: msg.subtype === "success" ? msg.result : msg.subtype };
        }
      }
      return signal.aborted ? cancelled(params.run_id) : { ...cancelled(params.run_id), error: "El agente terminó sin resultado" };
    } catch (err) {
      if (signal.aborted) return cancelled(params.run_id);
      return { ...cancelled(params.run_id), error: (err as Error).message };
    } finally {
      plugin?.cleanup();
    }
  }
}

/** Runner guionado, sin red: para probar la app de punta a punta sin gastar tokens. */
export class FakeRunner implements Runner {
  constructor(private call: AppCall) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (params.prompt === "crash") process.exit(1);
    if (params.mode === "summarize") {
      await this.call("tool.memory_remember", { agent_id: params.agent?.id, text: `Resumen de prueba: ${params.history?.length ?? 0} turnos` });
      return { run_id: params.run_id, ok: true, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0 };
    }
    if (params.prompt === "memoria") emit({ run_id: params.run_id, type: "text", text: `Memoria: ${params.agent?.memory?.map((m) => m.text).join(" | ") ?? "sin"}` });
    if (params.prompt === "colgado") await new Promise(() => {}); // nunca termina e ignora cancel
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    const { brands } = (await this.call("tool.brands_list", {})) as { brands: unknown[] };
    const summary = `Tienes ${brands.length} marca(s).`;
    emit({ run_id: params.run_id, type: "text", text: summary });
    if (params.prompt === "proponer trade") {
      const r = await this.call("tool.trade_propose", {
        agent_id: params.agent?.id, coin: "BTC", side: "long", size_usd: 500, leverage: 3, entry_type: "market",
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

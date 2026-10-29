import { tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { LAB_TOOL_SPECS, LAB_ANYWHERE, LAB_CURRENT_TOPIC } from "./lab.js";
import { unaliasSkillPaths, type SkillPlugin } from "./skills.js";
import { buildTradingTools, TRADING_TOOL_NAMES, type RunTrading } from "./trading.js";

export type AppCall = (method: string, params: Record<string, unknown>) => Promise<unknown>;

const network = z.enum(["instagram", "linkedin"]);
const date = z.string().describe("Fecha YYYY-MM-DD o ISO-8601");

export const TOOL_SPECS = [
  { name: "brands_list", description: "Lista las marcas del usuario con sus redes.", shape: {} },
  { name: "brands_get_guide", description: "Lee la guía de marca (markdown) de una marca.", shape: { brand_id: z.string() } },
  { name: "brands_write_guide", description: "Escribe o reemplaza la guía de marca completa en markdown.", shape: { brand_id: z.string(), markdown: z.string() } },
  { name: "brands_list_assets", description: "Lista las imágenes y archivos de una marca (id, tipo, nombre). Usa los id de tipo image en media.", shape: { brand_id: z.string() } },
  { name: "posts_list", description: "Lista posts, opcionalmente por marca y estado (draft, approved, preparing, scheduled, published, archived).", shape: { brand_id: z.string().optional(), status: z.string().optional() } },
  { name: "posts_create_draft", description: "Crea un post en borrador para una marca. No lo publica: el usuario lo revisa y aprueba. media: ids de imágenes de la marca (máx. 10).", shape: { brand_id: z.string(), network, body: z.string(), scheduled_for: date.optional(), media: z.array(z.string()).optional() } },
  { name: "posts_update_draft", description: "Edita un post que sigue en borrador.", shape: { post_id: z.string(), body: z.string().optional(), scheduled_for: date.optional(), media: z.array(z.string()).optional() } },
  { name: "tasks_list", description: "Lista tareas; con date, solo las de ese día.", shape: { date: date.optional() } },
  { name: "tasks_create", description: "Crea una tarea del usuario.", shape: { title: z.string(), due_date: date.optional(), brand_id: z.string().optional() } },
  { name: "tasks_complete", description: "Marca una tarea como hecha.", shape: { task_id: z.string() } },
  { name: "skills_list", description: "Lista los skills de la biblioteca: nombre, descripción, estado (draft/active), si los tienes asignados, si traen scripts y si son borradores tuyos.", shape: {} },
  { name: "skills_create_draft", description: "Crea un skill nuevo (estándar de Anthropic) a partir de tu investigación o de lo que pida el usuario. Queda en BORRADOR asignado a ti: el usuario lo revisa y lo activa. name: kebab-case. description: qué hace y cuándo usarlo. body: el contenido markdown del SKILL.md (sin frontmatter). files: archivos de apoyo opcionales, ruta relativa → texto.", shape: { name: z.string(), description: z.string(), body: z.string(), files: z.record(z.string(), z.string()).optional() } },
  { name: "skills_update_draft", description: "Edita un skill que sigue en borrador y que creaste tú. Los campos omitidos no cambian; files añade o reemplaza archivos.", shape: { name: z.string(), description: z.string().optional(), body: z.string().optional(), files: z.record(z.string(), z.string()).optional() } },
  { name: "skills_run_script", description: "Ejecuta un script de uno de tus skills activos (.py, .sh o .js) en una sandbox sin red. El usuario debe aprobar cada ejecución; si la deniega, no insistas. script: ruta relativa dentro del skill. Se ejecuta desde la carpeta raíz del skill: en args usa rutas relativas a ella (p. ej. data/1h).", shape: { skill: z.string(), script: z.string(), args: z.array(z.string()).optional() } },
  { name: "schedule_list", description: "Lista tus tareas programadas (nombre, instrucción, frecuencia, estado, próxima ejecución).", shape: {} },
  { name: "schedule_create_draft", description: "Crea una tarea programada para ti cuando el usuario te pida hacer algo de forma recurrente. Queda en BORRADOR hasta que el usuario la active. schedule: {kind:'interval', every_minutes (mín. 15), window?:{start:'08:00', end:'22:00'}} | {kind:'daily', time:'09:00'} | {kind:'weekly', days:['mon','fri'], time:'18:00'}. instruction: qué debes hacer en cada ejecución, autocontenida (no habrá nadie para aclarar).", shape: { name: z.string(), instruction: z.string(), schedule: z.record(z.string(), z.unknown()), model: z.string().optional(), max_runs_per_day: z.number().int().min(1).max(96).optional() } },
  { name: "schedule_update_draft", description: "Edita una tarea programada tuya que sigue en borrador. Los campos omitidos no cambian.", shape: { task_id: z.string(), name: z.string().optional(), instruction: z.string().optional(), schedule: z.record(z.string(), z.unknown()).optional(), model: z.string().optional(), max_runs_per_day: z.number().int().min(1).max(96).optional() } },
  { name: "ideas_create", description: "Guarda una oportunidad de negocio investigada, con fuentes, puntaje 1-5 y reporte en markdown.", shape: { title: z.string(), summary: z.string(), sources: z.array(z.string()), score: z.number().int().min(1).max(5), report_markdown: z.string() } },
] as const;

/** Memoria propia de cada agente (el agent_id lo pone el sidecar). */
export const MEMORY_TOOL_SPECS = [
  { name: "memory_list", description: "Lista tus notas de memoria (id, texto, fecha), las más recientes primero.", shape: {} },
  { name: "memory_remember", description: "Guarda en tu memoria algo duradero: preferencias del usuario, decisiones, lecciones de tu trabajo. Máx. 500 caracteres; una idea por nota. Con la memoria llena se borra la nota más antigua.", shape: { text: z.string() } },
  { name: "memory_forget", description: "Borra una nota de tu memoria (por id), p. ej. si quedó obsoleta o el usuario te lo pide.", shape: { memory_id: z.number().int() } },
] as const;

/** Solo en ejecuciones programadas: avisar al usuario cuando hay algo que merece su atención. */
export const SCHEDULED_TOOL_SPECS = [
  { name: "notify_user", description: "Envía un aviso de macOS al usuario. Úsalo SOLO si encontraste algo que merece su atención (una oportunidad, un riesgo, un resultado importante). Si no hay nada relevante, no lo uses. title: corto; message: 1–2 frases.", shape: { title: z.string(), message: z.string() } },
] as const;

/** Solo si el usuario autorizó carpetas para el agente. La app limita las rutas a esas carpetas. */
const absPath = z.string().describe("Ruta absoluta (o con ~) dentro de una carpeta autorizada");
export const FILE_TOOL_SPECS = [
  { name: "files_folders", description: "Lista las carpetas del usuario en las que puedes leer y escribir archivos.", shape: {} },
  { name: "files_list", description: "Lista el contenido de una carpeta (nombre, tipo, tamaño). Máx. 500 entradas.", shape: { path: absPath } },
  { name: "files_read", description: "Lee un archivo de texto (máx. 512 KB; si es más largo, llega truncado). No lee binarios.", shape: { path: absPath } },
  { name: "files_write", description: "Crea o reemplaza un archivo de texto con content completo (máx. 1 MB). El usuario aprueba cada escritura viendo el contenido; si la deniega, no insistas. Para editar, lee el archivo y escribe la versión completa.", shape: { path: absPath, content: z.string() } },
] as const;

/** Solo para el agente por defecto (Frontbot). */
export const DEFAULT_AGENT_TOOL_SPECS = [
  { name: "agents_create_draft", description: "Propone un agente especializado nuevo. Queda en borrador: el usuario lo revisa y lo activa. model: claude-sonnet-5-5, claude-opus-5-5 o claude-haiku-4-5-20251001.", shape: { name: z.string(), description: z.string(), instructions: z.string(), model: z.string().optional(), browser: z.boolean().optional(), icon: z.string().optional().describe("Nombre de un SF Symbol") } },
] as const;

/** Only available when the run has an app-validated trading mandate. */
const tradingCoin = z.string().describe("Símbolo en Hyperliquid, p. ej. BTC o ETH");
export const TRADING_TOOL_SPECS = [
  { name: "market_price", description: "Precio medio actual de una moneda en Hyperliquid.", shape: { coin: tradingCoin } },
  { name: "market_candles", description: "Velas OHLCV recientes.", shape: { coin: tradingCoin, interval: z.string(), count: z.number().int().min(1).max(500) } },
  { name: "market_funding", description: "Funding por hora, open interest y precio mark/oráculo.", shape: { coin: tradingCoin } },
  { name: "market_book", description: "Libro de órdenes de Hyperliquid.", shape: { coin: tradingCoin } },
  { name: "account_state", description: "Valor de cuenta, margen disponible y posiciones.", shape: {} },
  { name: "trade_propose", description: "Propone un trade. La app valida el mandato y conserva el flujo de aprobación. La cotización y el valor de cuenta los agrega Frontbot; no inventes esos datos.", shape: {
    coin: z.string(), side: z.enum(["long", "short"]), size_usd: z.number().positive(), leverage: z.number().int().min(1),
    entry_type: z.enum(["market", "limit"]), entry_price: z.number().positive().optional(), stop_loss: z.number().positive(),
    take_profit: z.number().positive().optional(), rationale: z.string(),
  } },
] as const;

export const ALLOWED_TOOLS = ["WebSearch", "WebFetch", ...TOOL_SPECS.map((t) => `mcp__frontbot__${t.name}`)];

/** Contexto del run: lo pone el sidecar, nunca el modelo. */
export type ToolContext = { agentId?: string; isDefault: boolean; memoryOnly?: boolean; runId?: string; scheduled?: boolean; files?: boolean; trading?: RunTrading; skillPlugin?: SkillPlugin;
  /** Sesión de estudio del laboratorio: lista cerrada de herramientas, sin nada que publique, opere o escriba fuera. */
  study?: { topicId: string; sessionId: string } };

const STUDY_BASE = ["brands_list", "brands_get_guide", "brands_list_assets", "posts_list", "tasks_list", "skills_list"];
const STUDY_MEMORY = ["memory_list", "memory_remember"];

const specsFor = (ctx: ToolContext) => {
  if (ctx.study) {
    // Nadie mira: solo lectura de la app, memoria propia y el laboratorio. Nada que publique, opere o escriba fuera.
    return [
      ...TOOL_SPECS.filter((t) => STUDY_BASE.includes(t.name)),
      ...MEMORY_TOOL_SPECS.filter((t) => STUDY_MEMORY.includes(t.name)),
      ...LAB_TOOL_SPECS,
    ];
  }
  if (ctx.memoryOnly) return [...MEMORY_TOOL_SPECS];
  // En una tarea programada nadie puede aprobar un script: esa herramienta no existe ahí.
  const base = ctx.scheduled ? TOOL_SPECS.filter((t) => t.name !== "skills_run_script") : [...TOOL_SPECS];
  // Tampoco hay nadie para aprobar una escritura: en una tarea programada solo se lee.
  const files = !ctx.files ? [] : ctx.scheduled ? FILE_TOOL_SPECS.filter((t) => t.name !== "files_write") : [...FILE_TOOL_SPECS];
  const lab = LAB_TOOL_SPECS.filter((t) => (LAB_ANYWHERE as readonly string[]).includes(t.name));
  return [...base, ...files, ...MEMORY_TOOL_SPECS, ...lab, ...(ctx.isDefault ? DEFAULT_AGENT_TOOL_SPECS : []), ...(ctx.scheduled ? SCHEDULED_TOOL_SPECS : []), ...(ctx.trading ? TRADING_TOOL_SPECS : [])];
};

/** Nombres exactos (sin prefijo mcp) de la lista cerrada del modo estudio. */
export const STUDY_TOOL_NAMES: string[] = specsFor({ isDefault: false, study: { topicId: "", sessionId: "" } }).map((t) => t.name);

export const allowedToolsFor = (ctx: ToolContext) => [...(ctx.memoryOnly ? [] : ["WebSearch", "WebFetch"]), ...specsFor(ctx).map((t) => `mcp__frontbot__${t.name}`)];

/** Provider-independent Frontbot tool contract shared by Claude and Codex. */
export function frontbotToolSpecs(ctx: ToolContext = { isDefault: true }) {
  return specsFor(ctx);
}

/** Invoke one tool through the app-owned handler, including trusted run context. */
export async function executeFrontbotTool(
  name: string,
  args: Record<string, unknown>,
  call: AppCall,
  ctx: ToolContext = { isDefault: true },
): Promise<{ content: [{ type: "text"; text: string }]; isError?: true }> {
  const spec = specsFor(ctx).find((candidate) => candidate.name === name);
  if (!spec) throw new Error(`Herramienta no permitida: ${name}`);
  // Match the Claude SDK's normal Zod parsing: unknown model-supplied fields are stripped.
  const schema = z.object(spec.shape);
  const parsed = schema.parse(args);
  if (ctx.trading && (TRADING_TOOL_NAMES as readonly string[]).includes(name)) {
    const tradingTool = buildTradingTools(call, { agentId: ctx.agentId, trading: ctx.trading }).find((candidate) => candidate.name === name);
    if (!tradingTool) throw new Error(`Herramienta no permitida: ${name}`);
    return await tradingTool.handler(parsed as never, {} as never) as unknown as Awaited<ReturnType<typeof executeFrontbotTool>>;
  }
  const params: Record<string, unknown> = ctx.agentId ? { ...parsed, agent_id: ctx.agentId } : { ...parsed };
  if (ctx.study) {
    if ((LAB_CURRENT_TOPIC as readonly string[]).includes(spec.name)) {
      params.topic_id = ctx.study.topicId;
      params.session_id = ctx.study.sessionId;
    } else if (spec.name === "lab_read_notebook" && typeof parsed.topic_id !== "string") {
      params.topic_id = ctx.study.topicId;
    }
  }
  if (spec.name === "notify_user" || spec.name === "files_write") params.run_id = ctx.runId;
  if (spec.name === "skills_run_script" && ctx.skillPlugin && Array.isArray(params.args)) {
    params.args = params.args.map((arg) => (typeof arg === "string" ? unaliasSkillPaths(arg, ctx.skillPlugin!) : arg));
  }
  try {
    const result = await call(`tool.${spec.name}`, params);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  } catch (err) {
    return { isError: true, content: [{ type: "text", text: (err as Error).message }] };
  }
}

export function buildTools(call: AppCall, ctx: ToolContext = { isDefault: true }) {
  return frontbotToolSpecs(ctx).map((spec) =>
    tool(spec.name, spec.description, spec.shape, async (args: Record<string, unknown>) => {
      try {
        return await executeFrontbotTool(spec.name, args, call, ctx);
      } catch (err) {
        return { isError: true, content: [{ type: "text" as const, text: (err as Error).message }] };
      }
    }),
  );
}

import { tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

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
  { name: "ideas_create", description: "Guarda una oportunidad de negocio investigada, con fuentes, puntaje 1-5 y reporte en markdown.", shape: { title: z.string(), summary: z.string(), sources: z.array(z.string()), score: z.number().int().min(1).max(5), report_markdown: z.string() } },
] as const;

/** Memoria propia de cada agente (el agent_id lo pone el sidecar). */
export const MEMORY_TOOL_SPECS = [
  { name: "memory_list", description: "Lista tus notas de memoria (id, texto, fecha), las más recientes primero.", shape: {} },
  { name: "memory_remember", description: "Guarda en tu memoria algo duradero: preferencias del usuario, decisiones, lecciones de tu trabajo. Máx. 500 caracteres; una idea por nota. Con la memoria llena se borra la nota más antigua.", shape: { text: z.string() } },
  { name: "memory_forget", description: "Borra una nota de tu memoria (por id), p. ej. si quedó obsoleta o el usuario te lo pide.", shape: { memory_id: z.number().int() } },
] as const;

/** Solo para el agente por defecto (Frontbot). */
export const DEFAULT_AGENT_TOOL_SPECS = [
  { name: "agents_create_draft", description: "Propone un agente especializado nuevo. Queda en borrador: el usuario lo revisa y lo activa. model: claude-sonnet-5-5, claude-opus-5-5 o claude-haiku-4-5-20251001.", shape: { name: z.string(), description: z.string(), instructions: z.string(), model: z.string().optional(), browser: z.boolean().optional(), icon: z.string().optional().describe("Nombre de un SF Symbol") } },
] as const;

export const ALLOWED_TOOLS = ["WebSearch", "WebFetch", ...TOOL_SPECS.map((t) => `mcp__frontbot__${t.name}`)];

/** Contexto del run: lo pone el sidecar, nunca el modelo. */
export type ToolContext = { agentId?: string; isDefault: boolean; memoryOnly?: boolean };

const specsFor = (ctx: ToolContext) => {
  if (ctx.memoryOnly) return [...MEMORY_TOOL_SPECS];
  return [...TOOL_SPECS, ...MEMORY_TOOL_SPECS, ...(ctx.isDefault ? DEFAULT_AGENT_TOOL_SPECS : [])];
};

export const allowedToolsFor = (ctx: ToolContext) => [...(ctx.memoryOnly ? [] : ["WebSearch", "WebFetch"]), ...specsFor(ctx).map((t) => `mcp__frontbot__${t.name}`)];

export function buildTools(call: AppCall, ctx: ToolContext = { isDefault: true }) {
  return specsFor(ctx).map((spec) =>
    tool(spec.name, spec.description, spec.shape, async (args: Record<string, unknown>) => {
      try {
        const params = ctx.agentId ? { ...args, agent_id: ctx.agentId } : args;
        const result = await call(`tool.${spec.name}`, params);
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
      } catch (err) {
        return { isError: true, content: [{ type: "text" as const, text: (err as Error).message }] };
      }
    }),
  );
}

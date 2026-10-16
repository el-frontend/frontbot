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

export const ALLOWED_TOOLS = ["WebSearch", "WebFetch", ...TOOL_SPECS.map((t) => `mcp__frontbot__${t.name}`)];

export function buildTools(call: AppCall) {
  return TOOL_SPECS.map((spec) =>
    tool(spec.name, spec.description, spec.shape, async (args: Record<string, unknown>) => {
      try {
        const result = await call(`tool.${spec.name}`, args);
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
      } catch (err) {
        return { isError: true, content: [{ type: "text" as const, text: (err as Error).message }] };
      }
    }),
  );
}

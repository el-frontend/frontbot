// Laboratorio: herramientas del agente para estudiar temas por su cuenta.
// Todas llaman a la app (`tool.lab_*`); el sidecar pone agent_id, topic_id y session_id, nunca el modelo.
import { z } from "zod";

/** Una sesión de estudio: lo que la app le pasa al sidecar para correrla. */
export type RunStudy = {
  topic_id: string; session_id: string; question: string; why: string;
  budget_tokens: number; allow_opus: boolean; notebook: unknown;
};

const noteKind = z.enum(["hypothesis", "test", "result", "conclusion", "model_note", "feedback", "note"]);
const evidence = z.enum(["weak", "medium", "strong"]);

export const LAB_TOOL_SPECS = [
  { name: "lab_open_topic", description: "Abre un tema de estudio: algo concreto que quieres aprender o comprobar. question: hasta 300 caracteres. why: hasta 1000, para qué le sirve al usuario. Falla si ya tienes 3 temas abiertos: pausa o abandona alguno antes.", shape: { question: z.string().max(300), why: z.string().max(1000) } },
  { name: "lab_list_topics", description: "Lista tus temas del laboratorio con su estado y conclusión.", shape: {} },
  { name: "lab_resume_topic", description: "Reanuda un tema pausado (pasa de paused a studying).", shape: { topic_id: z.string() } },
  { name: "lab_note", description: "Añade una entrada al cuaderno del tema en curso. kind: hypothesis, test, result, conclusion, model_note, feedback o note. evidence: weak, medium o strong, según lo que respalda la entrada. sources: enlaces o archivos en que se apoya. Máx. 4000 caracteres de texto.", shape: { kind: noteKind, text: z.string().max(4000), evidence: evidence.optional(), sources: z.array(z.string()).optional() } },
  { name: "lab_read_notebook", description: "Lee el cuaderno de un tema. Sin topic_id, el del tema en curso. Úsalo para reutilizar lo aprendido en otros temas.", shape: { topic_id: z.string().optional() } },
  { name: "lab_write_file", description: "Escribe un archivo de texto en el espacio de trabajo del tema o en shared/. Ruta relativa, sin '..'. Máx. 1 MB por archivo y 200 MB en total.", shape: { path: z.string(), content: z.string() } },
  { name: "lab_read_file", description: "Lee un archivo del espacio del tema, de shared/, de un dataset (dataset:<nombre>/…) o de un skill asignado (skill:<nombre>/…). Ruta relativa.", shape: { path: z.string() } },
  { name: "lab_list_files", description: "Lista los archivos de una carpeta del espacio del tema (o de shared/). Sin dir, la raíz del tema.", shape: { dir: z.string().optional() } },
  { name: "lab_run", description: "Ejecuta un script del espacio del tema en una sandbox sin red, sin pedir aprobación al usuario (máx. 5 min). Corre desde la carpeta del tema: usa rutas relativas, y los datasets están en dataset:<nombre>/… Devuelve stdout, stderr y exit (20 KB máx.). Lo que el script escribe queda en el espacio del tema.", shape: { script: z.string(), args: z.array(z.string()).optional() } },
  { name: "lab_list_datasets", description: "Lista los datasets compartidos: nombre, descripción, archivos y tamaño.", shape: {} },
  { name: "lab_fetch_dataset", description: "Pide a la app que descargue datos por https (solo GET, sin credenciales) a un dataset nuevo. Los datasets son inmutables: si el nombre ya existe, falla y eliges otro (p. ej. btc-4h-2026-10). 500 MB por dataset, 2 GB en total. Luego los lees con lab_run en dataset:<nombre>/…", shape: { name: z.string(), urls: z.array(z.string()).min(1).max(50), description: z.string() } },
  { name: "lab_end_session", description: "Cierra la sesión de estudio. outcome: continue (seguirás otro día), pause, resolve (exige conclusion) o abandon. summary: qué hiciste y qué sigue.", shape: { outcome: z.enum(["continue", "pause", "resolve", "abandon"]), summary: z.string(), conclusion: z.string().optional() } },
  { name: "lab_propose_skill", description: "Propone convertir lo aprendido en un skill. No se activa: el usuario lo revisa. kind: new o update (el skill debe ser tuyo). skill_name: kebab-case. body: markdown del SKILL.md sin frontmatter. files: hasta 20 archivos de apoyo (200 KB cada uno), ruta relativa → texto. evidence_summary: qué evidencia lo respalda.", shape: { kind: z.enum(["new", "update"]), skill_name: z.string(), description: z.string(), body: z.string(), files: z.record(z.string(), z.string()).optional(), evidence_summary: z.string() } },
] as const;

/** Las que existen fuera del modo estudio (chat, tareas programadas). */
export const LAB_ANYWHERE = ["lab_open_topic", "lab_list_topics", "lab_resume_topic", "lab_read_notebook", "lab_list_datasets"] as const;

/** Herramientas que actúan sobre el tema en curso: el sidecar fija su topic_id y session_id. */
export const LAB_CURRENT_TOPIC = ["lab_note", "lab_write_file", "lab_read_file", "lab_list_files", "lab_run", "lab_end_session", "lab_propose_skill", "lab_fetch_dataset"] as const;

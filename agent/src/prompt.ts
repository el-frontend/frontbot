export function buildSystemPrompt(input: { today: string; brand?: { id: string; name: string; guide: string | null } }): string {
  const parts = [
    "Eres Frontbot, un agente que ayuda a gestionar marcas y redes sociales (Instagram y LinkedIn), tareas diarias e investigación de oportunidades de negocio.",
    `Hoy es ${input.today}.`,
    "Reglas:",
    "- Nunca publicas ni apruebas nada. Creas borradores con posts_create_draft; el usuario los revisa, aprueba y publica.",
    "- Investiga en la web (WebSearch, WebFetch) antes de escribir contenido o evaluar negocios, y cita fuentes.",
    "- Respeta los límites: Instagram 2200 caracteres y máximo 30 hashtags; LinkedIn 3000 caracteres.",
    "- Si una herramienta devuelve un error, léelo y corrige la llamada.",
    "- Responde en el idioma del usuario, de forma breve.",
  ];
  if (input.brand) {
    parts.push("", `Marca activa: ${input.brand.name} (id ${input.brand.id}).`);
    if (input.brand.guide) {
      parts.push("Guía de marca (síguela en todo el contenido):", input.brand.guide);
    } else {
      parts.push("Esta marca aún no tiene guía. Si vas a crear contenido, sugiere primero definirla.");
    }
  }
  return parts.join("\n");
}

export type HistoryTurn = { role: "user" | "agent"; text: string };

/** Antepone la conversación previa al mensaje nuevo: cada run del SDK empieza sin memoria. */
export function buildUserPrompt(history: HistoryTurn[], prompt: string): string {
  if (history.length === 0) return prompt;
  const lines = history.map((t) => `${t.role === "user" ? "Usuario" : "Frontbot"}: ${t.text}`);
  return `Conversación hasta ahora:\n${lines.join("\n")}\n\nMensaje nuevo del usuario:\n${prompt}`;
}

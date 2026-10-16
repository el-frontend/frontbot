import { describe, it, expect } from "vitest";
import { buildSystemPrompt } from "../src/prompt.js";

describe("buildSystemPrompt", () => {
  it("includes today's date and the no-publish rule", () => {
    const p = buildSystemPrompt({ today: "2026-10-13" });
    expect(p).toContain("2026-10-13");
    expect(p).toContain("Nunca publicas");
    expect(p).not.toContain("Guía de marca");
  });

  it("injects the brand guide when a brand is active", () => {
    const p = buildSystemPrompt({ today: "2026-10-13", brand: { id: "b1", name: "Café Sol", guide: "# Tono\nCercano" } });
    expect(p).toContain("Marca activa: Café Sol (id b1)");
    expect(p).toContain("# Tono\nCercano");
  });

  it("asks to define a guide when the brand has none", () => {
    const p = buildSystemPrompt({ today: "2026-10-13", brand: { id: "b1", name: "Café Sol", guide: null } });
    expect(p).toContain("aún no tiene guía");
  });
});

import { buildUserPrompt } from "../src/prompt.js";

describe("buildUserPrompt", () => {
  it("returns the prompt unchanged without history", () => {
    expect(buildUserPrompt([], "hola")).toBe("hola");
  });

  it("prefixes the conversation so far", () => {
    const p = buildUserPrompt([{ role: "user", text: "¿tono?" }, { role: "agent", text: "Cercano" }], "sigue");
    expect(p).toBe("Conversación hasta ahora:\nUsuario: ¿tono?\nFrontbot: Cercano\n\nMensaje nuevo del usuario:\nsigue");
  });
});

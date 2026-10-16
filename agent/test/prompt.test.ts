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

describe("buildSystemPrompt per agent", () => {
  it("defaults to Frontbot", () => {
    expect(buildSystemPrompt({ today: "2026-10-16" })).toContain("Eres Frontbot");
  });

  it("uses the agent's name and instructions and keeps the shared rules", () => {
    const p = buildSystemPrompt({ today: "2026-10-16", agent: { name: "Crypto Trader", instructions: "Nunca sin stop loss." } });
    expect(p).toContain("Eres Crypto Trader");
    expect(p).toContain("Nunca sin stop loss.");
    expect(p).toContain("Nunca publicas");
    expect(p).toContain("2026-10-16");
  });

  it("labels history turns with the agent's name", () => {
    expect(buildUserPrompt([{ role: "agent", text: "hola" }], "sigue", "Crypto Trader")).toContain("Crypto Trader: hola");
  });
});

describe("buildSystemPrompt memory", () => {
  it("lists the agent's memory with dates and asks to keep it useful", () => {
    const p = buildSystemPrompt({ today: "2026-10-16", agent: { name: "T", instructions: "x", memory: [{ text: "Opera BTC en 4h", date: "2026-10-15" }] } });
    expect(p).toContain("Tu memoria");
    expect(p).toContain("- [2026-10-15] Opera BTC en 4h");
    expect(p).toContain("memory_remember");
  });

  it("says so when memory is empty", () => {
    expect(buildSystemPrompt({ today: "2026-10-16", agent: { name: "T", instructions: "x", memory: [] } })).toContain("Tu memoria está vacía");
  });
});

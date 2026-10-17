import { describe, it, expect } from "vitest";
import { buildSystemPrompt } from "../src/prompt.js";

describe("buildSystemPrompt", () => {
  it("includes today's date and the no-publish rule", () => {
    const p = buildSystemPrompt({ today: "2026-10-13" });
    expect(p).toContain("2026-10-13");
    expect(p).toContain("Nunca publicas");
    expect(p).not.toContain("Guía de marca");
  });

  it("system prompt mentions the lab", () => {
    const p = buildSystemPrompt({ today: "2026-10-13" });
    expect(p).toContain("lab_open_topic");
  });

  it("injects the brand guide when a brand is active", () => {
    const p = buildSystemPrompt({ today: "2026-10-13", brand: { id: "b1", name: "Café Sol", guide: "# Tono\nCercano" } });
    expect(p).toContain("Marca activa: Café Sol (id b1)");
    expect(p).toContain("# Tono\nCercano");
  });

  it("study mode drops trading, notify, drafts, files and browser sections", () => {
    const trading = { network: "mainnet" as const, mandate: { mode: "approve", max_risk_pct: 1, max_leverage: 3, coins: ["BTC"], max_trades_per_day: 2 } };
    const full = buildSystemPrompt({ today: "2026-10-13", trading, browser: true, folders: ["/tmp/x"], scheduledTask: "t" });
    for (const s of ["trade_propose", "notify_user", "skills_create_draft", "files_list", "Navegador", "posts_create_draft"]) expect(full).toContain(s);
    const p = buildSystemPrompt({ today: "2026-10-13", trading, browser: true, folders: ["/tmp/x"], scheduledTask: "t", study: true });
    for (const s of ["trade_propose", "account_state", "notify_user", "skills_create_draft", "files_", "Navegador", "posts_create_draft", "memory_forget"]) expect(p).not.toContain(s);
    expect(p).toContain("Nunca publicas");
    expect(p).toContain("2026-10-13");
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

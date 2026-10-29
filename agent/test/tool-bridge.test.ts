import { randomUUID } from "node:crypto";
import { connect } from "node:net";
import { describe, expect, it } from "vitest";
import { createToolBridge, requestToolBridge, TOOL_BRIDGE_REQUEST_TIMEOUT_MS } from "../src/tool-bridge.js";

describe("authenticated Frontbot tool bridge", () => {
  it("forwards a valid allowlisted call through the Swift RPC callback and returns the result", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const bridge = await createToolBridge(async (method, params) => {
      calls.push([method, params]);
      return { brands: [{ id: "b1" }] };
    }, { agentId: "agent-1", isDefault: false });
    try {
      const result = await requestToolBridge(bridge, { op: "call", name: "brands_list", arguments: {} });
      expect(result).toEqual({ content: [{ type: "text", text: '{"brands":[{"id":"b1"}]}' }] });
      expect(calls).toEqual([["tool.brands_list", { agent_id: "agent-1" }]]);
    } finally { await bridge.close(); }
  });

  it("returns Swift tool errors as MCP error results", async () => {
    const bridge = await createToolBridge(async () => { throw new Error("La escritura requiere aprobación."); }, { isDefault: false, files: true, runId: "r1" });
    try {
      const result = await requestToolBridge<{ isError?: boolean; content: { text: string }[] }>(bridge, {
        op: "call", name: "files_write", arguments: { path: "/tmp/demo.txt", content: "x" },
      });
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toBe("La escritura requiere aprobación.");
    } finally { await bridge.close(); }
  });

  it("rejects invalid tokens before forwarding", async () => {
    const calls: string[] = [];
    const bridge = await createToolBridge(async (method) => { calls.push(method); return {}; }, { isDefault: false });
    try {
      const response = await new Promise<{ bridgeError: string }>((resolve, reject) => {
        const socket = connect(bridge.socketPath);
        let buffer = "";
        socket.on("connect", () => socket.write(`${JSON.stringify({ op: "call", token: "0".repeat(64), request_id: randomUUID(), name: "brands_list", arguments: {} })}\n`));
        socket.on("data", (chunk) => { buffer += chunk.toString(); });
        socket.on("end", () => { try { resolve(JSON.parse(buffer)); } catch (error) { reject(error); } });
        socket.on("error", reject);
      });
      expect(response.bridgeError).toBe("Token de puente inválido.");
      expect(calls).toEqual([]);
    } finally { await bridge.close(); }
  });

  it("allows delayed approvals beyond the idle timeout and deduplicates identical in-flight retries", async () => {
    expect(TOOL_BRIDGE_REQUEST_TIMEOUT_MS).toBe(200_000);
    let dispatches = 0;
    const bridge = await createToolBridge(async (method) => {
      expect(method).toBe("tool.files_write");
      dispatches++;
      await new Promise((resolve) => setTimeout(resolve, 60));
      return { written: "/tmp/a" };
    }, { isDefault: false, files: true }, { idleMs: 15, requestMs: 250 });
    try {
      const request = { op: "call", name: "files_write", arguments: { path: "/tmp/a", content: "approved" } };
      // Identical calls while approval is pending share one Swift RPC request instead of running twice.
      const first = requestToolBridge(bridge, request, 250);
      const retry = requestToolBridge(bridge, request, 250);
      await expect(first).resolves.toEqual({ content: [{ type: "text", text: '{"written":"/tmp/a"}' }] });
      await expect(retry).resolves.toEqual({ content: [{ type: "text", text: '{"written":"/tmp/a"}' }] });
      expect(dispatches).toBe(1);
    } finally { await bridge.close(); }
  });

  it("returns a correlated timeout while retaining the pending dispatch to prevent a duplicate", async () => {
    let dispatches = 0;
    const bridge = await createToolBridge(async () => {
      dispatches++;
      await new Promise((resolve) => setTimeout(resolve, 100));
      return { approved: true };
    }, { isDefault: false, files: true }, { idleMs: 1_000, requestMs: 30 });
    try {
      const request = { op: "call", name: "files_write", arguments: { path: "/tmp/a", content: "approved" } };
      await expect(requestToolBridge(bridge, request, 30)).rejects.toThrow(/superó el plazo.*No repitas esta acción/);
      await expect(requestToolBridge(bridge, request, 30)).rejects.toThrow(/superó el plazo.*No repitas esta acción/);
      expect(dispatches).toBe(1);
    } finally { await bridge.close(); }
  });

  it("rejects malformed requests and unknown or context-excluded tools", async () => {
    const calls: string[] = [];
    const bridge = await createToolBridge(async (method) => { calls.push(method); return {}; }, { isDefault: false });
    try {
      await expect(requestToolBridge(bridge, { op: "unknown" }))
        .rejects.toThrow("Solicitud MCP inválida");
      await expect(requestToolBridge(bridge, { op: "call", name: "trade_execute", arguments: {} }))
        .rejects.toThrow("Herramienta no permitida");
      await expect(requestToolBridge(bridge, { op: "call", name: "files_write", arguments: { path: "/tmp/a", content: "x" } }))
        .rejects.toThrow("Herramienta no permitida");
      expect(calls).toEqual([]);
    } finally { await bridge.close(); }
  });

  it("rejects malformed JSON at the socket boundary", async () => {
    const bridge = await createToolBridge(async () => ({}), { isDefault: false });
    try {
      const error = await new Promise<string>((resolve, reject) => {
        const socket = connect(bridge.socketPath);
        let response = "";
        socket.on("connect", () => socket.write("{broken\n"));
        socket.on("data", (chunk) => { response += chunk.toString(); });
        socket.on("end", () => {
          try { resolve(JSON.parse(response).bridgeError); } catch (err) { reject(err); }
        });
        socket.on("error", reject);
      });
      expect(error).toBe("Solicitud JSON inválida.");
    } finally { await bridge.close(); }
  });

  it("keeps scheduled notification and file-write run identity inside the trusted context", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const bridge = await createToolBridge(async (method, params) => { calls.push([method, params]); return { ok: true }; }, {
      agentId: "a1", isDefault: false, files: true, scheduled: true, runId: "scheduled-1",
    });
    try {
      const listed = await requestToolBridge<{ tools: { name: string }[] }>(bridge, { op: "list" });
      expect(listed.tools.map((tool) => tool.name)).toContain("notify_user");
      expect(listed.tools.map((tool) => tool.name)).not.toContain("files_write");
      await requestToolBridge(bridge, { op: "call", name: "notify_user", arguments: { title: "Revisar", message: "Resultado" } });
      expect(calls).toEqual([["tool.notify_user", { title: "Revisar", message: "Resultado", agent_id: "a1", run_id: "scheduled-1" }]]);
    } finally { await bridge.close(); }
  });

  it("forwards script, memory, and trading proposal actions to their Swift tool handlers", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const bridge = await createToolBridge(async (method, params) => { calls.push([method, params]); return { ok: true }; }, {
      agentId: "a-trader", isDefault: false, runId: "trade-run", trading: true,
    });
    try {
      const names = (await requestToolBridge<{ tools: { name: string }[] }>(bridge, { op: "list" })).tools.map((tool) => tool.name);
      expect(names).toContain("skills_run_script");
      expect(names).toContain("memory_remember");
      expect(names).toContain("trade_propose");
      await requestToolBridge(bridge, { op: "call", name: "skills_run_script", arguments: { skill: "report", script: "run.py", args: ["--safe"] } });
      await requestToolBridge(bridge, { op: "call", name: "memory_remember", arguments: { text: "preferencias" } });
      await requestToolBridge(bridge, { op: "call", name: "trade_propose", arguments: {
        coin: "BTC", side: "long", size_usd: 200, leverage: 2, entry_type: "market", stop_loss: 59000, rationale: "setup",
      } });
      expect(calls.map(([method]) => method)).toEqual(["tool.skills_run_script", "tool.memory_remember", "tool.trade_propose"]);
      expect(calls[0][1]).toEqual({ skill: "report", script: "run.py", args: ["--safe"], agent_id: "a-trader" });
      expect(calls[1][1]).toEqual({ text: "preferencias", agent_id: "a-trader" });
      expect(calls[2][1]).toMatchObject({ agent_id: "a-trader", coin: "BTC", stop_loss: 59000 });
    } finally { await bridge.close(); }
  });
});

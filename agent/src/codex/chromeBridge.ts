// Chrome del usuario para runs de Codex: el MCP de Claude in Chrome (`claude --claude-in-chrome-mcp`)
// como cliente, y cada llamada pasa por el mismo BrowserGuard que en los runs de Claude.
// El Chrome propio de Codex no sirve: el modelo lo maneja escribiendo JavaScript y no hay guardián posible.
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { BrowserGuard, BROWSER_ALLOWED_TOOLS } from "../browserGuard.js";
import type { DynamicTool } from "./launch.js";

const PREFIX = "mcp__claude-in-chrome__";
const ALLOWED = new Set(BROWSER_ALLOWED_TOOLS.map((t) => t.slice(PREFIX.length)));
const NOT_ALLOWED = "Esta herramienta del navegador no está permitida en Frontbot.";

/** El binario de Claude que ya trae el sidecar (el mismo que usa el Agent SDK). */
export function claudeChromeCommand(env: NodeJS.ProcessEnv): { command: string; args: string[] } {
  if (env.FRONTBOT_CLAUDE_BIN) return { command: env.FRONTBOT_CLAUDE_BIN, args: ["--claude-in-chrome-mcp"] };
  const require = createRequire(import.meta.url);
  const pkg = require.resolve(`@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}/package.json`);
  return { command: join(dirname(pkg), "claude"), args: ["--claude-in-chrome-mcp"] };
}

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void };

export class ChromeBridge {
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private buffer = "";
  private guard = new BrowserGuard();
  private queue: Promise<unknown> = Promise.resolve();
  tools: DynamicTool[] = [];

  private constructor(private child: ChildProcessWithoutNullStreams) {
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (c: string) => this.read(c));
    child.stderr.on("data", () => undefined);
    child.stdin.on("error", () => undefined);
    const fail = () => { for (const p of this.pending.values()) p.reject(new Error("Chrome no está disponible.")); this.pending.clear(); };
    child.on("exit", fail);
    child.on("error", fail);
  }

  /** null si la extensión o el servidor no responden a tiempo: el run sigue, sin Chrome. */
  static async start(cmd: { command: string; args: string[] }, timeoutMs = 15_000): Promise<ChromeBridge | null> {
    let bridge: ChromeBridge;
    try {
      bridge = new ChromeBridge(spawn(cmd.command, cmd.args, { stdio: ["pipe", "pipe", "pipe"] }));
    } catch {
      return null;
    }
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<null>((r) => { timer = setTimeout(() => r(null), timeoutMs); });
    const ready = (async () => {
      await bridge.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "frontbot", version: "0.1.0" } });
      bridge.write({ jsonrpc: "2.0", method: "notifications/initialized" });
      const list = await bridge.request("tools/list", {});
      bridge.tools = (Array.isArray(list?.tools) ? list.tools : [])
        .filter((t: any) => typeof t?.name === "string" && ALLOWED.has(t.name))
        .map((t: any): DynamicTool => ({ type: "function", name: t.name, description: String(t.description ?? ""), inputSchema: t.inputSchema ?? { type: "object" } }));
      return bridge;
    })().catch(() => null);
    const result = await Promise.race([ready, timeout]);
    clearTimeout(timer);
    if (!result) bridge.close();
    return result;
  }

  has(name: string) { return this.tools.some((t) => t.name === name); }

  /** Una llamada a la vez: el guardián decide con el estado del navegador que dejó la anterior. */
  call(name: string, args: Record<string, unknown>): Promise<{ success: boolean; text: string }> {
    const next = this.queue.then(() => this.callNow(name, args));
    this.queue = next.catch(() => undefined);
    return next;
  }

  private async callNow(name: string, args: Record<string, unknown>): Promise<{ success: boolean; text: string }> {
    if (!this.has(name)) return { success: false, text: NOT_ALLOWED };
    const decision = this.guard.beforeTool(PREFIX + name, args);
    if (!decision.allow) return { success: false, text: decision.reason ?? NOT_ALLOWED };
    try {
      const res = await this.request("tools/call", { name, arguments: args });
      this.guard.afterTool(PREFIX + name, res);
      const text = (Array.isArray(res?.content) ? res.content : []).map((c: any) => (typeof c?.text === "string" ? c.text : "")).join("\n");
      return { success: res?.isError !== true, text };
    } catch (e) {
      return { success: false, text: (e as Error).message };
    }
  }

  close() { if (this.child.exitCode === null && !this.child.killed) this.child.kill("SIGTERM"); }

  private request(method: string, params: unknown): Promise<any> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  private write(msg: Record<string, unknown>) { if (!this.child.stdin.destroyed) this.child.stdin.write(JSON.stringify(msg) + "\n"); }

  private read(chunk: string) {
    this.buffer += chunk;
    let i: number;
    while ((i = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, i);
      this.buffer = this.buffer.slice(i + 1);
      if (!line.trim()) continue;
      let msg: any;
      try { msg = JSON.parse(line); } catch { continue; }
      const p = typeof msg.id === "number" ? this.pending.get(msg.id) : undefined;
      if (!p || msg.method !== undefined) continue;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(String(msg.error.message ?? "Error del navegador")));
      else p.resolve(msg.result);
    }
  }
}

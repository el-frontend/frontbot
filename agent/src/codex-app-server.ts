import { StringDecoder } from "node:string_decoder";
import type { ChildProcess } from "node:child_process";
import { codexEvent, jsonRpcNotification, jsonRpcRequest, parseCodexLine, type CodexEvent, type JsonObject } from "./codex-protocol.js";

export class CodexAppServerError extends Error {
  constructor(message: string, readonly code?: number | string) { super(message); this.name = "CodexAppServerError"; }
}

type Pending = { resolve(value: unknown): void; reject(error: Error): void; timer: NodeJS.Timeout };

/** JSONL stdio client for the installed Codex app-server. */
export class CodexAppServer {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly decoder = new StringDecoder("utf8");
  private buffer = "";
  private closed = false;
  private threadId?: string;
  private turnId?: string;
  private readonly listeners = new Set<(event: CodexEvent) => void>();
  private readonly errorListeners = new Set<(error: Error) => void>();

  constructor(private readonly child: ChildProcess, private readonly timeoutMs = 30_000) {
    child.stdout?.on("data", (chunk: Buffer | string) => this.read(chunk));
    // Stderr is deliberately drained by spawn's pipe, but never retained or logged:
    // child diagnostics may echo credentials or per-run MCP configuration.
    child.stderr?.on("data", () => undefined);
    child.on("error", (error) => this.fail(new CodexAppServerError(`No se pudo iniciar Codex app-server: ${error.message}`)));
    child.on("exit", (code, signal) => {
      if (!this.closed) this.fail(new CodexAppServerError(`Codex app-server terminó (${signal ?? code ?? "sin código"}).`));
    });
  }

  onEvent(listener: (event: CodexEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onError(listener: (error: Error) => void): () => void {
    this.errorListeners.add(listener);
    return () => this.errorListeners.delete(listener);
  }

  private emit(event: CodexEvent) { for (const listener of this.listeners) listener(event); }

  private fail(error: Error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    for (const listener of this.errorListeners) listener(error);
  }

  private read(chunk: Buffer | string) {
    this.buffer += typeof chunk === "string" ? chunk : this.decoder.write(chunk);
    if (Buffer.byteLength(this.buffer) > 2 * 1024 * 1024) {
      this.fail(new CodexAppServerError("Codex app-server envió una línea demasiado grande."));
      this.child.kill();
      return;
    }
    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      const parsed = parseCodexLine(line);
      if (parsed.kind === "invalid") {
        this.fail(new CodexAppServerError(parsed.error));
        this.child.kill();
        return;
      }
      if (parsed.kind === "response") {
        const id = Number(parsed.id);
        const pending = this.pending.get(id);
        if (!pending) continue;
        this.pending.delete(id);
        clearTimeout(pending.timer);
        if (parsed.error) pending.reject(new CodexAppServerError(this.responseError(parsed.error), parsed.error.code as number | string | undefined));
        else pending.resolve(parsed.result);
        continue;
      }
      if (parsed.kind === "serverRequest") {
        // app-server approval requests cannot map to Frontbot's per-path and per-write approvals.
        // Always deny native shell, native filesystem changes and permission escalation requests.
        if (parsed.method === "item/commandExecution/requestApproval") {
          this.write(`${JSON.stringify({ id: parsed.id, result: { decision: "decline" } })}\n`);
        } else if (parsed.method === "item/fileChange/requestApproval" || parsed.method === "item/permissions/requestApproval") {
          this.write(`${JSON.stringify({ id: parsed.id, result: { decision: "decline" } })}\n`);
        } else {
          this.write(`${JSON.stringify({ id: parsed.id, error: { code: -32601, message: "Unsupported app-server request." } })}\n`);
        }
        const event = codexEvent(parsed);
        if (event) this.emit(event);
        continue;
      }
      const event = this.bindLifecycle(parsed.method, parsed.params);
      if (event) this.emit(event);
    }
  }

  private bindLifecycle(method: string, params: JsonObject): CodexEvent | undefined {
    if (method === "thread/started" && typeof params.thread === "object" && params.thread !== null) {
      const thread = params.thread as JsonObject;
      if (typeof thread.id === "string") this.threadId = thread.id;
    }
    if (method === "turn/started" && typeof params.turn === "object" && params.turn !== null) {
      const turn = params.turn as JsonObject;
      if (typeof turn.id === "string") this.turnId = turn.id;
    }
    if (method === "turn/completed" && typeof params.turn === "object" && params.turn !== null) {
      const turn = params.turn as JsonObject;
      if (turn.status === "completed" || turn.status === "interrupted" || turn.status === "failed") this.turnId = undefined;
    }
    return codexEvent({ kind: "notification", method, params });
  }

  private responseError(error: JsonObject): string {
    if (typeof error.message === "string") return error.message.slice(0, 1000);
    return "Codex app-server rechazó una solicitud.";
  }

  private write(data: string) {
    if (this.closed || !this.child.stdin || this.child.stdin.destroyed) throw new CodexAppServerError("El canal de Codex app-server está cerrado.");
    this.child.stdin.write(data);
  }

  notify(method: string, params: JsonObject = {}) { this.write(jsonRpcNotification(method, params)); }

  request(method: string, params: JsonObject, timeoutMs = this.timeoutMs): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new CodexAppServerError(`Codex app-server agotó el tiempo esperando ${method}.`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try { this.write(jsonRpcRequest(id, method, params)); }
      catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error as Error);
      }
    });
  }

  async initialize(): Promise<void> {
    await this.request("initialize", {
      clientInfo: { name: "frontbot", title: "Frontbot", version: "0.1.0" },
      capabilities: { experimentalApi: false, requestAttestation: false },
    });
    this.notify("initialized");
  }

  async startThread(params: JsonObject, timeoutMs = this.timeoutMs): Promise<string> {
    const response = await this.request("thread/start", params, timeoutMs) as JsonObject;
    const thread = response?.thread;
    if (!thread || typeof thread !== "object" || typeof (thread as JsonObject).id !== "string") throw new CodexAppServerError("Codex app-server no devolvió el hilo esperado.");
    this.threadId = (thread as JsonObject).id as string;
    return this.threadId;
  }

  async startTurn(params: JsonObject, timeoutMs = this.timeoutMs): Promise<string> {
    const response = await this.request("turn/start", params, timeoutMs) as JsonObject;
    const turn = response?.turn;
    if (!turn || typeof turn !== "object" || typeof (turn as JsonObject).id !== "string") throw new CodexAppServerError("Codex app-server no devolvió el turno esperado.");
    this.turnId = (turn as JsonObject).id as string;
    return this.turnId;
  }

  async interrupt(): Promise<void> {
    const threadId = this.threadId;
    const turnId = this.turnId;
    if (!threadId || !turnId || this.closed) return;
    await this.request("turn/interrupt", { threadId, turnId }, 3000).catch(() => undefined);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    const threadId = this.threadId;
    // This CLI protocol has no thread/close method; unsubscribe is the supported
    // cleanup RPC. The one-run child is then ended, which also stops its MCP child.
    if (threadId) await this.request("thread/unsubscribe", { threadId }, 1500).catch(() => undefined);
    this.closed = true;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new CodexAppServerError("Codex app-server cerrado."));
    }
    this.pending.clear();
    try { this.child.stdin?.end(); } catch { /* already closed */ }
    if (this.child.exitCode === null && !this.child.killed) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => { this.child.kill("SIGTERM"); resolve(); }, 1000);
        this.child.once("exit", () => { clearTimeout(timer); resolve(); });
      });
      if (this.child.exitCode === null) this.child.kill("SIGKILL");
    }
  }

  get currentThreadId(): string | undefined { return this.threadId; }
  get currentTurnId(): string | undefined { return this.turnId; }
}

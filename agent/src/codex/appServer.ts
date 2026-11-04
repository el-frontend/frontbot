// Cliente JSON-RPC (una línea por mensaje, stdio) de un proceso `codex app-server`.
// stderr se descarta: stdout del sidecar es solo para el protocolo con la app.
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

export type Spawn = { command: string; args: string[]; env: NodeJS.ProcessEnv; cwd: string };
export type ServerReply = { result?: unknown; error?: { code: number; message: string } };

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void };

export class AppServer {
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private notificationHandlers: ((method: string, params: any) => void)[] = [];
  private serverRequestHandler?: (method: string, params: any) => Promise<ServerReply>;
  private buffer = "";
  private closed = false;
  readonly exited: Promise<{ code: number | null }>;

  private constructor(private child: ChildProcessWithoutNullStreams) {
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.read(chunk));
    child.stderr.on("data", () => undefined);
    child.stdin.on("error", () => undefined);
    this.exited = new Promise((resolve) => {
      const finish = (code: number | null) => {
        this.closed = true;
        for (const p of this.pending.values()) p.reject(new Error("Codex se cerró inesperadamente."));
        this.pending.clear();
        resolve({ code });
      };
      child.on("exit", (code) => finish(code));
      child.on("error", () => finish(null));
    });
  }

  static start(s: Spawn): AppServer {
    return new AppServer(spawn(s.command, s.args, { cwd: s.cwd, env: s.env, stdio: ["pipe", "pipe", "pipe"] }));
  }

  async initialize(): Promise<unknown> {
    const result = await this.request("initialize", {
      clientInfo: { name: "frontbot", title: "Frontbot", version: "0.1.0" },
      capabilities: { experimentalApi: true, requestAttestation: false },
    });
    this.notify("initialized", undefined);
    return result;
  }

  request<T = unknown>(method: string, params: unknown, signal?: AbortSignal): Promise<T> {
    if (this.closed) return Promise.reject(new Error("Codex se cerró inesperadamente."));
    if (signal?.aborted) return Promise.reject(new Error("Cancelado"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const onAbort = () => { this.pending.delete(id); reject(new Error("Cancelado")); };
      signal?.addEventListener("abort", onAbort, { once: true });
      this.pending.set(id, {
        resolve: (v) => { signal?.removeEventListener("abort", onAbort); resolve(v as T); },
        reject: (e) => { signal?.removeEventListener("abort", onAbort); reject(e); },
      });
      this.write({ id, method, params });
    });
  }

  notify(method: string, params: unknown) {
    this.write(params === undefined ? { method } : { method, params });
  }

  onNotification(fn: (method: string, params: any) => void) { this.notificationHandlers.push(fn); }

  onServerRequest(fn: (method: string, params: any) => Promise<ServerReply>) { this.serverRequestHandler = fn; }

  kill() {
    if (this.closed) return;
    this.closed = true;
    this.child.kill("SIGTERM");
    // Si no sale por las buenas, por las malas.
    setTimeout(() => { if (this.child.exitCode === null && this.child.signalCode === null) this.child.kill("SIGKILL"); }, 2000).unref();
  }

  private write(msg: Record<string, unknown>) {
    if (this.child.stdin.destroyed) return;
    this.child.stdin.write(JSON.stringify(msg) + "\n");
  }

  private read(chunk: string) {
    this.buffer += chunk;
    let i: number;
    while ((i = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, i);
      this.buffer = this.buffer.slice(i + 1);
      if (!line.trim()) continue;
      let msg: any;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.method !== undefined && msg.id !== undefined) void this.answer(msg.id, msg.method, msg.params);
      else if (msg.method !== undefined) for (const h of this.notificationHandlers) h(msg.method, msg.params ?? {});
      else if (typeof msg.id === "number" && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id)!;
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(String(msg.error.message ?? "Error de Codex")));
        else p.resolve(msg.result);
      }
    }
  }

  private async answer(id: unknown, method: string, params: unknown) {
    let reply: ServerReply;
    try {
      reply = this.serverRequestHandler ? await this.serverRequestHandler(method, params ?? {}) : { error: { code: -32601, message: `No soportado: ${method}` } };
    } catch (e) {
      reply = { error: { code: -32000, message: (e as Error).message } };
    }
    this.write(reply.error ? { id, error: reply.error } : { id, result: reply.result ?? null });
  }
}

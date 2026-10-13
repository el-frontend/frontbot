import type { Readable, Writable } from "node:stream";

export class RpcError extends Error {
  constructor(message: string, public code: number) {
    super(message);
  }
}

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void };

/** JSON-RPC 2.0 bidireccional, un mensaje JSON por línea. */
export class RpcPeer {
  private nextId = 1;
  private buffer = "";
  private pending = new Map<number, Pending>();
  private requestHandlers = new Map<string, (params: any) => Promise<unknown>>();
  private notificationHandlers = new Map<string, (params: any) => void>();

  constructor(input: Readable, private output: Writable) {
    input.setEncoding("utf8");
    input.on("data", (chunk: string) => this.onData(chunk));
    input.on("end", () => {
      for (const p of this.pending.values()) p.reject(new RpcError("Conexión cerrada", -32001));
      this.pending.clear();
    });
  }

  onRequest(method: string, handler: (params: any) => Promise<unknown>) {
    this.requestHandlers.set(method, handler);
  }

  onNotification(method: string, handler: (params: any) => void) {
    this.notificationHandlers.set(method, handler);
  }

  request<T = unknown>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params: unknown) {
    this.send({ jsonrpc: "2.0", method, params });
  }

  private send(msg: unknown) {
    this.output.write(JSON.stringify(msg) + "\n");
  }

  private onData(chunk: string) {
    this.buffer += chunk;
    let idx: number;
    while ((idx = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (line) this.dispatch(line);
    }
  }

  private dispatch(line: string) {
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return; // línea corrupta: se ignora
    }
    if (typeof msg.method === "string") {
      if (msg.id === undefined) {
        this.notificationHandlers.get(msg.method)?.(msg.params);
        return;
      }
      const handler = this.requestHandlers.get(msg.method);
      if (!handler) {
        this.send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: `Método desconocido: ${msg.method}` } });
        return;
      }
      handler(msg.params).then(
        (result) => this.send({ jsonrpc: "2.0", id: msg.id, result: result ?? null }),
        (err: Error) => this.send({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: err.message } }),
      );
      return;
    }
    const pending = this.pending.get(msg.id);
    if (!pending) return;
    this.pending.delete(msg.id);
    if (msg.error) pending.reject(new RpcError(msg.error.message, msg.error.code));
    else pending.resolve(msg.result);
  }
}

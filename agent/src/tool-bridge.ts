import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer, type Server as NetServer, type Socket, connect } from "node:net";
import { chmod, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { executeFrontbotTool, frontbotToolSpecs, type AppCall, type ToolContext } from "./tools.js";

const MAX_MESSAGE_BYTES = 1024 * 1024;
const RequestSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("list"), token: z.string().min(32) }).strict(),
  z.object({ op: z.literal("call"), token: z.string().min(32), name: z.string().min(1).max(100), arguments: z.record(z.string(), z.unknown()) }).strict(),
]);

export type BridgeTool = { name: string; description: string; inputSchema: Record<string, unknown> };
export type ToolBridgeConfig = { socketPath: string; token: string };
export type RunningToolBridge = ToolBridgeConfig & { close(): Promise<void> };

function matchesToken(expected: string, candidate: string): boolean {
  const left = Buffer.from(expected);
  const right = Buffer.from(candidate);
  return left.length === right.length && timingSafeEqual(left, right);
}

function jsonSchema(spec: ReturnType<typeof frontbotToolSpecs>[number]): Record<string, unknown> {
  return z.toJSONSchema(z.object(spec.shape)) as Record<string, unknown>;
}

function send(socket: Socket, value: unknown) {
  if (!socket.destroyed) socket.end(`${JSON.stringify(value)}\n`);
}

async function handleRequest(line: string, token: string, call: AppCall, ctx: ToolContext) {
  let raw: unknown;
  try { raw = JSON.parse(line); } catch { throw new Error("Solicitud JSON inválida."); }
  const request = RequestSchema.safeParse(raw);
  if (!request.success) throw new Error("Solicitud MCP inválida.");
  if (!matchesToken(token, request.data.token)) throw new Error("Token de puente inválido.");
  if (request.data.op === "list") {
    const tools: BridgeTool[] = frontbotToolSpecs(ctx).map((spec) => ({ name: spec.name, description: spec.description, inputSchema: jsonSchema(spec) }));
    return { tools };
  }
  return await executeFrontbotTool(request.data.name, request.data.arguments, call, ctx);
}

/** Per-run private Unix socket. It only forwards allowlisted tool calls to Swift via AppCall. */
export async function createToolBridge(call: AppCall, ctx: ToolContext): Promise<RunningToolBridge> {
  const directory = await mkdtemp(join(tmpdir(), "frontbot-mcp-"));
  await chmod(directory, 0o700);
  const socketPath = join(directory, "bridge.sock");
  const token = randomBytes(32).toString("hex");
  const server: NetServer = createServer((socket) => {
    socket.setTimeout(10_000, () => socket.destroy());
    let buffer = "";
    let handled = false;
    socket.on("data", (chunk) => {
      if (handled) return;
      buffer += chunk.toString("utf8");
      if (Buffer.byteLength(buffer) > MAX_MESSAGE_BYTES) {
        handled = true;
        send(socket, { error: "Solicitud demasiado grande." });
        return;
      }
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      handled = true;
      const trailing = buffer.slice(newline + 1).trim();
      if (trailing) {
        send(socket, { error: "Se permite una sola solicitud por conexión." });
        return;
      }
      void handleRequest(buffer.slice(0, newline), token, call, ctx).then(
        (result) => send(socket, { result }),
        (error: Error) => send(socket, { bridgeError: error.message || "Solicitud rechazada." }),
      );
    });
    socket.on("error", () => undefined);
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => { server.off("error", reject); resolve(); });
  });
  await chmod(socketPath, 0o600);
  return {
    socketPath,
    token,
    close: async () => {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await rm(directory, { recursive: true, force: true });
    },
  };
}

/** Request helper used by the stdio MCP process. Each call has a fresh local connection. */
export function requestToolBridge<T>(config: ToolBridgeConfig, request: Record<string, unknown>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const socket = connect(config.socketPath);
    let buffer = "";
    let settled = false;
    const finish = (error?: Error, value?: T) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      if (error) reject(error); else resolve(value as T);
    };
    socket.setTimeout(10_000, () => finish(new Error("Tiempo de espera del puente MCP agotado.")));
    socket.on("connect", () => socket.write(`${JSON.stringify({ ...request, token: config.token })}\n`));
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      if (Buffer.byteLength(buffer) > MAX_MESSAGE_BYTES) return finish(new Error("Respuesta del puente demasiado grande."));
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      try {
        const response = JSON.parse(buffer.slice(0, newline)) as { result?: T; bridgeError?: string };
        if (response.bridgeError) finish(new Error(response.bridgeError));
        else if (Object.hasOwn(response, "result")) finish(undefined, response.result);
        else finish(new Error("Respuesta inválida del puente MCP."));
      } catch { finish(new Error("Respuesta JSON inválida del puente MCP.")); }
    });
    socket.on("error", (error) => finish(error));
    socket.on("end", () => { if (!settled) finish(new Error("El puente MCP cerró la conexión sin responder.")); });
  });
}

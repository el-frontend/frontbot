import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { createServer, type Server as NetServer, type Socket, connect } from "node:net";
import { chmod, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { executeFrontbotTool, frontbotToolSpecs, type AppCall, type ToolContext } from "./tools.js";

const MAX_MESSAGE_BYTES = 1024 * 1024;
const IDLE_TIMEOUT_MS = 10_000;
/** 120s Swift approval window + up to 60s script runtime + 20s for setup/cleanup. */
export const TOOL_BRIDGE_REQUEST_TIMEOUT_MS = 200_000;
const CLIENT_RESPONSE_GRACE_MS = 5_000;
const RequestSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("list"), token: z.string().min(32) }).strict(),
  z.object({ op: z.literal("call"), token: z.string().min(32), request_id: z.string().uuid(), name: z.string().min(1).max(100), arguments: z.record(z.string(), z.unknown()) }).strict(),
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

function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stableJSON(item)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

async function handleRequest(line: string, token: string, call: AppCall, ctx: ToolContext, inFlight: Map<string, Promise<unknown>>) {
  let raw: unknown;
  try { raw = JSON.parse(line); } catch { throw new Error("Solicitud JSON inválida."); }
  const request = RequestSchema.safeParse(raw);
  if (!request.success) throw new Error("Solicitud MCP inválida.");
  if (!matchesToken(token, request.data.token)) throw new Error("Token de puente inválido.");
  if (request.data.op === "list") {
    const tools: BridgeTool[] = frontbotToolSpecs(ctx).map((spec) => ({ name: spec.name, description: spec.description, inputSchema: jsonSchema(spec) }));
    return { result: { tools } };
  }
  const fingerprint = stableJSON([request.data.name, request.data.arguments]);
  let execution = inFlight.get(fingerprint);
  if (!execution) {
    execution = executeFrontbotTool(request.data.name, request.data.arguments, call, ctx);
    inFlight.set(fingerprint, execution);
    void execution.finally(() => {
      if (inFlight.get(fingerprint) === execution) inFlight.delete(fingerprint);
    }).catch(() => undefined);
  }
  return { requestId: request.data.request_id, result: await execution };
}

/** Per-run private Unix socket. It only forwards allowlisted tool calls to Swift via AppCall. */
export type ToolBridgeTimeouts = { idleMs?: number; requestMs?: number };

export async function createToolBridge(call: AppCall, ctx: ToolContext, timeouts: ToolBridgeTimeouts = {}): Promise<RunningToolBridge> {
  const directory = await mkdtemp(join(tmpdir(), "frontbot-mcp-"));
  await chmod(directory, 0o700);
  const socketPath = join(directory, "bridge.sock");
  const token = randomBytes(32).toString("hex");
  const idleTimeoutMs = timeouts.idleMs ?? IDLE_TIMEOUT_MS;
  const requestTimeoutMs = timeouts.requestMs ?? TOOL_BRIDGE_REQUEST_TIMEOUT_MS;
  const inFlight = new Map<string, Promise<unknown>>();
  const server: NetServer = createServer((socket) => {
    let responded = false;
    let requestId: string | undefined;
    let timeoutResponse: unknown = { bridgeError: "Tiempo de espera esperando una solicitud MCP." };
    const respond = (value: unknown) => {
      if (responded) return;
      responded = true;
      send(socket, value);
    };
    socket.on("timeout", () => respond(timeoutResponse));
    socket.setTimeout(idleTimeoutMs);
    let buffer = "";
    let handled = false;
    socket.on("data", (chunk) => {
      if (handled) return;
      buffer += chunk.toString("utf8");
      if (Buffer.byteLength(buffer) > MAX_MESSAGE_BYTES) {
        handled = true;
        respond({ bridgeError: "Solicitud demasiado grande." });
        return;
      }
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      handled = true;
      try {
        const parsed = RequestSchema.safeParse(JSON.parse(buffer.slice(0, newline)));
        if (parsed.success && parsed.data.op === "call") requestId = parsed.data.request_id;
      } catch { /* handleRequest returns a protocol error below */ }
      timeoutResponse = {
        request_id: requestId,
        bridgeError: requestId
          ? `La solicitud ${requestId} superó el plazo de ${requestTimeoutMs / 1000}s y puede seguir pendiente en Frontbot. No repitas esta acción.`
          : "La solicitud MCP superó el plazo de respuesta.",
      };
      socket.setTimeout(requestTimeoutMs);
      const trailing = buffer.slice(newline + 1).trim();
      if (trailing) {
        respond({ bridgeError: "Se permite una sola solicitud por conexión." });
        return;
      }
      void handleRequest(buffer.slice(0, newline), token, call, ctx, inFlight).then(
        (response) => respond({ request_id: response.requestId, result: response.result }),
        (error: Error) => respond({ request_id: requestId, bridgeError: error.message || "Solicitud rechazada." }),
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
export function requestToolBridge<T>(config: ToolBridgeConfig, request: Record<string, unknown>, requestTimeoutMs = TOOL_BRIDGE_REQUEST_TIMEOUT_MS): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const socket = connect(config.socketPath);
    let buffer = "";
    let settled = false;
    const requestId = request.op === "call" ? randomUUID() : undefined;
    let timeoutError = new Error("Tiempo de espera esperando conexión con el puente MCP.");
    const finish = (error?: Error, value?: T) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      if (error) reject(error); else resolve(value as T);
    };
    socket.on("timeout", () => finish(timeoutError));
    socket.setTimeout(IDLE_TIMEOUT_MS);
    socket.on("connect", () => {
      timeoutError = new Error(
        requestId
          ? `La solicitud ${requestId} sigue pendiente en Frontbot; no la repitas automáticamente.`
          : "Tiempo de espera de respuesta MCP agotado.",
      );
      socket.setTimeout(requestTimeoutMs + CLIENT_RESPONSE_GRACE_MS);
      socket.write(`${JSON.stringify({ ...request, ...(requestId ? { request_id: requestId } : {}), token: config.token })}\n`);
    });
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      if (Buffer.byteLength(buffer) > MAX_MESSAGE_BYTES) return finish(new Error("Respuesta del puente demasiado grande."));
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      try {
        const response = JSON.parse(buffer.slice(0, newline)) as { request_id?: string; result?: T; bridgeError?: string };
        if (requestId && response.request_id !== requestId) finish(new Error("La respuesta no corresponde a la solicitud MCP actual."));
        else if (response.bridgeError) finish(new Error(response.bridgeError));
        else if (Object.hasOwn(response, "result")) finish(undefined, response.result);
        else finish(new Error("Respuesta inválida del puente MCP."));
      } catch { finish(new Error("Respuesta JSON inválida del puente MCP.")); }
    });
    socket.on("error", (error) => finish(error));
    socket.on("end", () => { if (!settled) finish(new Error("El puente MCP cerró la conexión sin responder.")); });
  });
}

/**
 * Wire contract validated against codex-cli 0.158.0-alpha.2.1 on 2026-10-28.
 * app-server uses newline-delimited JSON-RPC over stdio. `initialize` receives a
 * request/response, followed by the `initialized` notification. A turn is
 * created with thread/start + turn/start; content arrives as
 * item/agentMessage/delta and completion as turn/completed. Keep this adapter
 * tolerant of unrelated server notifications because the protocol evolves.
 */

export type JsonObject = Record<string, unknown>;
export type CodexLine =
  | { kind: "response"; id: number | string; result?: unknown; error?: JsonObject }
  | { kind: "notification"; method: string; params: JsonObject }
  | { kind: "serverRequest"; id: number | string; method: string; params: JsonObject }
  | { kind: "invalid"; error: string };

export type CodexEvent =
  | { type: "text"; text: string }
  | { type: "tool_call"; text: string }
  | { type: "status"; text: string }
  | { type: "usage"; inputTokens: number; outputTokens: number }
  | { type: "approval_request"; operation: "command" | "file_change" | "permissions" }
  | { type: "completed"; status: "completed" | "interrupted" | "failed"; error?: string };

const object = (value: unknown): value is JsonObject => !!value && typeof value === "object" && !Array.isArray(value);
const idValid = (value: unknown): value is number | string => typeof value === "string" || (typeof value === "number" && Number.isFinite(value));

/** Parse one JSONL message. Unknown but well-formed notifications are retained for the caller to ignore. */
export function parseCodexLine(line: string): CodexLine {
  let value: unknown;
  try { value = JSON.parse(line); } catch { return { kind: "invalid", error: "Malformed JSON from Codex app-server." }; }
  if (!object(value)) return { kind: "invalid", error: "Malformed app-server envelope." };
  if (Object.hasOwn(value, "id")) {
    if (!idValid(value.id)) return { kind: "invalid", error: "Malformed app-server response id." };
    if (Object.hasOwn(value, "method")) {
      if (typeof value.method !== "string" || (value.params !== undefined && value.params !== null && !object(value.params))) return { kind: "invalid", error: "Malformed app-server request." };
      return { kind: "serverRequest", id: value.id, method: value.method, params: object(value.params) ? value.params : {} };
    }
    if (Object.hasOwn(value, "error")) {
      if (!object(value.error)) return { kind: "invalid", error: "Malformed app-server error." };
      return { kind: "response", id: value.id, error: value.error };
    }
    if (!Object.hasOwn(value, "result")) return { kind: "invalid", error: "Malformed app-server response." };
    return { kind: "response", id: value.id, result: value.result };
  }
  if (typeof value.method !== "string" || (value.params !== undefined && value.params !== null && !object(value.params))) return { kind: "invalid", error: "Malformed app-server notification." };
  return { kind: "notification", method: value.method, params: object(value.params) ? value.params : {} };
}

function nonnegative(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

/** Convert app-server notifications into the provider-neutral runner stream. */
export function codexEvent(message: Extract<CodexLine, { kind: "notification" | "serverRequest" }>): CodexEvent | undefined {
  if (message.kind === "serverRequest") {
    if (message.method === "item/commandExecution/requestApproval") return { type: "approval_request", operation: "command" };
    if (message.method === "item/fileChange/requestApproval") return { type: "approval_request", operation: "file_change" };
    if (message.method === "item/permissions/requestApproval") return { type: "approval_request", operation: "permissions" };
    return undefined;
  }
  const p = message.params;
  switch (message.method) {
    case "item/agentMessage/delta":
      return typeof p.delta === "string" ? { type: "text", text: p.delta } : undefined;
    case "item/started": {
      const item = p.item;
      if (!object(item)) return undefined;
      if (item.type === "mcpToolCall" && typeof item.tool === "string") return { type: "tool_call", text: item.tool };
      if (item.type === "commandExecution" || item.type === "fileChange") return { type: "tool_call", text: String(item.type) };
      return undefined;
    }
    case "thread/tokenUsage/updated": {
      const usage = p.tokenUsage;
      const last = object(usage) && object(usage.last) ? usage.last : undefined;
      if (!last) return undefined;
      const inputTokens = nonnegative(last.inputTokens);
      const outputTokens = nonnegative(last.outputTokens);
      if (inputTokens === undefined || outputTokens === undefined) return undefined;
      return { type: "usage", inputTokens, outputTokens };
    }
    case "turn/completed": {
      const turn = p.turn;
      if (!object(turn) || (turn.status !== "completed" && turn.status !== "interrupted" && turn.status !== "failed")) return undefined;
      const error = object(turn.error) && typeof turn.error.message === "string" ? turn.error.message : undefined;
      return { type: "completed", status: turn.status, ...(error ? { error } : {}) };
    }
    case "thread/status/changed":
      return object(p.status) && p.status.type === "active" ? { type: "status", text: "Codex está trabajando…" } : undefined;
    default: return undefined;
  }
}

export function jsonRpcRequest(id: number, method: string, params: JsonObject): string {
  return `${JSON.stringify({ id, method, params })}\n`;
}

export function jsonRpcNotification(method: string, params: JsonObject = {}): string {
  return `${JSON.stringify({ method, params })}\n`;
}

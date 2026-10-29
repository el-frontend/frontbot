import { describe, expect, it } from "vitest";
import { codexEvent, jsonRpcNotification, jsonRpcRequest, parseCodexLine } from "../src/codex-protocol.js";

describe("Codex JSONL protocol", () => {
  it("parses responses, notifications and server requests", () => {
    expect(parseCodexLine('{"id":2,"result":{"thread":{}}}')).toEqual({ kind: "response", id: 2, result: { thread: {} } });
    expect(parseCodexLine('{"method":"item/agentMessage/delta","params":{"delta":"hola"}}')).toEqual({ kind: "notification", method: "item/agentMessage/delta", params: { delta: "hola" } });
    expect(parseCodexLine('{"id":"a","method":"item/commandExecution/requestApproval","params":{}}')).toEqual({ kind: "serverRequest", id: "a", method: "item/commandExecution/requestApproval", params: {} });
  });

  it("rejects malformed envelopes and ignores unrelated notifications", () => {
    expect(parseCodexLine("no json").kind).toBe("invalid");
    expect(parseCodexLine('{"id":1}').kind).toBe("invalid");
    const line = parseCodexLine('{"method":"account/updated","params":{}}');
    expect(line.kind === "notification" ? codexEvent(line) : "bad").toBeUndefined();
    expect(parseCodexLine('{"method":"some/future/notification"}')).toEqual({ kind: "notification", method: "some/future/notification", params: {} });
  });

  it("translates streamed text, Frontbot MCP calls, usage and turn completion", () => {
    const text = parseCodexLine('{"method":"item/agentMessage/delta","params":{"delta":"hola"}}');
    expect(text.kind === "notification" ? codexEvent(text) : undefined).toEqual({ type: "text", text: "hola" });
    const tool = parseCodexLine('{"method":"item/started","params":{"item":{"type":"mcpToolCall","tool":"memory_remember"}}}');
    expect(tool.kind === "notification" ? codexEvent(tool) : undefined).toEqual({ type: "tool_call", text: "memory_remember" });
    const usage = parseCodexLine('{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"inputTokens":7,"outputTokens":4}}}}');
    expect(usage.kind === "notification" ? codexEvent(usage) : undefined).toEqual({ type: "usage", inputTokens: 7, outputTokens: 4 });
    const done = parseCodexLine('{"method":"turn/completed","params":{"turn":{"status":"failed","error":{"message":"invalid model"}}}}');
    expect(done.kind === "notification" ? codexEvent(done) : undefined).toEqual({ type: "completed", status: "failed", error: "invalid model" });
    const approval = parseCodexLine('{"id":1,"method":"item/commandExecution/requestApproval","params":{"command":"echo blocked"}}');
    expect(approval.kind === "serverRequest" ? codexEvent(approval) : undefined).toEqual({ type: "approval_request", operation: "command" });
  });

  it("writes JSONL app-server messages", () => {
    expect(JSON.parse(jsonRpcRequest(1, "initialize", { clientInfo: {} }))).toEqual({ id: 1, method: "initialize", params: { clientInfo: {} } });
    expect(JSON.parse(jsonRpcNotification("initialized"))).toEqual({ method: "initialized", params: {} });
  });
});

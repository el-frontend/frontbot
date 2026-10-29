import { describe, expect, it, vi } from "vitest";
import { OpenAIResponsesError, streamOpenAIResponse, type OpenAIResponseEvent } from "../src/openai-responses.js";

const encoder = new TextEncoder();
const sseResponse = (chunks: string[], init: ResponseInit = {}) => new Response(new ReadableStream({
  start(controller) {
    for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
    controller.close();
  },
}), { status: 200, headers: { "content-type": "text/event-stream" }, ...init });

const request = { model: "gpt-6-astra", input: [{ role: "user", content: "Hola" }], tools: [{ type: "function" as const, name: "tasks_list", description: "List tasks", parameters: { type: "object", properties: {} } }] };

describe("streamOpenAIResponse", () => {
  it("sends a stateless streamed Responses request with function tools and bearer auth only in the header", async () => {
    const fetch = vi.fn().mockResolvedValue(sseResponse([
      'data: {"type":"response.completed","response":{"output":[]}}\n\n',
    ]));

    await streamOpenAIResponse(request, { apiKey: "sk-secret", fetch });

    expect(fetch).toHaveBeenCalledOnce();
    const [url, init] = fetch.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.openai.com/v1/responses");
    expect(init.headers).toEqual({ "content-type": "application/json", authorization: "Bearer sk-secret" });
    expect(JSON.parse(String(init.body))).toEqual({ ...request, stream: true, store: false });
    expect(String(init.body)).not.toContain("sk-secret");
  });

  it("parses split CRLF SSE chunks, forwards deltas, and preserves final output items", async () => {
    const events: OpenAIResponseEvent[] = [];
    const result = await streamOpenAIResponse(request, { apiKey: "secret", fetch: vi.fn().mockResolvedValue(sseResponse([
      ': keepalive\r\n\r\n',
      'data: {"type":"response.output_text.delta","delta":"Hel',
      'lo"}\r\n\r\n',
      'event: ignored\r\ndata: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"id\\":"}\r\n\r\n',
      'data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\\"id\\":1}"}\r\n\r\n',
      'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","status":"completed","encrypted_content":"complete"}}\r\n\r\n',
      'data: {"type":"response.output_item.done","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"tasks_list","arguments":"{\\"id\\":1}","status":"completed"}}\r\n\r\n',
      'data: {"type":"response.completed","response":{"id":"resp_1","output":[]}}\r\n\r\n',
    ])) }, (event) => events.push(event));

    expect(events).toEqual(expect.arrayContaining([
      { type: "text_delta", delta: "Hello" },
      { type: "function_call_arguments_delta", itemId: "fc_1", delta: "{\"id\":" },
      { type: "function_call_arguments_done", itemId: "fc_1", arguments: "{\"id\":1}" },
    ]));
    expect(result.output).toEqual([
      { id: "rs_1", type: "reasoning", status: "completed", encrypted_content: "complete" },
      { id: "fc_1", type: "function_call", call_id: "call_1", name: "tasks_list", arguments: "{\"id\":1}", status: "completed" },
    ]);
  });

  it("rejects provider and malformed stream errors without leaking authorization data", async () => {
    await expect(streamOpenAIResponse(request, { apiKey: "sk-secret", fetch: vi.fn().mockResolvedValue(new Response(JSON.stringify({ error: { message: "bad sk-secret" } }), { status: 401 })) }))
      .rejects.toMatchObject({ message: "La clave de OpenAI no es válida.", kind: "authentication" });
    await expect(streamOpenAIResponse(request, { apiKey: "sk-secret", fetch: vi.fn().mockResolvedValue(sseResponse(['data: {oops}\n\n'])) }))
      .rejects.toMatchObject({ message: "La respuesta de OpenAI no se pudo interpretar.", kind: "malformed_stream" });
    await expect(streamOpenAIResponse(request, { apiKey: "sk-secret", fetch: vi.fn().mockResolvedValue(sseResponse([
      'data: {"type":"response.failed","response":{"error":{"message":"bad sk-secret"}}}\n\n',
    ])) })).rejects.toBeInstanceOf(OpenAIResponsesError);
  });

  it("ignores unrelated events and reports an abort as cancellation", async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(streamOpenAIResponse(request, { apiKey: "sk-secret", signal: controller.signal, fetch: vi.fn() }))
      .rejects.toMatchObject({ message: "Cancelado", kind: "cancelled" });

    const result = await streamOpenAIResponse(request, { apiKey: "sk-secret", fetch: vi.fn().mockResolvedValue(sseResponse([
      'data: {"type":"response.created"}\n\n',
      'data: {"type":"response.completed","response":{"output":[{"id":"msg_1","type":"message","status":"completed"}]}}\n\n',
    ])) });
    expect(result.output).toEqual([{ id: "msg_1", type: "message", status: "completed" }]);
  });
});

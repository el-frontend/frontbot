/** Minimal, stateless transport for the OpenAI Responses streaming endpoint. */
export type OpenAIFunctionTool = {
  type: "function";
  name: string;
  description?: string;
  parameters: Record<string, unknown>;
  strict?: boolean;
};

export type OpenAIResponsesRequest = {
  model: string;
  input: unknown;
  instructions?: string;
  tools?: OpenAIFunctionTool[];
};

export type ResponseOutputItem = Record<string, unknown> & { type: string };
export type OpenAICompletedResponse = Record<string, unknown> & { output?: ResponseOutputItem[] };

export type OpenAIResponseEvent =
  | { type: "text_delta"; delta: string }
  | { type: "function_call_arguments_delta"; itemId: string; delta: string }
  | { type: "function_call_arguments_done"; itemId: string; arguments: string }
  | { type: "output_item_done"; outputIndex: number; item: ResponseOutputItem }
  | { type: "completed"; response: OpenAICompletedResponse };

export type OpenAIResponsesResult = { response: OpenAICompletedResponse; output: ResponseOutputItem[] };
export type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export type OpenAIResponsesOptions = {
  apiKey: string;
  endpoint?: string;
  fetch?: FetchLike;
  signal?: AbortSignal;
};

export class OpenAIResponsesError extends Error {
  constructor(readonly kind: "authentication" | "rate_limit" | "model_unavailable" | "request_too_large" | "network" | "cancelled" | "malformed_stream" | "api", message: string) {
    super(message);
    this.name = "OpenAIResponsesError";
  }
}

const isObject = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const isOutputItem = (value: unknown): value is ResponseOutputItem => isObject(value) && typeof value.type === "string";
const cancelled = () => new OpenAIResponsesError("cancelled", "Cancelado");
const malformed = () => new OpenAIResponsesError("malformed_stream", "La respuesta de OpenAI no se pudo interpretar.");

function errorFor(status: number, payload: unknown): OpenAIResponsesError {
  const error = isObject(payload) && isObject(payload.error) ? payload.error : undefined;
  const code = typeof error?.code === "string" ? error.code : "";
  if (status === 401 || status === 403) return new OpenAIResponsesError("authentication", "La clave de OpenAI no es válida.");
  if (status === 429) return new OpenAIResponsesError("rate_limit", "OpenAI está limitando las solicitudes. Inténtalo de nuevo en unos minutos.");
  if (status === 413 || code === "context_length_exceeded" || code === "request_too_large") return new OpenAIResponsesError("request_too_large", "La solicitud es demasiado grande para OpenAI.");
  if (status === 404 || code === "model_not_found" || code === "unsupported_model" || code === "model_not_available") return new OpenAIResponsesError("model_unavailable", "El modelo seleccionado no está disponible en este proyecto de OpenAI.");
  return new OpenAIResponsesError("api", "OpenAI no pudo completar la solicitud.");
}

async function safeJson(response: Response): Promise<unknown> {
  try { return await response.json(); } catch { return undefined; }
}

/** Decode SSE records incrementally. Comments and empty keepalives are ignored. */
async function* sseData(body: ReadableStream<Uint8Array>, signal?: AbortSignal): AsyncGenerator<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let data: string[] = [];
  const dispatch = () => {
    const out = data.join("\n");
    data = [];
    return out;
  };
  try {
    for (;;) {
      if (signal?.aborted) throw cancelled();
      const next = await reader.read();
      if (next.done) break;
      buffer += decoder.decode(next.value, { stream: true });
      let newline: number;
      while ((newline = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (line === "") {
          const event = dispatch();
          if (event) yield event;
        } else if (!line.startsWith(":")) {
          const colon = line.indexOf(":");
          const field = colon === -1 ? line : line.slice(0, colon);
          let value = colon === -1 ? "" : line.slice(colon + 1);
          if (value.startsWith(" ")) value = value.slice(1);
          if (field === "data") data.push(value);
        }
      }
    }
    buffer += decoder.decode();
    if (buffer) {
      if (buffer.endsWith("\r")) buffer = buffer.slice(0, -1);
      if (buffer.startsWith("data:")) data.push(buffer.slice(5).replace(/^ /, ""));
    }
    const event = dispatch();
    if (event) yield event;
  } finally {
    reader.releaseLock();
  }
}

/**
 * POST a one-shot, stateless Responses request and stream its typed events.
 * Function arguments are only forwarded; callers must wait for their complete
 * output item before validating or invoking a Frontbot tool.
 */
export async function streamOpenAIResponse(
  request: OpenAIResponsesRequest,
  options: OpenAIResponsesOptions,
  onEvent?: (event: OpenAIResponseEvent) => void,
): Promise<OpenAIResponsesResult> {
  if (options.signal?.aborted) throw cancelled();
  const apiKey = options.apiKey.trim();
  if (!apiKey) throw new OpenAIResponsesError("authentication", "Falta la clave de OpenAI.");
  let response: Response;
  try {
    response = await (options.fetch ?? globalThis.fetch)(options.endpoint ?? "https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ model: request.model, input: request.input, ...(request.instructions ? { instructions: request.instructions } : {}), ...(request.tools ? { tools: request.tools } : {}), stream: true, store: false }),
      signal: options.signal,
    });
  } catch (cause) {
    if (options.signal?.aborted || (cause instanceof DOMException && cause.name === "AbortError")) throw cancelled();
    throw new OpenAIResponsesError("network", "No se pudo conectar con OpenAI.");
  }
  if (!response.ok) throw errorFor(response.status, await safeJson(response));
  if (!response.body) throw new OpenAIResponsesError("api", "OpenAI no devolvió una respuesta transmitida.");

  const output = new Map<number, ResponseOutputItem>();
  let completed: OpenAICompletedResponse | undefined;
  try {
    for await (const data of sseData(response.body, options.signal)) {
      if (data === "[DONE]") continue;
      let event: unknown;
      try { event = JSON.parse(data); } catch { throw malformed(); }
      if (!isObject(event) || typeof event.type !== "string") throw malformed();
      switch (event.type) {
        case "response.output_text.delta":
          if (typeof event.delta === "string") onEvent?.({ type: "text_delta", delta: event.delta });
          break;
        case "response.function_call_arguments.delta":
          if (typeof event.item_id === "string" && typeof event.delta === "string") onEvent?.({ type: "function_call_arguments_delta", itemId: event.item_id, delta: event.delta });
          break;
        case "response.function_call_arguments.done":
          if (typeof event.item_id === "string" && typeof event.arguments === "string") onEvent?.({ type: "function_call_arguments_done", itemId: event.item_id, arguments: event.arguments });
          break;
        case "response.output_item.done":
          if (typeof event.output_index !== "number" || !isOutputItem(event.item)) throw malformed();
          output.set(event.output_index, event.item);
          onEvent?.({ type: "output_item_done", outputIndex: event.output_index, item: event.item });
          break;
        case "response.completed":
          if (!isObject(event.response)) throw malformed();
          completed = event.response as OpenAICompletedResponse;
          if (Array.isArray(completed.output)) completed.output.forEach((item, index) => { if (!output.has(index) && isOutputItem(item)) output.set(index, item); });
          onEvent?.({ type: "completed", response: completed });
          break;
        case "response.failed":
        case "response.incomplete":
        case "error":
          throw errorFor(500, event);
        default:
          break;
      }
    }
  } catch (cause) {
    if (cause instanceof OpenAIResponsesError) throw cause;
    if (options.signal?.aborted || (cause instanceof DOMException && cause.name === "AbortError")) throw cancelled();
    throw new OpenAIResponsesError("network", "No se pudo conectar con OpenAI.");
  }
  if (options.signal?.aborted) throw cancelled();
  if (!completed) throw new OpenAIResponsesError("malformed_stream", "OpenAI terminó la respuesta sin confirmarla.");
  return { response: completed, output: [...output.entries()].sort(([a], [b]) => a - b).map(([, item]) => item) };
}

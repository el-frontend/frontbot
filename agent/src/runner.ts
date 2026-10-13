import { query, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { buildTools, ALLOWED_TOOLS, type AppCall } from "./tools.js";
import { buildSystemPrompt } from "./prompt.js";

export type Brand = { id: string; name: string; guide: string | null };
export type RunParams = { run_id: string; prompt: string; model: string; brand?: Brand };
export type RunEvent = { run_id: string; type: "text" | "tool_call" | "status"; text: string };
export type RunDone = { run_id: string; ok: boolean; summary: string; input_tokens: number; output_tokens: number; cost_usd: number; error?: string };

export interface Runner {
  run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone>;
}

const cancelled = (run_id: string): RunDone => ({ run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: "Cancelado" });

export class RealRunner implements Runner {
  constructor(private call: AppCall) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (signal.aborted) return cancelled(params.run_id);
    const abortController = new AbortController();
    signal.addEventListener("abort", () => abortController.abort());
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: buildTools(this.call) });
    const today = new Date().toISOString().slice(0, 10);
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    try {
      const stream = query({
        prompt: params.prompt,
        options: {
          model: params.model,
          systemPrompt: buildSystemPrompt({ today, brand: params.brand }),
          tools: ["WebSearch", "WebFetch"],
          allowedTools: ALLOWED_TOOLS,
          mcpServers: { frontbot: server },
          strictMcpConfig: true,
          settingSources: [],
          permissionMode: "dontAsk",
          maxTurns: 30,
          abortController,
        },
      });
      for await (const msg of stream) {
        if (msg.type === "assistant") {
          for (const block of msg.message.content) {
            if (block.type === "text") emit({ run_id: params.run_id, type: "text", text: block.text });
            if (block.type === "tool_use") emit({ run_id: params.run_id, type: "tool_call", text: block.name.replace("mcp__frontbot__", "") });
          }
        } else if (msg.type === "result") {
          const usage = msg.usage as { input_tokens?: number; output_tokens?: number };
          const base = { run_id: params.run_id, input_tokens: usage.input_tokens ?? 0, output_tokens: usage.output_tokens ?? 0, cost_usd: msg.total_cost_usd ?? 0 };
          if (msg.subtype === "success" && !msg.is_error) return { ...base, ok: true, summary: msg.result };
          return { ...base, ok: false, summary: "", error: msg.subtype === "success" ? msg.result : msg.subtype };
        }
      }
      return signal.aborted ? cancelled(params.run_id) : { ...cancelled(params.run_id), error: "El agente terminó sin resultado" };
    } catch (err) {
      if (signal.aborted) return cancelled(params.run_id);
      return { ...cancelled(params.run_id), error: (err as Error).message };
    }
  }
}

/** Runner guionado, sin red: para probar la app de punta a punta sin gastar tokens. */
export class FakeRunner implements Runner {
  constructor(private call: AppCall) {}

  async run(params: RunParams, emit: (e: RunEvent) => void, signal: AbortSignal): Promise<RunDone> {
    if (params.prompt === "crash") process.exit(1);
    emit({ run_id: params.run_id, type: "status", text: "pensando" });
    const { brands } = (await this.call("tool.brands_list", {})) as { brands: unknown[] };
    const summary = `Tienes ${brands.length} marca(s).`;
    emit({ run_id: params.run_id, type: "text", text: summary });
    if (params.prompt.includes("crear post") && params.brand) {
      await this.call("tool.posts_create_draft", { brand_id: params.brand.id, network: "instagram", body: "Post de prueba" });
      emit({ run_id: params.run_id, type: "tool_call", text: "posts_create_draft" });
    }
    if (params.prompt.includes("lento")) {
      const aborted = signal.aborted || await new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), 5000);
        signal.addEventListener("abort", () => { clearTimeout(timer); resolve(true); });
      });
      if (aborted) return cancelled(params.run_id);
    }
    return { run_id: params.run_id, ok: true, summary, input_tokens: 0, output_tokens: 0, cost_usd: 0 };
  }
}

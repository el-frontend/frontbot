import type { CodexRuntimeConfig } from "./runner.js";
import type { RunDone, RunEvent, RunParams, Runner, RunnerContext } from "./runner.js";

/**
 * Codex runtime is fail-closed until the app-server provides a verifiable way to
 * disable every native shell/read capability while keeping Frontbot MCP tools.
 * Approval prompts and model instructions are not security boundaries.
 */
export class CodexRunner implements Runner {
  constructor(readonly config: CodexRuntimeConfig) {}

  async run(params: RunParams, _emit: (event: RunEvent) => void, signal: AbortSignal, _context?: RunnerContext): Promise<RunDone> {
    if (signal.aborted) return { run_id: params.run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0, error: "Cancelado" };
    return {
      run_id: params.run_id, ok: false, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0,
      error: "La integración de Codex está deshabilitada hasta poder garantizar los permisos de herramientas de Frontbot.",
    };
  }
}

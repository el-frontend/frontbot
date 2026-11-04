// Cómo se lanza un `codex app-server` para un run: qué capacidades tiene el modo, con qué flags
// se apagan las que no, el perfil de permisos de la carpeta de trabajo y los params del hilo.
// Funciones puras: lo que el modelo puede hacer se decide aquí, no en el prompt.
import { alwaysDenied, safeReadRoots, workdirDomains, type RunWorkdir } from "../workdir.js";
import type { RunParams } from "../runner.js";

export type CodexCaps = { web: boolean; shell: boolean; browser: boolean; skills: boolean };
export type DynamicTool = { type: "function"; name: string; description: string; inputSchema: Record<string, unknown> };

/** Nombre del perfil de permisos de Frontbot (un proceso por run: no choca entre runs). */
export const PROFILE = "frontbot";

/** Funciones de Codex que Frontbot nunca da: plugins, conectores, su Chrome, computer use, sub-agentes… */
const ALWAYS_DISABLED = ["plugins", "apps", "memories", "browser_use", "computer_use", "multi_agent", "image_generation", "goals", "sleep_tool", "tool_suggest"];

/** Las mismas reglas que `buildQueryOptions` de Claude. */
export function codexCaps(params: RunParams): CodexCaps {
  const mode = params.mode;
  const summarize = mode === "summarize", study = mode === "study", image = mode === "image", metrics = mode === "metrics";
  return {
    browser: (params.browser === true || metrics) && !summarize && !study && !image,
    web: !(summarize || image || metrics),
    shell: (mode === undefined || mode === "chat") && params.workdir !== undefined,
    skills: !summarize && !study && !image && !metrics && (params.skills?.length ?? 0) > 0,
  };
}

const toml = (value: string) => JSON.stringify(value);
const inlineTable = (entries: [string, string][]) => `{${entries.map(([k, v]) => `${toml(k)}=${toml(v)}`).join(",")}}`;
const config = (value: string) => ["-c", value];

/** Perfil por run: home y rutas protegidas denegadas, la carpeta con escritura, lecturas extra y red limitada. */
export function workdirProfileArgs(wd: RunWorkdir, home: string): string[] {
  const filesystem: [string, string][] = [
    [home, "deny"],
    ...alwaysDenied(home).map((p): [string, string] => [p, "deny"]),
    ...safeReadRoots(wd.read_dirs, home).map((p): [string, string] => [p, "read"]),
    [wd.path, "write"],
    [":slash_tmp", "deny"],
    [":tmpdir", "deny"],
  ];
  return [
    ...config(`default_permissions=${toml(PROFILE)}`),
    ...config(`permissions.${PROFILE}.extends=":workspace"`),
    ...config(`permissions.${PROFILE}.filesystem=${inlineTable(filesystem)}`),
    ...config(`permissions.${PROFILE}.network.enabled=true`),
    ...config(`permissions.${PROFILE}.network.mode="limited"`),
    ...config(`permissions.${PROFILE}.network.domains=${inlineTable(workdirDomains(wd).map((d): [string, string] => [d, "allow"]))}`),
    ...config("features.network_proxy=true"),
  ];
}

export function codexArgs(caps: CodexCaps, profile?: { wd: RunWorkdir; home: string }): string[] {
  const disable = [...ALWAYS_DISABLED];
  if (!caps.shell) disable.push("shell_tool", "unified_exec");
  // `exec`/`wait` (JS aislado, sin disco ni red) hacen falta para la web y el shell; sin ninguno, fuera.
  if (!caps.web && !caps.shell) disable.push("code_mode_host");
  return [
    "app-server",
    ...config("mcp_servers={}"),
    ...config('cli_auth_credentials_store="file"'),
    ...disable.flatMap((f) => ["--disable", f]),
    ...(caps.web ? [] : config("tools.web_search=false")),
    ...(caps.shell && profile ? workdirProfileArgs(profile.wd, profile.home) : []),
  ];
}

export function codexThreadParams(input: { params: RunParams; caps: CodexCaps; instructions: string; tools: DynamicTool[]; cwd: string }): Record<string, unknown> {
  const { params, caps, instructions, tools, cwd } = input;
  return {
    model: params.model, cwd, ephemeral: true, developerInstructions: instructions, dynamicTools: tools,
    // Con shell, lo que no cabe en la sandbox llega como petición de aprobación; aceptar lo saca de la sandbox.
    ...(caps.shell ? { approvalPolicy: "on-request", permissions: PROFILE } : { approvalPolicy: "never", sandbox: "read-only", environments: [] }),
  };
}

/** Los `maxTurns` de Claude por modo, contados como llamadas a herramientas o comandos. */
export function codexMaxToolCalls(params: RunParams): number {
  if (params.mode === "summarize") return 6;
  if (params.mode === "study") return 60;
  if (params.mode === "metrics") return 40;
  if ((params.mode === undefined || params.mode === "chat") && params.workdir) return 150;
  return 30;
}

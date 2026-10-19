// Carpeta de trabajo del chat: decide allow/deny/ask para las herramientas de Claude Code
// respecto a esa carpeta, y construye la sandbox de Bash. Función pura, sin estado.
import { realpathSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import type { SandboxSettings } from "@anthropic-ai/claude-agent-sdk";

/** Rutas reales. `read_dirs` incluye `~/Downloads` ya resuelto: lo pone la app. */
export type RunWorkdir = { path: string; read_dirs: string[] };

export type WorkdirAsk =
  | { kind: "write"; tool: "Write" | "Edit"; path: string; content?: string; old_string?: string; new_string?: string }
  | { kind: "unsandboxed"; command: string };

export type WorkdirDecision = { kind: "allow" } | { kind: "deny"; reason: string } | { kind: "ask"; ask: WorkdirAsk };

export const WORKDIR_TOOLS = ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "TodoWrite"];

/** Nunca se leen ni se escriben, aunque caigan dentro de una carpeta elegida. */
// El perfil de Frontbot Chrome no se incluye: el código del sidecar no define ninguno propio (usa el Chrome del usuario).
export function alwaysDenied(home: string): string[] {
  return [
    ".ssh",
    ".aws",
    ".gnupg",
    "Library/Keychains",
    "Library/Application Support/Frontbot",
    "Library/Application Support/Google/Chrome",
  ].map((p) => join(home, p));
}

/** realpath del tramo que existe + los componentes que faltan (como `AgentFiles.resolve` en Swift). */
function realish(p: string): string {
  const missing: string[] = [];
  let cur = resolve(p);
  for (;;) {
    try {
      return join(realpathSync(cur), ...missing.reverse());
    } catch {
      const up = dirname(cur);
      if (up === cur) return resolve(p);
      missing.push(cur.slice(up.length === 1 ? 1 : up.length + 1));
      cur = up;
    }
  }
}

const inside = (target: string, root: string) => target === root || target.startsWith(root.endsWith(sep) ? root : root + sep);

function expand(p: string, wd: RunWorkdir, home: string): string {
  const abs = p === "~" ? home : p.startsWith("~/") ? join(home, p.slice(2)) : resolve(wd.path, p);
  return realish(abs);
}

/** Un patrón de Glob cuenta como ruta si es absoluto o empieza por `~`; se corta antes del primer comodín. */
function globRoot(pattern: string): string | null {
  if (!pattern.startsWith("/") && !pattern.startsWith("~")) return null;
  const parts = pattern.split("/");
  const i = parts.findIndex((c) => /[*?[{]/.test(c));
  const head = (i < 0 ? parts : parts.slice(0, i)).join("/");
  return head === "" ? "/" : head;
}

const str = (v: unknown) => (typeof v === "string" && v ? v : undefined);

export function workdirDecision(tool: string, input: Record<string, unknown>, wd: RunWorkdir, home: string = homedir()): WorkdirDecision {
  const denied = alwaysDenied(home).map(realish);
  const root = realish(wd.path);
  const reads = wd.read_dirs.map(realish);
  const hitsDenied = (t: string) => denied.some((d) => inside(t, d));

  const checkRead = (raw: string): WorkdirDecision => {
    const t = expand(raw, wd, home);
    if (hitsDenied(t)) return { kind: "deny", reason: `Esa ruta está protegida y nunca se puede leer: ${raw}` };
    if (inside(t, root) || reads.some((r) => inside(t, r))) return { kind: "allow" };
    return { kind: "deny", reason: `Fuera de la carpeta de trabajo o de una carpeta de lectura: ${raw}` };
  };

  switch (tool) {
    case "Read": {
      const p = str(input.file_path);
      return p ? checkRead(p) : { kind: "allow" };
    }
    case "Grep": {
      const p = str(input.path);
      return p ? checkRead(p) : { kind: "allow" };
    }
    case "Glob": {
      for (const p of [str(input.path), globRoot(str(input.pattern) ?? "") ?? undefined]) {
        if (!p) continue;
        const r = checkRead(p);
        if (r.kind !== "allow") return r;
      }
      return { kind: "allow" };
    }
    case "Write":
    case "Edit": {
      const raw = str(input.file_path);
      if (!raw) return { kind: "deny", reason: "Falta la ruta del archivo." };
      const t = expand(raw, wd, home);
      if (hitsDenied(t)) return { kind: "deny", reason: `Esa ruta está protegida y nunca se puede escribir: ${raw}` };
      if (inside(t, root)) return { kind: "allow" };
      const ask: WorkdirAsk = { kind: "write", tool, path: t };
      if (tool === "Write") ask.content = str(input.content) ?? "";
      else {
        ask.old_string = str(input.old_string) ?? "";
        ask.new_string = str(input.new_string) ?? "";
      }
      return { kind: "ask", ask };
    }
    case "Bash":
      return input.dangerouslyDisableSandbox === true
        ? { kind: "ask", ask: { kind: "unsandboxed", command: str(input.command) ?? "" } }
        : { kind: "allow" };
    default:
      return { kind: "allow" };
  }
}

/** Mensaje de error si la carpeta no sirve como carpeta de trabajo, o `null` si es válida. */
export function validateWorkdir(wd: RunWorkdir, home: string = homedir()): string | null {
  let real: string;
  try {
    real = realpathSync(wd.path);
    if (!statSync(real).isDirectory()) return "La ruta no es una carpeta.";
  } catch {
    return "La carpeta no existe.";
  }
  const h = realish(home);
  if (real === sep || real === h) return "Elige una carpeta concreta, no tu carpeta personal ni la raíz.";
  // Un ancestro de una ruta denegada (p. ej. ~/Library) la dejaría al alcance; una ruta dentro de ella, también.
  if (alwaysDenied(home).map(realish).some((d) => inside(d, real) || inside(real, d))) return "Esa carpeta contiene o es una ruta protegida.";
  return null;
}

/**
 * Sandbox de Bash. `allowRead` re-permite dentro de `denyRead` (home entero): la Tarea 3 lo verifica de verdad.
 * Red abierta a propósito: sin `allowedDomains`.
 */
export function sandboxSettings(wd: RunWorkdir, home: string, toolPaths: string[]): SandboxSettings {
  const tmps = [...new Set([realish(tmpdir()), "/private/tmp"])];
  const cache = [join(home, ".npm"), join(home, ".cache")];
  return {
    enabled: true,
    failIfUnavailable: true,
    autoAllowBashIfSandboxed: true,
    allowUnsandboxedCommands: true,
    network: {},
    filesystem: {
      allowWrite: [wd.path, ...cache, ...tmps],
      denyRead: [home, ...alwaysDenied(home)],
      allowRead: [wd.path, ...wd.read_dirs, ...toolPaths, ...cache, join(home, ".npm-global"), join(home, ".nvm"), ...tmps],
    },
  };
}

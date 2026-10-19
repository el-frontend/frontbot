// Carpeta de trabajo del chat: decide allow/deny/ask para las herramientas de Claude Code
// respecto a esa carpeta, y construye la sandbox de Bash. Función pura, sin estado.
import { lstatSync, readlinkSync, realpathSync, statSync } from "node:fs";
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
export function alwaysDenied(home: string): string[] {
  // El perfil de Frontbot Chrome no se incluye: el sidecar no define ninguno propio (usa el Chrome del usuario).
  return [
    ".ssh",
    ".aws",
    ".gnupg",
    "Library/Keychains",
    "Library/Application Support/Frontbot",
    "Library/Application Support/Google/Chrome",
  ].map((p) => join(home, p));
}

const MAX_LINKS = 40;

/**
 * Resuelve una ruta absoluta componente a componente, como el kernel: los enlaces se siguen antes de
 * aplicar `..` y los enlaces rotos apuntan a donde apuntan. Los componentes que no existen se añaden al final.
 * Devuelve null si no se puede resolver (bucle de enlaces, permisos…): quien llama debe denegar.
 */
function resolveReal(abs: string): string | null {
  let cur: string = sep;
  let queue = abs.split("/").filter((c) => c !== "");
  let links = 0;
  while (queue.length) {
    const [c, ...rest] = queue;
    if (c === ".") { queue = rest; continue; }
    if (c === "..") { cur = dirname(cur); queue = rest; continue; }
    const next = join(cur, c);
    let st;
    try {
      st = lstatSync(next);
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      if (code === "ENOENT" || code === "ENOTDIR") return resolve(next, ...rest);
      return null;
    }
    if (st.isSymbolicLink()) {
      if (++links > MAX_LINKS) return null;
      let target: string;
      try { target = readlinkSync(next); } catch { return null; }
      if (target.startsWith("/")) cur = sep;
      queue = [...target.split("/").filter((x) => x !== ""), ...rest];
    } else {
      cur = next;
      queue = rest;
    }
  }
  return cur;
}

/** Para raíces conocidas (carpeta, denegadas): si no se resuelve, vale la ruta léxica. */
const realish = (p: string) => resolveReal(resolve(p)) ?? resolve(p);

// APFS no distingue mayúsculas: `~/.SSH` es `~/.ssh`.
const fold = (p: string) => (process.platform === "darwin" ? p.toLowerCase() : p);
const inside = (target: string, root: string) => {
  const t = fold(target), r = fold(root);
  return t === r || t.startsWith(r.endsWith(sep) ? r : r + sep);
};

/** `~` → home; relativa → contra la carpeta. Sin normalizar `..` aquí: lo resuelve el recorrido real. */
function expand(p: string, wd: RunWorkdir, home: string): string | null {
  const abs = p === "~" ? home : p.startsWith("~/") ? home + "/" + p.slice(2) : p.startsWith("/") ? p : wd.path + "/" + p;
  return resolveReal(abs);
}

/** Tramo de un patrón de Glob hasta el primer componente con comodín. */
const cutAtWildcard = (pattern: string) => {
  const parts = pattern.split("/");
  const i = parts.findIndex((c) => /[*?[{]/.test(c));
  return (i < 0 ? parts : parts.slice(0, i)).join("/");
};

const str = (v: unknown) => (typeof v === "string" && v ? v : undefined);

/** Carpetas de lectura extra que no pueden anular lo denegado: ni home, ni la raíz, ni ancestros o hijos de rutas protegidas. */
function safeReadRoots(paths: string[], home: string): string[] {
  const denied = alwaysDenied(home).map(realish);
  const h = realish(home);
  return paths.map(realish).filter((r) => r !== sep && !inside(h, r) && !denied.some((d) => inside(d, r) || inside(r, d)));
}

export function workdirDecision(tool: string, input: Record<string, unknown>, wd: RunWorkdir, home: string = homedir()): WorkdirDecision {
  const denied = alwaysDenied(home).map(realish);
  const root = realish(wd.path);
  const reads = safeReadRoots(wd.read_dirs, home);
  const hitsDenied = (t: string) => denied.some((d) => inside(t, d));

  const checkRead = (raw: string): WorkdirDecision => {
    const t = expand(raw, wd, home);
    if (t === null) return { kind: "deny", reason: `No se puede resolver la ruta: ${raw}` };
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
      const pattern = str(input.pattern) ?? "";
      const pathLike = pattern.startsWith("/") || pattern.startsWith("~");
      // Un patrón relativo con `..` puede salir de la carpeta: se comprueba contra su base.
      const dotdot = !pathLike && pattern.split("/").includes("..");
      const base = str(input.path) ?? wd.path;
      const fromPattern = pathLike ? cutAtWildcard(pattern) || "/" : dotdot ? base + "/" + cutAtWildcard(pattern) : undefined;
      for (const p of [str(input.path), fromPattern]) {
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
      if (t === null) return { kind: "deny", reason: `No se puede resolver la ruta: ${raw}` };
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
  if (real === sep || fold(real) === fold(h)) return "Elige una carpeta concreta, no tu carpeta personal ni la raíz.";
  // Un ancestro de una ruta denegada (p. ej. ~/Library) la dejaría al alcance; una ruta dentro de ella, también.
  if (alwaysDenied(home).map(realish).some((d) => inside(d, real) || inside(real, d))) return "Esa carpeta contiene o es una ruta protegida.";
  return null;
}

/**
 * Sandbox de Bash. `allowRead` re-permite dentro de `denyRead` (home entero): la Tarea 3 lo verifica de verdad.
 * Red abierta a propósito: sin `allowedDomains`.
 */
export function sandboxSettings(wd: RunWorkdir, home: string, toolPaths: string[]): SandboxSettings {
  const reads = safeReadRoots([...wd.read_dirs, ...toolPaths], home);
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
      allowRead: [wd.path, ...reads, ...cache, join(home, ".npm-global"), join(home, ".nvm"), ...tmps],
    },
  };
}

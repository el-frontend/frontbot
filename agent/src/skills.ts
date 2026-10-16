// Skills del agente (estándar de Anthropic) cargados como un plugin local del Agent SDK.
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";

export const PLUGIN_NAME = "frontbot-agent";
export type RunSkill = { name: string; dir: string };
export type SkillPlugin = { path: string; skillNames: string[]; dirs: string[]; cleanup: () => void };

const SAFE_NAME = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;

/** Directorio temporal con `.claude-plugin/plugin.json` y `skills/<nombre>` → carpeta de la biblioteca. */
export function prepareSkillPlugin(skills: RunSkill[]): SkillPlugin {
  const path = mkdtempSync(join(tmpdir(), "frontbot-plugin-"));
  mkdirSync(join(path, ".claude-plugin"));
  mkdirSync(join(path, "skills"));
  writeFileSync(join(path, ".claude-plugin", "plugin.json"), JSON.stringify({ name: PLUGIN_NAME, version: "1.0.0", description: "Skills del agente de Frontbot" }));
  const names: string[] = [];
  const dirs: string[] = [];
  for (const s of skills) {
    if (!SAFE_NAME.test(s.name)) continue;
    try {
      symlinkSync(s.dir, join(path, "skills", s.name), "dir");
      names.push(`${PLUGIN_NAME}:${s.name}`);
      dirs.push(s.dir);
    } catch { /* skill ilegible: se omite */ }
  }
  return { path, skillNames: names, dirs, cleanup: () => rmSync(path, { recursive: true, force: true }) };
}

const real = (p: string) => { try { return realpathSync(p); } catch { return resolve(p); } };

/** `Read` solo dentro de las carpetas de los skills del run (resolviendo enlaces y `..`). */
export function readGuard(skillDirs: string[], pluginPath: string) {
  const roots = [...skillDirs, join(pluginPath, "skills")].map(real);
  return (filePath: string) => {
    const target = real(resolve(filePath));
    return roots.some((root) => target === root || target.startsWith(root + sep));
  };
}

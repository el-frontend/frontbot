import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, lstatSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { prepareSkillPlugin, readGuard, PLUGIN_NAME } from "../src/skills.js";
import { buildQueryOptions } from "../src/runner.js";
import { TOOL_SPECS } from "../src/tools.js";

const made: (() => void)[] = [];
afterEach(() => { while (made.length) made.pop()!(); });

function skillDir(name: string) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `skill-${name}-`)));
  writeFileSync(join(dir, "SKILL.md"), `---\nname: ${name}\ndescription: d\n---\n`);
  mkdirSync(join(dir, "ref"));
  writeFileSync(join(dir, "ref", "notas.md"), "hola");
  return dir;
}

describe("prepareSkillPlugin", () => {
  it("builds a local plugin with one symlink per skill and cleans it up", () => {
    const a = skillDir("analisis");
    const plugin = prepareSkillPlugin([{ name: "analisis", dir: a }]);
    expect(JSON.parse(readFileSync(join(plugin.path, ".claude-plugin", "plugin.json"), "utf8")).name).toBe(PLUGIN_NAME);
    expect(lstatSync(join(plugin.path, "skills", "analisis")).isSymbolicLink()).toBe(true);
    expect(plugin.skillNames).toEqual([`${PLUGIN_NAME}:analisis`]);
    plugin.cleanup();
    expect(existsSync(plugin.path)).toBe(false);
    expect(existsSync(join(a, "SKILL.md"))).toBe(true);
  });

  it("ignores skills with unsafe names", () => {
    const plugin = prepareSkillPlugin([{ name: "../fuera", dir: skillDir("x") }]);
    made.push(plugin.cleanup);
    expect(plugin.skillNames).toEqual([]);
  });
});

describe("readGuard", () => {
  it("only allows reading inside the run's skill folders", () => {
    const a = skillDir("a");
    const plugin = prepareSkillPlugin([{ name: "a", dir: a }]);
    made.push(plugin.cleanup);
    const guard = readGuard([a], plugin.path);
    expect(guard(join(a, "ref", "notas.md"))).toBe(true);
    expect(guard(join(plugin.path, "skills", "a", "ref", "notas.md"))).toBe(true);
    expect(guard(join(a, "..", "otro.md"))).toBe(false);
    expect(guard("/etc/passwd")).toBe(false);
    expect(guard(join(process.env.HOME ?? "/", ".zshrc"))).toBe(false);
  });
});

describe("buildQueryOptions with skills", () => {
  it("loads the plugin, enables Skill and Read, and guards Read", async () => {
    const a = skillDir("analisis");
    const plugin = prepareSkillPlugin([{ name: "analisis", dir: a }]);
    made.push(plugin.cleanup);
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", skills: [{ name: "analisis", dir: a }] }, server, new AbortController(), "2026-10-16", plugin);
    expect(opts.plugins).toEqual([{ type: "local", path: plugin.path }]);
    expect(opts.skills).toEqual([`${PLUGIN_NAME}:analisis`]);
    expect(opts.tools).toEqual(expect.arrayContaining(["Skill", "Read"]));
    expect(opts.allowedTools).toEqual(expect.arrayContaining(["Skill", "Read"]));
    const pre = opts.hooks!.PreToolUse!;
    const decide = async (file_path: string) => {
      for (const m of pre) for (const h of m.hooks) {
        const out = await h({ hook_event_name: "PreToolUse", tool_name: "Read", tool_input: { file_path }, tool_use_id: "u", session_id: "s", transcript_path: "", cwd: "" } as never, "u", { signal: new AbortController().signal });
        if ((out as { hookSpecificOutput?: { permissionDecision?: string } }).hookSpecificOutput?.permissionDecision === "deny") return "deny";
      }
      return "allow";
    };
    expect(await decide(join(a, "ref", "notas.md"))).toBe("allow");
    expect(await decide("/etc/passwd")).toBe("deny");
  });

  it("without skills there is no plugin, Skill or Read", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-16");
    expect(opts.plugins).toBeUndefined();
    expect(opts.tools).toEqual(["WebSearch", "WebFetch"]);
  });
});

describe("skill tools", () => {
  it("exist for every agent and none activates a skill", () => {
    const names = TOOL_SPECS.map((t) => t.name);
    expect(names).toEqual(expect.arrayContaining(["skills_list", "skills_create_draft", "skills_update_draft", "skills_run_script"]));
    expect(names.some((n) => /activate|approve/.test(n))).toBe(false);
  });
});

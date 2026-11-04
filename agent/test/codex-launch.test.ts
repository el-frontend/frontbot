import { describe, expect, it } from "vitest";
import { codexArgs, codexCaps, codexMaxToolCalls, codexThreadParams, workdirProfileArgs } from "../src/codex/launch.js";
import { workdirDomains, type RunWorkdir } from "../src/workdir.js";
import type { RunParams } from "../src/runner.js";

const base: RunParams = { run_id: "r1", prompt: "hola", model: "gpt-6-astra", provider: "codex", codex_runtime: "session" };
const wd: RunWorkdir = { path: "/Users/u/proyecto", read_dirs: [] };

/** Pares `[flag, valor]` de los `-c`. */
const configs = (args: string[]) => args.flatMap((a, i) => (a === "-c" ? [args[i + 1]] : []));
const disabled = (args: string[]) => args.flatMap((a, i) => (a === "--disable" ? [args[i + 1]] : []));

describe("codexCaps / codexArgs", () => {
  it("chat sin carpeta apaga shell y deja web", () => {
    const args = codexArgs(codexCaps(base));
    expect(args[0]).toBe("app-server");
    expect(disabled(args)).toEqual(expect.arrayContaining(["shell_tool", "unified_exec", "plugins", "apps", "memories", "browser_use", "computer_use", "multi_agent", "image_generation", "goals", "sleep_tool", "tool_suggest"]));
    expect(disabled(args)).not.toContain("code_mode_host");
    expect(configs(args)).not.toContain("tools.web_search=false");
    expect(configs(args)).toContain("mcp_servers={}");
    expect(configs(args)).toContain('cli_auth_credentials_store="file"');
  });

  it("imagen, resumen y métricas apagan web y code mode", () => {
    for (const mode of ["image", "summarize", "metrics"] as const) {
      const args = codexArgs(codexCaps({ ...base, mode }));
      expect(configs(args)).toContain("tools.web_search=false");
      expect(disabled(args)).toContain("code_mode_host");
    }
  });

  it("métricas fuerza browser; imagen nunca", () => {
    expect(codexCaps({ ...base, mode: "metrics" }).browser).toBe(true);
    expect(codexCaps({ ...base, mode: "image", browser: true }).browser).toBe(false);
    expect(codexCaps({ ...base, mode: "study", browser: true }).browser).toBe(false);
  });

  it("workdir solo en chat", () => {
    expect(codexCaps({ ...base, mode: "scheduled", workdir: wd }).shell).toBe(false);
    expect(codexCaps({ ...base, workdir: wd }).shell).toBe(true);
    expect(disabled(codexArgs(codexCaps({ ...base, workdir: wd }), { wd, home: "/Users/u" }))).not.toContain("shell_tool");
  });

  it("skills solo en chat o tareas con skills", () => {
    const skills = [{ name: "s", dir: "/x" }];
    expect(codexCaps({ ...base, skills }).skills).toBe(true);
    expect(codexCaps({ ...base, mode: "study", skills }).skills).toBe(false);
    expect(codexCaps(base).skills).toBe(false);
  });
});

describe("workdirProfileArgs", () => {
  it("niega el home, las rutas protegidas y /tmp; escribe en la carpeta", () => {
    const c = configs(workdirProfileArgs(wd, "/Users/u"));
    expect(c).toContain('default_permissions="frontbot"');
    expect(c).toContain('permissions.frontbot.extends=":workspace"');
    const fs = c.find((x) => x.startsWith("permissions.frontbot.filesystem="))!;
    const table = fs.slice("permissions.frontbot.filesystem=".length);
    expect(table).toContain('"/Users/u"="deny"');
    expect(table).toContain('"/Users/u/proyecto"="write"');
    expect(table).toContain('"/Users/u/.ssh"="deny"');
    expect(table).toContain('":slash_tmp"="deny"');
    expect(table).toContain('":tmpdir"="deny"');
    expect(c).toContain("features.network_proxy=true");
    expect(c).toContain('permissions.frontbot.network.mode="limited"');
    const domains = c.find((x) => x.startsWith("permissions.frontbot.network.domains="))!;
    for (const d of workdirDomains(wd)) expect(domains).toContain(`"${d}"="allow"`);
  });
});

describe("codexThreadParams", () => {
  it("sin shell: sin entornos y sin aprobaciones; con shell: perfil frontbot", () => {
    const tools = [{ type: "function" as const, name: "brands_list", description: "d", inputSchema: { type: "object" } }];
    const plain = codexThreadParams({ params: base, caps: codexCaps(base), instructions: "I", tools, cwd: "/tmp/x" });
    expect(plain).toMatchObject({ model: "gpt-6-astra", cwd: "/tmp/x", ephemeral: true, developerInstructions: "I", dynamicTools: tools, environments: [], approvalPolicy: "never", sandbox: "read-only" });
    expect(plain).not.toHaveProperty("permissions");
    const shell = codexThreadParams({ params: { ...base, workdir: wd }, caps: codexCaps({ ...base, workdir: wd }), instructions: "I", tools, cwd: wd.path });
    expect(shell).toMatchObject({ permissions: "frontbot", approvalPolicy: "on-request" });
    expect(shell).not.toHaveProperty("sandbox");
    expect(shell).not.toHaveProperty("environments");
  });
});

describe("codexMaxToolCalls", () => {
  it("sigue los topes de Claude por modo", () => {
    expect(codexMaxToolCalls({ ...base, mode: "summarize" })).toBe(6);
    expect(codexMaxToolCalls({ ...base, mode: "study" })).toBe(60);
    expect(codexMaxToolCalls({ ...base, workdir: wd })).toBe(150);
    expect(codexMaxToolCalls({ ...base, mode: "metrics" })).toBe(40);
    expect(codexMaxToolCalls(base)).toBe(30);
  });
});

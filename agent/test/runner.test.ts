import { describe, it, expect, vi } from "vitest";
import { mkdtempSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { WORKDIR_TOOLS, sandboxSettings } from "../src/workdir.js";
import { TokenMeter } from "../src/study.js";
import type { AppCall } from "../src/tools.js";
import type { SkillPlugin } from "../src/skills.js";
import { createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { buildQueryOptions, createProductionRunner, createCodexAppServer, ProviderRunner, RealRunner, toolCallText, type RunParams, type Runner } from "../src/runner.js";

describe("ProviderRunner", () => {
  it("dispatches provider runs and preserves their event and completion contract", async () => {
    const calls: string[] = [];
    const runner = (name: string): Runner => ({
      async run(params, emit) {
        calls.push(`${name}:${params.provider ?? "claude"}`);
        emit({ run_id: params.run_id, type: "text", text: name });
        return { run_id: params.run_id, ok: true, summary: name, input_tokens: 1, output_tokens: 2, cost_usd: 0 };
      },
    });
    const router = new ProviderRunner(runner("claude"), runner("codex"));
    const events: unknown[] = [];
    const claude = await router.run({ run_id: "c", prompt: "p", model: "claude", provider: "claude" }, (e) => events.push(e), new AbortController().signal);
    const codex = await router.run({ run_id: "x", prompt: "p", model: "codex", provider: "codex" }, (e) => events.push(e), new AbortController().signal);
    expect(calls).toEqual(["claude:claude", "codex:codex"]);
    expect(events).toEqual([{ run_id: "c", type: "text", text: "claude" }, { run_id: "x", type: "text", text: "codex" }]);
    expect(claude).toMatchObject({ run_id: "c", ok: true, summary: "claude" });
    expect(codex).toMatchObject({ run_id: "x", ok: true, summary: "codex" });
  });

  it("forwards internal Frontbot tool context to Codex but not Claude", async () => {
    let received: unknown;
    let claudeContext: unknown;
    const codex: Runner = { async run(_params, _emit, _signal, context) {
      received = context;
      return { run_id: "x", ok: true, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0 };
    } };
    const router = new ProviderRunner({ async run(_params, _emit, _signal, context) {
      claudeContext = context;
      return { run_id: "c", ok: true, summary: "", input_tokens: 0, output_tokens: 0, cost_usd: 0 };
    } }, codex);
    const context = { frontbot: { context: { isDefault: true }, execute: async () => ({ content: [{ type: "text" as const, text: "{}" }] }) } };
    await router.run({ run_id: "x", prompt: "p", model: "codex", provider: "codex" }, () => {}, new AbortController().signal, context);
    expect(received).toBe(context);
    await router.run({ run_id: "c", prompt: "p", model: "claude", provider: "claude" }, () => {}, new AbortController().signal, context);
    expect(claudeContext).toBeUndefined();
  });
});

describe("provider child environment", () => {
  it("production Codex provider fails closed before attempting native shell or file access", async () => {
    const runner = createProductionRunner(async () => ({}), {
      PATH: "/bin", FRONTBOT_CODEX_EXECUTABLE: "/test/codex", FRONTBOT_OPENAI_API_KEY: "test-key",
    });
    const shell = await runner.run({ run_id: "shell", prompt: "run cat ~/.ssh/id_rsa", model: "gpt-6-astra", provider: "codex" }, () => {}, new AbortController().signal);
    const read = await runner.run({ run_id: "read", prompt: "read /Users/other/private.txt", model: "gpt-6-astra", provider: "codex" }, () => {}, new AbortController().signal);
    expect(shell.error).toContain("integración de Codex está deshabilitada");
    expect(read.error).toContain("integración de Codex está deshabilitada");
  });

  it("production bootstrap scrubs secrets from the sidecar before Claude can use it", () => {
    const env = { PATH: "/bin", ANTHROPIC_API_KEY: "claude-config", OPENAI_API_KEY: "shell-openai",
      FRONTBOT_OPENAI_API_KEY: "codex-config", FRONTBOT_CODEX_EXECUTABLE: "/bin/codex" };
    const runner = createProductionRunner(async () => ({}), env);
    expect(env).toEqual({ PATH: "/bin", ANTHROPIC_API_KEY: "claude-config", FRONTBOT_CODEX_EXECUTABLE: "/bin/codex" });
    expect(runner.claudeEnvironment(env)).toEqual({ PATH: "/bin", ANTHROPIC_API_KEY: "claude-config" });
    expect(runner.codexEnvironment(env)).toEqual({ PATH: "/bin", OPENAI_API_KEY: "codex-config" });
  });

  it("production Codex app-server spawn receives the key in env only", () => {
    let launch: { executable: string; args: string[]; env: NodeJS.ProcessEnv } | undefined;
    createCodexAppServer({ executable: "/bin/codex", apiKey: "secret-openai" }, {
      inherited: { PATH: "/bin", ANTHROPIC_API_KEY: "secret-anthropic", OPENAI_API_KEY: "shell-openai" },
      spawn: (executable, args, options) => {
        launch = { executable, args, env: options.env };
        return {} as never;
      },
    });
    expect(launch).toEqual({ executable: "/bin/codex", args: ["app-server", "--listen", "stdio://"], env: { PATH: "/bin", OPENAI_API_KEY: "secret-openai" } });
    expect(JSON.stringify(launch?.args)).not.toContain("secret-openai");
  });
});

describe("buildQueryOptions", () => {
  it("does not persist sessions to ~/.claude and keeps the tool lockdown", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-13");
    expect(opts.persistSession).toBe(false);
    expect(opts.tools).toEqual(["WebSearch", "WebFetch"]);
    expect(opts.permissionMode).toBe("dontAsk");
    expect(opts.settingSources).toEqual([]);
    expect(opts.strictMcpConfig).toBe(true);
    expect(opts.model).toBe("m");
  });

  it("leaves the user's browser off unless asked", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-13");
    expect(opts.extraArgs).toBeUndefined();
    expect(opts.allowedTools?.some((t) => t.includes("claude-in-chrome"))).toBe(false);
  });

  it("enables Claude in Chrome behind the guard when browser is on", async () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", browser: true }, server, new AbortController(), "2026-10-13");
    expect(opts.extraArgs).toEqual({ chrome: null });
    expect(opts.allowedTools).toContain("mcp__claude-in-chrome__computer");
    expect(opts.allowedTools).not.toContain("mcp__claude-in-chrome__javascript_tool");
    expect(opts.systemPrompt).toContain("Chrome");
    const pre = opts.hooks?.PreToolUse?.[0].hooks[0];
    const out = await pre!({ hook_event_name: "PreToolUse", tool_name: "mcp__claude-in-chrome__javascript_tool", tool_input: {}, tool_use_id: "u", session_id: "s", transcript_path: "", cwd: "" } as never, "u", { signal: new AbortController().signal });
    expect(out).toMatchObject({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny" } });
  });

  it("uses the agent's prompt and hides Frontbot-only tools from specialists", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const agent = { id: "a1", name: "Crypto Trader", instructions: "Siempre stop loss.", is_default: false };
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", agent }, server, new AbortController(), "2026-10-16");
    expect(opts.systemPrompt).toContain("Eres Crypto Trader");
    expect(opts.allowedTools).not.toContain("mcp__frontbot__agents_create_draft");
    const def = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-16");
    expect(def.allowedTools).toContain("mcp__frontbot__agents_create_draft");
  });

  it("summarize mode only exposes memory tools and asks for a summary", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const agent = { id: "a1", name: "T", instructions: "x", is_default: false, memory: [] };
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m", agent, mode: "summarize", browser: true }, server, new AbortController(), "2026-10-16");
    expect(opts.allowedTools?.every((t) => t.startsWith("mcp__frontbot__memory_"))).toBe(true);
    expect(opts.tools).toEqual([]);
    expect(opts.extraArgs).toBeUndefined();
    expect(opts.maxTurns).toBeLessThanOrEqual(8);
  });

  it("every agent has memory tools", () => {
    const server = createSdkMcpServer({ name: "frontbot", version: "0.1.0", tools: [] });
    const opts = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-16");
    expect(opts.allowedTools).toContain("mcp__frontbot__memory_remember");
  });
});

describe("folders", () => {
  const server = createSdkMcpServer({ name: "frontbot", version: "0" });
  const base = { run_id: "r", prompt: "hola", model: "m", agent: { id: "a", name: "Redactor", instructions: "x", is_default: false } };

  it("authorized folders enable the file tools and are listed in the prompt", () => {
    const opts = buildQueryOptions({ ...base, folders: ["/Users/u/marcas"] }, server, new AbortController(), "2026-10-16");
    expect(opts.allowedTools).toContain("mcp__frontbot__files_write");
    expect(String(opts.systemPrompt)).toContain("/Users/u/marcas");
    expect(opts.tools).not.toContain("Write"); // nunca las herramientas de archivos del SDK
  });

  it("without folders there are no file tools", () => {
    const opts = buildQueryOptions(base, server, new AbortController(), "2026-10-16");
    expect(opts.allowedTools?.some((t) => t.includes("files_"))).toBe(false);
  });
});

describe("workdir", () => {
  const server = createSdkMcpServer({ name: "frontbot", version: "0" });
  const wd = { path: mkdtempSync(join(tmpdir(), "wd-")), read_dirs: [join(homedir(), "Downloads")] };
  const base = { run_id: "r", prompt: "hola", model: "m", workdir: wd };
  const build = (p: Partial<RunParams> = {}, call?: AppCall, plugin?: SkillPlugin) =>
    buildQueryOptions({ ...base, ...p }, server, new AbortController(), "2026-10-18", plugin, undefined, call);
  const hook = async (opts: ReturnType<typeof build>, tool_name: string, tool_input: unknown, tool_use_id = "u") => {
    const m = opts.hooks!.PreToolUse!.find((x) => !x.matcher)!;
    return (await m.hooks[0]({ hook_event_name: "PreToolUse", tool_name, tool_input, tool_use_id } as never, undefined, { signal: new AbortController().signal })) as Record<string, any>;
  };

  it("chat with a workdir gets built-in tools, sandbox and 150 turns", () => {
    for (const mode of [undefined, "chat" as const]) {
      const o = build({ mode });
      expect(o.cwd).toBe(wd.path);
      expect(o.tools).toEqual(expect.arrayContaining([...WORKDIR_TOOLS, "WebSearch", "WebFetch"]));
      expect(new Set(o.tools).size).toBe(o.tools!.length);
      expect(o.allowedTools).toEqual(expect.arrayContaining(WORKDIR_TOOLS));
      expect(o.sandbox).toEqual(sandboxSettings(wd, homedir(), [dirname(process.execPath), "/Applications/Google Chrome.app", "/Applications/Chromium.app", "/opt/homebrew", "/usr/local"]));
      expect(o.maxTurns).toBe(150);
      expect(o.hooks!.PreToolUse!.some((m) => !m.matcher)).toBe(true);
      expect(String(o.systemPrompt)).toContain(`Carpeta de trabajo: ${wd.path}`);
    }
  });

  it("other modes ignore the workdir", () => {
    for (const mode of ["scheduled", "study", "summarize"] as const) {
      const o2 = buildQueryOptions({ ...base, mode, study: { topic_id: "t", session_id: "s" } as never }, server, new AbortController(), "2026-10-18", undefined, new TokenMeter(10));
      expect(o2.cwd).toBeUndefined();
      expect(o2.sandbox).toBeUndefined();
      expect(o2.tools).not.toContain("Bash");
      expect(o2.maxTurns).toBe(mode === "summarize" ? 6 : mode === "study" ? 60 : 30);
    }
  });

  it("an invalid workdir fails the run without calling query", async () => {
    const queryFn = vi.fn();
    const r = await new RealRunner(async () => ({}), queryFn as never).run({ ...base, workdir: { path: "/no/existe/xyz", read_dirs: [] } }, () => {}, new AbortController().signal);
    expect(r.ok).toBe(false);
    expect(r.error).toBe("La carpeta no existe.");
    expect(queryFn).not.toHaveBeenCalled();
  });

  it("hook denies reads outside with the guard's reason", async () => {
    const r = await hook(build(), "Read", { file_path: "/etc/hosts" });
    expect(r.hookSpecificOutput.permissionDecision).toBe("deny");
    expect(r.hookSpecificOutput.permissionDecisionReason).toContain("Fuera de la carpeta de trabajo");
  });

  it("hook asks the app for writes outside and obeys the answer", async () => {
    const path = join(homedir(), "Downloads", "x.txt");
    const call = vi.fn().mockResolvedValueOnce({ allow: true }).mockResolvedValueOnce({ allow: false }).mockRejectedValueOnce(new Error("sin app"));
    const o = build({}, call);
    expect(await hook(o, "Write", { file_path: path, content: "hola" })).toEqual({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "Aprobado por el usuario" } });
    expect(call).toHaveBeenCalledWith("workdir.approve", { run_id: "r", kind: "write", tool: "Write", path: realpathSync(join(homedir(), "Downloads")) + "/x.txt", content: "hola" });
    const denied = await hook(o, "Write", { file_path: path, content: "hola" });
    expect(denied.hookSpecificOutput.permissionDecisionReason).toBe("El usuario lo denegó; no insistas.");
    expect((await hook(o, "Write", { file_path: path, content: "hola" })).hookSpecificOutput.permissionDecision).toBe("deny");
  });

  it("an approved unsandboxed Bash ask is explicitly allowed, a denied one is not", async () => {
    const call = vi.fn().mockResolvedValueOnce({ allow: true }).mockResolvedValueOnce({ allow: false });
    const o = build({}, call);
    const input = { command: "npx hyperframes render", dangerouslyDisableSandbox: true };
    expect((await hook(o, "Bash", input)).hookSpecificOutput.permissionDecision).toBe("allow");
    expect(call).toHaveBeenCalledWith("workdir.approve", { run_id: "r", kind: "unsandboxed", command: "npx hyperframes render" });
    expect((await hook(o, "Bash", input)).hookSpecificOutput.permissionDecision).toBe("deny");
    expect(await hook(o, "Bash", { command: "ls" })).toEqual({});
  });

  it("with a workdir the mode is default with a deny-by-default canUseTool; without it, dontAsk", async () => {
    expect(build().permissionMode).toBe("default");
    expect(typeof build().canUseTool).toBe("function");
    const plain = buildQueryOptions({ run_id: "r", prompt: "p", model: "m" }, server, new AbortController(), "2026-10-18");
    expect(plain.permissionMode).toBe("dontAsk");
    expect(plain.canUseTool).toBeUndefined();
  });

  it("canUseTool denies unknown tools and unapproved unsandboxed Bash, and allows an approved call once", async () => {
    const call = vi.fn().mockResolvedValue({ allow: true });
    const o = build({}, call);
    const cu = o.canUseTool!;
    const opt = (id?: string) => ({ signal: new AbortController().signal, toolUseID: id }) as never;
    const bash = { command: "npx hyperframes render", dangerouslyDisableSandbox: true };
    const no = { behavior: "deny", message: expect.stringContaining("Frontbot no permite esta acción") };
    expect(await cu("WebFetch", {}, opt("u"))).toEqual(no);
    expect(await cu("Bash", bash, opt("u"))).toEqual(no);
    await hook(o, "Bash", bash, "u");
    expect(await cu("Bash", { ...bash, command: "otro" }, opt("u"))).toEqual(no);
    expect(await cu("Bash", { command: bash.command }, opt("u"))).toEqual(no);
    expect(await cu("Bash", bash, opt(undefined))).toEqual(no);
    expect(await cu("Bash", bash, opt("u"))).toEqual({ behavior: "allow", updatedInput: bash });
    expect(await cu("Bash", bash, opt("u"))).toEqual(no);
  });

  it("canUseTool: an approval for one tool use does not allow another with the same command", async () => {
    const o = build({}, vi.fn().mockResolvedValue({ allow: true }));
    const bash = { command: "npx hyperframes render", dangerouslyDisableSandbox: true };
    await hook(o, "Bash", bash, "A");
    expect(await o.canUseTool!("Bash", bash, { signal: new AbortController().signal, toolUseID: "B" } as never)).toMatchObject({ behavior: "deny" });
    expect(await o.canUseTool!("Bash", bash, { signal: new AbortController().signal, toolUseID: "A" } as never)).toMatchObject({ behavior: "allow" });
  });

  it("canUseTool denies an approved unsandboxed ask with an empty or non-string command", async () => {
    const o = build({}, vi.fn().mockResolvedValue({ allow: true }));
    const opt = (id: string) => ({ signal: new AbortController().signal, toolUseID: id }) as never;
    for (const [id, command] of [["E", ""], ["N", 42]] as const) {
      const bash = { command, dangerouslyDisableSandbox: true };
      await hook(o, "Bash", bash, id);
      expect(await o.canUseTool!("Bash", bash, opt(id))).toMatchObject({ behavior: "deny" });
    }
  });

  it("workdir runs keep npm/puppeteer caches inside the folder", () => {
    const env = build().env!;
    expect(env.npm_config_cache).toBe(join(wd.path, ".frontbot-cache", "npm"));
    expect(env.XDG_CACHE_HOME).toBe(join(wd.path, ".frontbot-cache"));
    expect(env.PUPPETEER_CACHE_DIR).toBe(join(wd.path, ".frontbot-cache", "puppeteer"));
    expect(env.PATH).toBe(process.env.PATH);
  });

  it("canUseTool: a user-denied unsandboxed ask leaves nothing approved", async () => {
    const o = build({}, vi.fn().mockResolvedValue({ allow: false }));
    const bash = { command: "npx hyperframes render", dangerouslyDisableSandbox: true };
    expect((await hook(o, "Bash", bash, "A")).hookSpecificOutput.permissionDecision).toBe("deny");
    expect(await o.canUseTool!("Bash", bash, { signal: new AbortController().signal, toolUseID: "A" } as never)).toMatchObject({ behavior: "deny" });
  });

  it("with skills, skill files are readable outside the folder but protected paths never are", async () => {
    const dir = mkdtempSync(join(tmpdir(), "sk-"));
    mkdirSync(join(dir, "skills"));
    writeFileSync(join(dir, "skills", "SKILL.md"), "x");
    const plugin = { path: dir, skillNames: ["a"], dirs: [dir], cleanup() {} };
    const o = build({}, undefined, plugin);
    expect(await hook(o, "Read", { file_path: join(dir, "skills", "SKILL.md") })).toEqual({});
    const evil = { ...plugin, dirs: [homedir()] };
    const r = await hook(build({}, undefined, evil), "Read", { file_path: join(homedir(), ".ssh", "x") });
    expect(r.hookSpecificOutput.permissionDecision).toBe("deny");
  });

  it("tool_call text carries the detail, relative to the folder", () => {
    expect(toolCallText("Bash", { command: "ls" }, wd)).toBe("Bash · ls");
    expect(toolCallText("Read", { file_path: `${wd.path}/a/b.md` }, wd)).toBe("Read · a/b.md");
    expect(toolCallText("Grep", { pattern: "x".repeat(200) }, wd)).toBe(`Grep · ${"x".repeat(120)}`);
    expect(toolCallText("TodoWrite", { todos: [] }, wd)).toBe("TodoWrite");
    expect(toolCallText("mcp__frontbot__lab_note", {}, wd)).toBe("lab_note");
  });
});

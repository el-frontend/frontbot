import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, existsSync, realpathSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { AppServer, type Spawn } from "../src/codex/appServer.js";
import { CodexAppRunner } from "../src/codex-app-runner.js";
import { toolContext, type RunEvent, type RunParams, type RunnerContext } from "../src/runner.js";

const FAKE = fileURLToPath(new URL("./fixtures/fake-codex.mjs", import.meta.url));
const base: RunParams = { run_id: "r1", prompt: "hola", model: "gpt-6-astra", provider: "codex", codex_runtime: "session",
  agent: { id: "a1", name: "Redactor", instructions: "Escribe claro.", is_default: false } };

let logFile = "";
const spawned: Spawn[] = [];
function runner(opts: Partial<ConstructorParameters<typeof CodexAppRunner>[0]> = {}, env: NodeJS.ProcessEnv = {}) {
  logFile = join(mkdtempSync(join(tmpdir(), "fb-codex-log-")), "log.jsonl");
  return new CodexAppRunner({
    bin: "/fake/codex", home: mkdtempSync(join(tmpdir(), "fb-codex-home-")),
    version: async () => "codex-cli 0.158.0",
    start: (s) => { spawned.push(s); return AppServer.start({ ...s, command: process.execPath, args: [FAKE, ...s.args], env: { ...s.env, FAKE_CODEX_LOG: logFile, ...env } }); },
    startChrome: async () => null,
    ...opts,
  });
}
const logged = (method: string) => existsSync(logFile)
  ? readFileSync(logFile, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((e) => e.method === method)
  : [];

function ctx(params: RunParams, output: unknown = { brands: [{ id: "b1", name: "Marca" }] }) {
  const execute = vi.fn(async () => output as never);
  const context: RunnerContext = { frontbot: { call: vi.fn(), context: toolContext(params), execute } };
  return { execute, context };
}

async function run(r: CodexAppRunner, params: RunParams, signal = new AbortController().signal) {
  const events: RunEvent[] = [];
  const { execute, context } = ctx(params);
  const done = await r.run(params, (e) => events.push(e), signal, context);
  return { done, events, execute };
}

afterEach(() => { spawned.length = 0; });

describe("CodexAppRunner", () => {
  it("chat de texto: eventos, resumen y tokens", async () => {
    const { done, events } = await run(runner(), base);
    expect(events).toEqual([
      { run_id: "r1", type: "status", text: "pensando" },
      { run_id: "r1", type: "text", text: "Ho" },
      { run_id: "r1", type: "text", text: "la" },
    ]);
    expect(done).toEqual({ run_id: "r1", ok: true, summary: "Hola", input_tokens: 10, output_tokens: 3, cost_usd: null, runtime: "session" });
  });

  it("arranca con CODEX_HOME propio y sin shell en chat", async () => {
    await run(runner(), base);
    expect(spawned[0].env.CODEX_HOME).toMatch(/fb-codex-home-/);
    expect(spawned[0].env.OPENAI_API_KEY).toBeUndefined();
    expect(spawned[0].args).toEqual(expect.arrayContaining(["--disable", "shell_tool"]));
  });

  it("una herramienta de Frontbot pasa por execute", async () => {
    const { done, execute } = await run(runner(), { ...base, prompt: "usa brands_list" });
    expect(execute).toHaveBeenCalledWith("brands_list", {});
    expect(done.summary).toContain("ok:true");
    expect(done.summary).toContain("Marca");
  });

  it("una herramienta fuera de la lista no llega a execute", async () => {
    const { done, execute } = await run(runner(), { ...base, prompt: "usa desconocida" });
    expect(execute).not.toHaveBeenCalled();
    expect(done.summary).toBe("ok:false:La herramienta solicitada no está permitida.");
  });

  it("params del hilo: sin entornos en chat y lista cerrada en imagen", async () => {
    await run(runner(), base);
    const chat = logged("thread/start")[0].params;
    expect(chat.environments).toEqual([]);
    expect(chat.ephemeral).toBe(true);
    expect(chat.dynamicTools.map((t: { name: string }) => t.name)).toContain("posts_list");
    await run(runner(), { ...base, mode: "image", image: { kind: "html", count: 1 }, prompt: "x" });
    const image = logged("thread/start")[0].params;
    expect(image.dynamicTools.map((t: { name: string }) => t.name).sort()).toEqual(["brands_get_guide", "brands_list", "brands_list_assets", "images_render_html"]);
  });

  it("modelo no disponible en la sesión", async () => {
    const { done } = await run(runner(), { ...base, model: "gpt-6.1-terra" });
    expect(done).toMatchObject({ ok: false, error: "Elige un modelo disponible en la ficha del agente.", runtime: "session" });
  });

  it("sin binario no arranca nada ni usa la API", async () => {
    const start = vi.fn();
    const { done, execute } = await run(runner({ bin: null, start }), base);
    expect(done).toMatchObject({ ok: false, error: "Codex no está instalado. Instálalo o conecta solo la API key en Ajustes.", runtime: "session" });
    expect(start).not.toHaveBeenCalled();
    expect(execute).not.toHaveBeenCalled();
  });

  it("versión vieja pide actualizar", async () => {
    const { done } = await run(runner({ version: async () => "codex-cli 0.150.0" }), base);
    expect(done).toMatchObject({ ok: false, error: "Actualiza Codex para usarlo en Frontbot." });
  });

  it("sesión caducada termina con su error, una sola vez", async () => {
    const events: RunEvent[] = [];
    const { context } = ctx(base);
    const done = await runner().run({ ...base, prompt: "falla" }, (e) => events.push(e), new AbortController().signal, context);
    expect(done.ok).toBe(false);
    expect(done.error).toContain("session expired");
  });

  it("si el proceso muere, error claro", async () => {
    const { done } = await run(runner(), { ...base, prompt: "muere" });
    expect(done).toMatchObject({ ok: false, error: "Codex se cerró inesperadamente." });
  });

  it("cancelar un turno colgado termina rápido", async () => {
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 150);
    const t0 = Date.now();
    const { done } = await run(runner(), { ...base, prompt: "cuelga" }, controller.signal);
    expect(done).toMatchObject({ ok: false, error: "Cancelado" });
    expect(Date.now() - t0).toBeLessThan(3000);
  });

  it("tope de herramientas", async () => {
    const { done } = await run(runner(), { ...base, prompt: "muchas" });
    expect(done.ok).toBe(false);
    expect(done.error).toContain("límite de herramientas");
  });

  it("métricas sin Chrome: sin herramientas de navegador y sin colgarse", async () => {
    const { done } = await run(runner(), { ...base, mode: "metrics", prompt: "hola" });
    expect(done.ok).toBe(true);
    const names = logged("thread/start")[0].params.dynamicTools.map((t: { name: string }) => t.name);
    expect(names).not.toContain("navigate");
    expect(names).toEqual(expect.arrayContaining(["metrics_post", "posts_record_metrics"]));
  });

  it("con Chrome, sus herramientas se exponen y pasan por el puente", async () => {
    const call = vi.fn(async () => ({ success: true, text: "Tab 1: https://example.com" }));
    const bridge = { tools: [{ type: "function" as const, name: "tabs_context_mcp", description: "d", inputSchema: { type: "object" } }], has: (n: string) => n === "tabs_context_mcp", call, close: vi.fn() };
    const { done } = await run(runner({ startChrome: async () => bridge as never }), { ...base, browser: true, prompt: "chrome" });
    expect(call).toHaveBeenCalledWith("tabs_context_mcp", {});
    expect(done.summary).toBe("ok:true:Tab 1: https://example.com");
    expect(bridge.close).toHaveBeenCalled();
  });
});

describe("CodexAppRunner · carpeta, skills y estudio", () => {
  const folder = () => realpathSync(mkdtempSync(join(tmpdir(), "fb-wd-")));
  const withCall = (params: RunParams, call: ReturnType<typeof vi.fn>) => {
    const execute = vi.fn(async () => ({}) as never);
    return { execute, context: { frontbot: { call, context: toolContext(params), execute } } as RunnerContext };
  };
  const go = async (r: CodexAppRunner, params: RunParams, call = vi.fn(async () => ({ allow: false }))) => {
    const { context } = withCall(params, call);
    return { done: await r.run(params, () => {}, new AbortController().signal, context), call };
  };

  it("un comando con ruta protegida se declina sin preguntar", async () => {
    const wd = { path: folder(), read_dirs: [] };
    const { done, call } = await go(runner(), { ...base, workdir: wd, prompt: "shell" });
    expect(done.summary).toBe("decision:decline");
    expect(call).not.toHaveBeenCalled();
  });

  it("un comando fuera de la sandbox pregunta a la app", async () => {
    const wd = { path: folder(), read_dirs: [] };
    const yes = await go(runner(), { ...base, workdir: wd, prompt: "shell npm install" }, vi.fn(async () => ({ allow: true })));
    expect(yes.call).toHaveBeenCalledWith("workdir.approve", { run_id: "r1", kind: "unsandboxed", command: "npm install" });
    expect(yes.done.summary).toBe("decision:accept");
    const no = await go(runner(), { ...base, workdir: wd, prompt: "shell npm install" });
    expect(no.done.summary).toBe("decision:decline");
  });

  it("con carpeta arranca con el perfil de permisos y sin entornos vacíos", async () => {
    const wd = { path: folder(), read_dirs: [] };
    await go(runner(), { ...base, workdir: wd });
    expect(spawned[0].args).toContain('default_permissions="frontbot"');
    expect(spawned[0].args).not.toContain("shell_tool");
    expect(spawned[0].cwd).toBe(wd.path);
    expect(logged("thread/start")[0].params).toMatchObject({ permissions: "frontbot", approvalPolicy: "on-request" });
  });

  it("una escritura fuera de la carpeta pregunta como write", async () => {
    const wd = { path: folder(), read_dirs: [] };
    const outside = join(folder(), "fuera.txt");
    const { done, call } = await go(runner({}, { FAKE_OUTSIDE_PATH: outside }), { ...base, workdir: wd, prompt: "escribe fuera" }, vi.fn(async () => ({ allow: true })));
    expect(call).toHaveBeenCalledWith("workdir.approve", expect.objectContaining({ run_id: "r1", kind: "write", path: outside }));
    expect(done.summary).toBe("decision:accept");
  });

  it("un cambio de archivo desconocido o con grantRoot se declina", async () => {
    const wd = { path: folder(), read_dirs: [] };
    const unknown = await go(runner({}, { FAKE_FILE_ITEM: "otro" }), { ...base, workdir: wd, prompt: "escribe fuera" }, vi.fn(async () => ({ allow: true })));
    expect(unknown.done.summary).toBe("decision:decline");
    const grant = await go(runner({}, { FAKE_GRANT_ROOT: "/" }), { ...base, workdir: wd, prompt: "escribe fuera" }, vi.fn(async () => ({ allow: true })));
    expect(grant.done.summary).toBe("decision:decline");
  });

  it("una petición de permisos se declina", async () => {
    const { done } = await go(runner(), { ...base, prompt: "permisos" });
    expect(done.summary).toContain('"decision":"decline"');
  });

  it("una carpeta inválida no arranca Codex", async () => {
    const start = vi.fn();
    const { done } = await go(runner({ start }), { ...base, workdir: { path: homedir(), read_dirs: [] } });
    expect(done.ok).toBe(false);
    expect(done.error).toContain("Elige una carpeta concreta");
    expect(start).not.toHaveBeenCalled();
  });

  it("skills_read lee dentro de los skills y niega fuera", async () => {
    const dir = folder();
    writeFileSync(join(dir, "SKILL.md"), "# Mi skill\nPasos.");
    const params: RunParams = { ...base, skills: [{ name: "mi-skill", dir }], prompt: "lee skill" };
    const { done } = await go(runner({}, { FAKE_SKILL_PATH: join(dir, "SKILL.md") }), params);
    expect(done.summary).toBe("a:true:# Mi skill\nPasos.|b:false:skills_read solo puede leer archivos de tus skills.");
    const thread = logged("thread/start")[0].params;
    expect(thread.developerInstructions).toContain("Skills disponibles");
    expect(thread.developerInstructions).toContain(join(dir, "SKILL.md"));
    expect(thread.dynamicTools.map((t: { name: string }) => t.name)).toContain("skills_read");
  });

  it("el estudio corta por tokens y avisa una vez", async () => {
    const study = { topic_id: "t1", session_id: "s1", question: "¿Q?", why: "porque", budget_tokens: 140, allow_opus: false, notebook: null };
    const params: RunParams = { ...base, mode: "study", study: study as never, prompt: "estudio" };
    const { done } = await go(runner(), params);
    expect(done).toMatchObject({ ok: true, cut: true, cut_reason: "tokens" });
    expect(done.lab_tokens).toBeGreaterThanOrEqual(140);
    expect(logged("turn/steer")).toHaveLength(1);
    expect(logged("turn/start")[0].params.input[0].text).not.toContain("Cuándo delegar");
  });
});

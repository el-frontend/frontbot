// Prueba manual contra el Codex real (gasta unos pocos tokens de la suscripción conectada).
// Uso: cd agent && npm run build && FRONTBOT_CODEX_HOME=<carpeta con sesión> node scripts/codex-smoke.mjs
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { CodexAppRunner } from "../dist/codex-app-runner.js";
import { codexVersion, locateCodex } from "../dist/codex/account.js";
import { ChromeBridge, claudeChromeCommand } from "../dist/codex/chromeBridge.js";
import { toolContext } from "../dist/runner.js";

const home = process.env.FRONTBOT_CODEX_HOME;
if (!home) { console.error("Falta FRONTBOT_CODEX_HOME"); process.exit(2); }
const bin = locateCodex(process.env);
const runner = new CodexAppRunner({ bin, home, version: codexVersion(bin) });
const model = process.env.SMOKE_MODEL ?? "gpt-6-luna";
let failures = 0;
const report = (name, ok, detail = "") => { if (!ok) failures++; console.log(`${ok ? "OK   " : "FALLO"} ${name}${detail ? ` — ${detail}` : ""}`); };

async function run(params, call = async () => ({ allow: false })) {
  const events = [];
  const execute = async () => ({ brands: [{ id: "b1", name: "Marca Prueba" }] });
  const done = await runner.run({ run_id: "smoke", model, provider: "codex", codex_runtime: "session", ...params }, (e) => events.push(e), new AbortController().signal,
    { frontbot: { call, context: toolContext(params), execute } });
  return { done, events };
}

// 1. chat con herramienta de Frontbot
{
  const { done } = await run({ prompt: "Llama a brands_list y dime solo el nombre de la marca." });
  report("chat", done.ok && done.summary.includes("Marca Prueba"), done.error ?? done.summary.slice(0, 80));
}
// 2. sin shell
{
  const { done, events } = await run({ prompt: "Ejecuta `ls ~` con un shell si puedes y dime qué pasó." });
  report("sin shell", done.ok && !events.some((e) => e.type === "tool_call" && e.text.startsWith("Bash ·")), done.error ?? done.summary.slice(0, 80));
}
// 3. carpeta de trabajo: lee/escribe dentro, no lee un secreto del home
{
  const base = mkdtempSync(join(homedir(), ".frontbot-smoke-"));
  const wd = join(base, "proyecto"); mkdirSync(wd);
  const secretDir = join(base, "otra"); mkdirSync(secretDir);
  writeFileSync(join(secretDir, "secreto.txt"), "SMOKE_SECRET_42");
  const { done } = await run({ prompt: `Con tu shell, como comandos aparte: 1) cat ${join(secretDir, "secreto.txt")} 2) echo hola > dentro.txt. No pidas escalar. Di literalmente qué salió en cada uno.`, workdir: { path: wd, read_dirs: [] } });
  report("carpeta", done.ok && !done.summary.includes("SMOKE_SECRET_42") && existsSync(join(wd, "dentro.txt")), done.error ?? done.summary.slice(0, 120));
  rmSync(base, { recursive: true, force: true });
}
// 4. chrome: solo el contexto de pestañas, sin navegar
{
  const bridge = await ChromeBridge.start(claudeChromeCommand(process.env));
  if (!bridge) report("chrome", false, "el puente no arrancó (¿extensión conectada?)");
  else { const r = await bridge.call("tabs_context_mcp", {}); bridge.close(); report("chrome", r.success, r.text.slice(0, 80)); }
}
process.exit(failures ? 1 : 0);

// Prueba real de la sandbox de la carpeta de trabajo (gasta tokens, usa Haiku).
// Uso: cd agent && npx vite-node scripts/workdir-probe.ts <checks|render>
// Crea ~/frontbot-probe-<fecha>, lanza RealRunner con un `call` falso que aprueba todo y registra,
// y escribe en stdout cada petición, cada tool_call y el RunDone. Borrar la carpeta a mano al terminar.
import { mkdirSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { RealRunner, type RunParams } from "../src/runner.js";

const step = process.argv[2] ?? "checks";
const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 12).replace(/^(\d{8})(\d{4})$/, "$1-$2");
const dir = process.env.PROBE_DIR ?? join(homedir(), `frontbot-probe-${stamp}`);
mkdirSync(dir, { recursive: true });
const path = realpathSync(dir);
const downloads = realpathSync(join(homedir(), "Downloads"));
console.log(JSON.stringify({ probe_dir: path, read_dirs: [downloads] }));

const CHECKS = `Ejecuta con la herramienta Bash, uno por uno y EXACTAMENTE como están escritos (sin reformular ni buscar rodeos), estos comandos, y para cada uno informa literalmente el comando, el código de salida y la salida (stdout/stderr) tal cual:
1. echo ok > dentro.txt
2. echo x > ~/fuera-probe.txt
3. cat ~/Documents/*
4. ls ~/Desktop
5. ls ~/Downloads
6. curl -sI https://example.com | head -1
7. npx -y hyperframes --version
8. echo x > ~/.npm/probe
Si un comando falla, no lo reintentes de otra forma: solo informa el error.`;

const RENDER = `Crea con HyperFrames (paquete npm \`hyperframes\`; usa \`npx -y hyperframes --help\` para aprender su uso) un vídeo de 3 segundos con el texto "Hola Frontbot" sobre fondo negro, hazlo y renderízalo a .mp4 dentro de la carpeta actual. Usa Bash. Si un comando falla por la sandbox (EPERM u operation not permitted), reintenta ese mismo comando con dangerouslyDisableSandbox true para que el usuario lo apruebe. Informa la ruta del .mp4 y cada error literal que veas.`;

const params: RunParams = {
  run_id: "probe-" + step,
  prompt: step === "render" ? RENDER : CHECKS,
  model: "claude-haiku-4-5-20251001",
  mode: "chat",
  workdir: { path, read_dirs: [downloads] },
};

const call = async (method: string, p: Record<string, unknown>) => {
  console.log("CALL " + JSON.stringify({ method, params: p }));
  return { allow: true };
};

// Envuelve query() para registrar los resultados de herramientas (mensajes `user` con tool_result).
const loggingQuery = ((args: Parameters<typeof query>[0]) => {
  const inner = query(args);
  return (async function* () {
    for await (const m of inner) {
      if (m.type === "user" && Array.isArray(m.message.content)) {
        for (const b of m.message.content as { type: string; content?: unknown }[]) {
          if (b.type === "tool_result") console.log("RESULT " + JSON.stringify(b.content).slice(0, 500));
        }
      }
      yield m;
    }
  })();
}) as typeof query;

// Registra cada llamada a canUseTool (se espera para SandboxNetworkAccess y para el Bash sin sandbox aprobado; nunca para Bash dentro de la sandbox).
const wrappedQuery = ((args: Parameters<typeof query>[0]) => {
  const cu = args.options?.canUseTool;
  if (cu && args.options) {
    args.options.canUseTool = async (tool, input, o) => {
      const r = await cu(tool, input, o);
      console.log("CANUSETOOL " + JSON.stringify({ tool, input, r }).slice(0, 400));
      return r;
    };
  }
  return loggingQuery(args);
}) as typeof query;

const done = await new RealRunner(call, wrappedQuery).run(
  params,
  (e) => console.log("EVENT " + JSON.stringify(e)),
  new AbortController().signal,
);
console.log("DONE " + JSON.stringify(done));

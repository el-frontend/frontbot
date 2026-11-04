// app-server falso para tests: habla JSON-RPC por líneas (stdio) y se porta según el texto del primer turno.
import { appendFileSync } from "node:fs";

let nextId = 1000;
const pending = new Map();
const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const notify = (method, params) => send({ method, params });
const ask = (method, params) => new Promise((resolve) => { const id = nextId++; pending.set(id, resolve); send({ id, method, params }); });
const log = (entry) => { if (process.env.FAKE_CODEX_LOG) appendFileSync(process.env.FAKE_CODEX_LOG, JSON.stringify(entry) + "\n"); };

const thread = { id: "th-1" };
const turn = { id: "tu-1" };
const delta = (text) => notify("item/agentMessage/delta", { threadId: thread.id, turnId: turn.id, itemId: "m1", delta: text });
const message = (text) => notify("item/completed", { threadId: thread.id, turnId: turn.id, item: { type: "agentMessage", id: "m1", text } });
const usage = (input, cached, output) => notify("thread/tokenUsage/updated", { threadId: thread.id, turnId: turn.id, tokenUsage: { total: { inputTokens: input, cachedInputTokens: cached, outputTokens: output, totalTokens: input + output } } });
const complete = (status = "completed") => notify("turn/completed", { threadId: thread.id, turn: { id: turn.id, status, items: [] } });
const say = (text) => { delta(text); message(text); };
const toolCall = (tool, args, callId = "c1") => {
  notify("item/started", { threadId: thread.id, turnId: turn.id, item: { type: "dynamicToolCall", id: callId, tool, arguments: args, status: "inProgress" } });
  return ask("item/tool/call", { threadId: thread.id, turnId: turn.id, callId, namespace: null, tool, arguments: args });
};
const textOf = (res) => (res?.contentItems ?? []).map((c) => c.text ?? "").join("");

async function play(text) {
  if (text === "hola") { delta("Ho"); delta("la"); message("Hola"); usage(10, 4, 3); return complete(); }
  if (text === "usa brands_list") { const r = await toolCall("brands_list", {}); say(`ok:${r.success}:${textOf(r)}`); usage(5, 0, 2); return complete(); }
  if (text === "usa desconocida") { const r = await toolCall("rm_rf", { path: "/" }); say(`ok:${r.success}:${textOf(r)}`); return complete(); }
  if (text === "lee skill") { const r = await toolCall("skills_read", { path: process.env.FAKE_SKILL_PATH ?? "" }); const r2 = await toolCall("skills_read", { path: "/etc/hosts" }, "c2"); say(`a:${r.success}:${textOf(r)}|b:${r2.success}:${textOf(r2)}`); return complete(); }
  if (text === "chrome") { const r = await toolCall("tabs_context_mcp", {}); say(`ok:${r.success}:${textOf(r)}`); return complete(); }
  if (text.startsWith("shell")) {
    const command = text === "shell" ? "cat ~/.ssh/id_rsa" : text.slice(6);
    notify("item/started", { threadId: thread.id, turnId: turn.id, item: { type: "commandExecution", id: "e1", command } });
    const r = await ask("item/commandExecution/requestApproval", { threadId: thread.id, turnId: turn.id, itemId: "e1", command, cwd: "/" });
    say(`decision:${r?.decision ?? "error"}`); return complete();
  }
  if (text === "escribe fuera") {
    const r = await ask("item/fileChange/requestApproval", { threadId: thread.id, turnId: turn.id, itemId: "f1", changes: [{ path: process.env.FAKE_OUTSIDE_PATH ?? "/Users/u/fuera.txt", kind: "add" }] });
    say(`decision:${r?.decision ?? "error"}`); return complete();
  }
  if (text === "permisos") { const r = await ask("item/permissions/requestApproval", { threadId: thread.id, turnId: turn.id }); say(`respuesta:${JSON.stringify(r)}`); return complete(); }
  if (text === "cuelga") return;
  if (text === "muere") process.exit(3);
  if (text === "falla") { notify("error", { threadId: thread.id, turnId: turn.id, error: { message: "Your session expired. Sign in again." } }); return complete("failed"); }
  if (text === "muchas") { for (let i = 0; i < 50; i++) await toolCall("brands_list", {}, `c${i}`); say("fin"); return complete(); }
  if (text === "estudio") {
    for (let i = 1; i <= 10; i++) { usage(20 * i, 0, 5 * i); await new Promise((r) => setTimeout(r, 20)); }
    say("estudio terminado"); return complete();
  }
  say(`eco:${text}`); return complete();
}

const handlers = {
  initialize: () => ({ userAgent: "fake-codex/0.158.0", codexHome: process.env.CODEX_HOME ?? null }),
  "account/read": () => (process.env.FAKE_CODEX_NO_ACCOUNT === "1"
    ? { account: null, requiresOpenaiAuth: true }
    : { account: { type: "chatgpt", email: "fake@frontbot.test", planType: "pro" }, requiresOpenaiAuth: true }),
  "account/login/start": () => { setTimeout(() => notify("account/login/completed", { loginId: "l1", success: true }), 50); return { type: "chatgpt", loginId: "l1", authUrl: "https://auth.openai.com/fake" }; },
  "account/logout": () => ({}),
  "model/list": () => ({ data: [{ id: "gpt-6-astra" }, { id: "gpt-6-sol" }], nextCursor: null }),
  "thread/start": (params) => { log({ method: "thread/start", params, env: { CODEX_HOME: process.env.CODEX_HOME }, argv: process.argv.slice(2) }); notify("thread/started", { thread }); return { thread }; },
  "turn/start": (params) => { log({ method: "turn/start", params }); const text = params.input?.[0]?.text ?? ""; setTimeout(() => void play(text), 5); return { turn }; },
  "turn/interrupt": () => { log({ method: "turn/interrupt" }); setTimeout(() => complete("interrupted"), 5); return {}; },
  "turn/steer": (params) => { log({ method: "turn/steer", params }); return { turnId: turn.id }; },
};

let buf = "";
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.method && msg.id !== undefined) {
      const h = handlers[msg.method];
      if (!h) { send({ id: msg.id, error: { code: -32601, message: `no soportado: ${msg.method}` } }); continue; }
      send({ id: msg.id, result: h(msg.params ?? {}) });
    } else if (msg.method) {
      // notificaciones del cliente (initialized): nada
    } else if (pending.has(msg.id)) {
      const r = pending.get(msg.id); pending.delete(msg.id);
      r(msg.error ? { error: msg.error } : msg.result);
    }
  }
});
process.stdin.on("end", () => process.exit(0));

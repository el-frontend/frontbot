// La sesión de Codex propia de Frontbot: dónde está el binario, si la versión sirve, la cuenta
// conectada y el login con ChatGPT. Todo corre con el CODEX_HOME de Frontbot, nunca `~/.codex`.
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { AppServer, type Spawn } from "./appServer.js";
import { codexArgs } from "./launch.js";

export const CODEX_CANDIDATES = [
  "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
  "/Applications/Codex.app/Contents/Resources/codex",
  "/opt/homebrew/bin/codex",
  "/usr/local/bin/codex",
];
export const MIN_CODEX_VERSION = "0.158.0";

export type CodexStatus = { installed: boolean; compatible: boolean; version: string | null; account: { email: string | null; plan: string | null } | null; models: string[] };

export interface CodexAccountLike {
  status(): Promise<CodexStatus>;
  login(): Promise<{ auth_url: string }>;
  waitLogin(timeoutMs?: number): Promise<{ ok: boolean }>;
  logout(): Promise<void>;
}

export function locateCodex(env: NodeJS.ProcessEnv, exists: (p: string) => boolean = existsSync): string | null {
  if (env.FRONTBOT_CODEX_BIN && exists(env.FRONTBOT_CODEX_BIN)) return env.FRONTBOT_CODEX_BIN;
  for (const c of CODEX_CANDIDATES) if (exists(c)) return c;
  for (const dir of (env.PATH ?? "").split(":").filter(Boolean)) {
    const p = join(dir, "codex");
    if (exists(p)) return p;
  }
  return null;
}

const parseVersion = (output: string) => /(\d+)\.(\d+)\.(\d+)/.exec(output);

export function codexVersionOk(output: string): boolean {
  const m = parseVersion(output);
  if (!m) return false;
  const have = m.slice(1, 4).map(Number);
  const need = MIN_CODEX_VERSION.split(".").map(Number);
  for (let i = 0; i < 3; i++) if (have[i] !== need[i]) return have[i] > need[i];
  return true;
}

export const codexVersionString = (output: string) => parseVersion(output)?.[0] ?? null;

/** Entorno mínimo del proceso de Codex: nada de keys de la shell. */
export function codexEnv(home: string, base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { CODEX_HOME: home };
  for (const k of ["PATH", "HOME", "TMPDIR", "USER"]) if (base[k]) env[k] = base[k];
  return env;
}

export function ensureCodexHome(home: string) {
  mkdirSync(home, { recursive: true, mode: 0o700 });
  chmodSync(home, 0o700);
}

/** `codex --version` del binario (cadena vacía si no hay o falla). */
export const codexVersion = (bin: string | null) => async (): Promise<string> => (bin ? runVersion(bin)() : "");

const runVersion = (bin: string) => () => new Promise<string>((resolve) => {
  execFile(bin, ["--version"], { timeout: 10_000 }, (err, stdout) => resolve(err ? "" : String(stdout)));
});

/** Solo cuenta y login: sin shell, sin web, sin nada que pueda usar el modelo. */
const ACCOUNT_ARGS = codexArgs({ web: false, shell: false, browser: false, skills: false });

export class CodexAccount implements CodexAccountLike {
  private loginServer?: AppServer;
  private loginDone?: Promise<boolean>;
  private readonly version: () => Promise<string>;
  private readonly start: (s: Spawn) => AppServer;

  constructor(private opts: { bin: string | null; home: string; version?: () => Promise<string>; start?: (s: Spawn) => AppServer }) {
    this.version = opts.version ?? (opts.bin ? runVersion(opts.bin) : async () => "");
    this.start = opts.start ?? AppServer.start;
  }

  private async open(): Promise<AppServer> {
    ensureCodexHome(this.opts.home);
    const server = this.start({ command: this.opts.bin!, args: ACCOUNT_ARGS, env: codexEnv(this.opts.home), cwd: this.opts.home });
    await server.initialize();
    return server;
  }

  async status(): Promise<CodexStatus> {
    if (!this.opts.bin) return { installed: false, compatible: false, version: null, account: null, models: [] };
    const out = await this.version();
    const version = codexVersionString(out);
    if (!codexVersionOk(out)) return { installed: true, compatible: false, version, account: null, models: [] };
    const server = await this.open();
    try {
      const read = await server.request<{ account: { email?: string; planType?: string } | null }>("account/read", { refreshToken: false });
      if (!read?.account) return { installed: true, compatible: true, version, account: null, models: [] };
      const list = await server.request<{ data?: { id?: string }[] }>("model/list", {});
      const models = (list?.data ?? []).map((m) => m.id).filter((id): id is string => typeof id === "string");
      return { installed: true, compatible: true, version, account: { email: read.account.email ?? null, plan: read.account.planType ?? null }, models };
    } finally {
      server.kill();
    }
  }

  async login(): Promise<{ auth_url: string }> {
    if (!this.opts.bin) throw new Error("Codex no está instalado.");
    if (!codexVersionOk(await this.version())) throw new Error("Actualiza Codex para usarlo en Frontbot.");
    this.close();
    const server = await this.open();
    this.loginServer = server;
    this.loginDone = new Promise<boolean>((resolve) => {
      server.onNotification((method, params) => { if (method === "account/login/completed") resolve(params?.success !== false); });
      void server.exited.then(() => resolve(false));
    });
    const res = await server.request<{ authUrl?: string }>("account/login/start", { type: "chatgpt" });
    if (!res?.authUrl) { this.close(); throw new Error("Codex no devolvió la página de inicio de sesión."); }
    return { auth_url: res.authUrl };
  }

  async waitLogin(timeoutMs = 600_000): Promise<{ ok: boolean }> {
    if (!this.loginDone) return { ok: false };
    let timer: NodeJS.Timeout | undefined;
    const ok = await Promise.race([this.loginDone, new Promise<boolean>((r) => { timer = setTimeout(() => r(false), timeoutMs); })]);
    clearTimeout(timer);
    this.close();
    return { ok };
  }

  async logout(): Promise<void> {
    if (!this.opts.bin) return;
    const server = await this.open();
    try { await server.request("account/logout", {}); } finally { server.kill(); }
  }

  /** Mata un login pendiente. */
  close() {
    this.loginServer?.kill();
    this.loginServer = undefined;
    this.loginDone = undefined;
  }
}

/** Para FRONTBOT_FAKE_AGENT: sin procesos, con la sesión simulada. */
export class FakeCodexAccount implements CodexAccountLike {
  constructor(private connected: boolean) {}
  async status(): Promise<CodexStatus> {
    return { installed: true, compatible: true, version: "0.158.0",
      account: this.connected ? { email: "fake@frontbot.test", plan: "pro" } : null,
      models: this.connected ? ["gpt-6-astra", "gpt-6-sol"] : [] };
  }
  async login() { return { auth_url: "https://auth.openai.com/fake" }; }
  async waitLogin() { this.connected = true; return { ok: true }; }
  async logout() { this.connected = false; }
}

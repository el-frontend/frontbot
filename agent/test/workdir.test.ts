import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { workdirDecision, alwaysDenied, sandboxSettings, validateWorkdir, WORKDIR_TOOLS, type RunWorkdir } from "../src/workdir.js";

let home: string;
let work: string;
let wd: RunWorkdir;

beforeAll(() => {
  home = realpathSync(mkdtempSync(join(tmpdir(), "frontbot-wd-")));
  work = join(home, "work");
  mkdirSync(work);
  mkdirSync(join(home, "Downloads"));
  mkdirSync(join(home, "Documents"));
  mkdirSync(join(home, ".ssh"));
  mkdirSync(join(home, "Library"));
  writeFileSync(join(home, "Documents", "secret.txt"), "s");
  writeFileSync(join(home, ".ssh", "id"), "k");
  writeFileSync(join(work, "a.txt"), "a");
  symlinkSync(join(home, "Documents"), join(work, "docs"), "dir");
  wd = { path: work, read_dirs: [join(home, "Downloads")] };
});
afterAll(() => rmSync(home, { recursive: true, force: true }));

const d = (tool: string, input: Record<string, unknown>, w = wd) => workdirDecision(tool, input, w, home);

describe("workdirDecision", () => {
  it("lee dentro de la carpeta y de las carpetas de lectura", () => {
    expect(d("Read", { file_path: join(work, "a.txt") })).toEqual({ kind: "allow" });
    expect(d("Read", { file_path: join(home, "Downloads", "x.mp4") })).toEqual({ kind: "allow" });
  });
  it("deniega leer fuera", () => {
    const r = d("Read", { file_path: join(home, "Documents", "secret.txt") });
    expect(r.kind).toBe("deny");
    expect(r.kind === "deny" && r.reason).toContain("carpeta de lectura");
  });
  it("deniega leer a través de un enlace que sale de la carpeta", () => {
    expect(d("Read", { file_path: join(work, "docs", "secret.txt") }).kind).toBe("deny");
  });
  it("lo siempre denegado gana a read_dirs", () => {
    const wide = { path: work, read_dirs: [home] };
    expect(d("Read", { file_path: join(home, ".ssh", "id") }, wide).kind).toBe("deny");
  });
  it("Glob y Grep", () => {
    expect(d("Glob", { pattern: "**/*.html" })).toEqual({ kind: "allow" });
    expect(d("Glob", { pattern: join(home, "Documents", "**") }).kind).toBe("deny");
    expect(d("Glob", { pattern: join(work, "**", "*.md") })).toEqual({ kind: "allow" });
    expect(d("Grep", { pattern: "x", path: join(home, "Documents") }).kind).toBe("deny");
    expect(d("Grep", { pattern: "x" })).toEqual({ kind: "allow" });
  });
  it("escribe sin preguntar dentro, aunque falten subcarpetas", () => {
    expect(d("Write", { file_path: join(work, "out", "a", "b.html"), content: "x" })).toEqual({ kind: "allow" });
  });
  it("pregunta al escribir fuera", () => {
    const p = join(home, "Downloads", "a.txt");
    expect(d("Write", { file_path: p, content: "hola" })).toEqual({ kind: "ask", ask: { kind: "write", tool: "Write", path: p, content: "hola" } });
    const e = join(home, "Documents", "secret.txt");
    expect(d("Edit", { file_path: e, old_string: "a", new_string: "b" })).toEqual({ kind: "ask", ask: { kind: "write", tool: "Edit", path: e, old_string: "a", new_string: "b" } });
  });
  it("nunca pregunta por rutas siempre denegadas", () => {
    expect(d("Write", { file_path: join(home, ".ssh", "x"), content: "" }).kind).toBe("deny");
  });
  it("Bash: permitido en sandbox, pregunta sin ella", () => {
    expect(d("Bash", { command: "npm i" })).toEqual({ kind: "allow" });
    expect(d("Bash", { command: "npx hyperframes render", dangerouslyDisableSandbox: true }))
      .toEqual({ kind: "ask", ask: { kind: "unsandboxed", command: "npx hyperframes render" } });
  });
  it("resuelve rutas relativas contra la carpeta", () => {
    expect(d("Read", { file_path: "relativo.txt" })).toEqual({ kind: "allow" });
  });
  it("no opina de otras herramientas", () => {
    expect(d("mcp__frontbot__posts_list", {})).toEqual({ kind: "allow" });
  });
});

describe("validateWorkdir", () => {
  it("rechaza home, raíz, ancestros de rutas denegadas e inexistentes", () => {
    expect(validateWorkdir({ path: home, read_dirs: [] }, home)).not.toBeNull();
    expect(validateWorkdir({ path: "/", read_dirs: [] }, home)).not.toBeNull();
    expect(validateWorkdir({ path: join(home, "Library"), read_dirs: [] }, home)).not.toBeNull();
    expect(validateWorkdir({ path: join(home, "nada"), read_dirs: [] }, home)).not.toBeNull();
  });
  it("acepta una carpeta normal", () => {
    expect(validateWorkdir(wd, home)).toBeNull();
  });
});

describe("sandboxSettings", () => {
  it("construye permisos y banderas", () => {
    const s = sandboxSettings(wd, home, ["/opt/x"]);
    expect(s.filesystem?.allowWrite).toContain(wd.path);
    expect(s.filesystem?.denyRead).toContain(home);
    expect(s.filesystem?.denyRead).toEqual(expect.arrayContaining(alwaysDenied(home)));
    expect(s.filesystem?.allowRead).toEqual(expect.arrayContaining([wd.path, ...wd.read_dirs, "/opt/x"]));
    expect(s.filesystem?.allowRead).not.toContain(home);
    expect(s.network?.allowedDomains).toBeUndefined();
    expect(s).toMatchObject({ enabled: true, failIfUnavailable: true, autoAllowBashIfSandboxed: true, allowUnsandboxedCommands: true });
  });
  it("expone las herramientas", () => {
    expect(WORKDIR_TOOLS).toEqual(["Read", "Write", "Edit", "Glob", "Grep", "Bash", "TodoWrite"]);
  });
});

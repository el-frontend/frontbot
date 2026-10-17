import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, writeFileSync, readFileSync, statSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { convert } from "./convert.mjs";

const GLB = process.env.FRONTBOT_GLB ?? join(homedir(), "Downloads", "frontbot-meshy.glb");
const skip = !existsSync(GLB) && "no está el GLB de Meshy";

test("converts the Meshy GLB into a small, valid USDZ", { skip }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "mascot-"));
  const output = join(dir, "frontbot.usdz");
  const r = await convert({ input: GLB, output, workDir: join(dir, "work") });
  assert.ok(r.verts > 20000 && r.verts <= 40000, `vértices: ${r.verts}`);
  assert.ok(statSync(output).size < 3_000_000, "menos de 3 MB");
  assert.match(execFileSync("usdcat", ["-l", output]).toString(), /^OK/);
});

test("never overwrites the good USDZ when a limit is exceeded", { skip }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "mascot-"));
  const output = join(dir, "frontbot.usdz");
  writeFileSync(output, "bueno");
  await assert.rejects(convert({ input: GLB, output, workDir: join(dir, "work"), maxVerts: 1000 }), /vértices/);
  assert.equal(readFileSync(output, "utf8"), "bueno");
});

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { packUsdz } from "./usdz.mjs";

// Recorre las cabeceras locales del zip: [{ name, start, data }].
function entries(buf) {
  const out = [];
  let o = 0;
  while (buf.readUInt32LE(o) === 0x04034b50) {
    const method = buf.readUInt16LE(o + 8), size = buf.readUInt32LE(o + 18);
    const nameLen = buf.readUInt16LE(o + 26), extraLen = buf.readUInt16LE(o + 28);
    const name = buf.subarray(o + 30, o + 30 + nameLen).toString();
    const start = o + 30 + nameLen + extraLen;
    out.push({ name, method, start, data: buf.subarray(start, start + size) });
    o = start + size;
  }
  return out;
}

test("stores files uncompressed, root layer first, data aligned to 64 bytes", () => {
  const dir = mkdtempSync(join(tmpdir(), "usdz-"));
  const a = join(dir, "frontbot.usdc"), b = join(dir, "base.jpg"), c = join(dir, "n.png");
  writeFileSync(a, Buffer.alloc(101, 1)); writeFileSync(b, Buffer.alloc(77, 2)); writeFileSync(c, Buffer.alloc(3, 3));
  const out = join(dir, "x.usdz");
  packUsdz(out, [a, b, c]);
  const list = entries(readFileSync(out));
  assert.deepEqual(list.map((e) => e.name), ["frontbot.usdc", "base.jpg", "n.png"]);
  for (const e of list) {
    assert.equal(e.method, 0, "sin compresión");
    assert.equal(e.start % 64, 0, `${e.name} alineado a 64`);
  }
  assert.deepEqual(list[1].data, Buffer.alloc(77, 2));
});

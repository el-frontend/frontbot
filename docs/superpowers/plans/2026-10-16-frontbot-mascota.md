# Mascota de Frontbot — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Frontbot tiene logo e icono propios a partir del dibujo 2D, y una mascota 3D animada por estados en el notch y en el chat.

**Architecture:** Un script de Node convierte el GLB de Meshy en un USDZ (malla simplificada, texturas JPEG/PNG, empaquetado propio). En FrontbotCore, tres piezas puras (`MascotMood`, `MascotMotion`, `MascotPose`) deciden el estado y la pose, y `MascotScene` (RealityKit) monta el modelo con luces y cámara. En la app, `MascotView` envuelve `RealityView` + `TimelineView`, y `AppModel` alimenta `MascotMood` con los eventos del agente.

**Tech Stack:** Swift 6 / SwiftUI / RealityKit (macOS 15), XCTest, Node 24 con `@gltf-transform` 4.5.1, `meshoptimizer` 1.3.0 y `sharp` 0.35.5, Vision, `usdcat`, `iconutil`.

**Spec:** `docs/superpowers/specs/2026-10-16-frontbot-mascota-design.md`

## Global Constraints

- Mínimo de la app: **macOS 15** (`platforms: [.macOS(.v15)]`).
- `frontbot.usdz`: **menos de 3 MB y menos de 40.000 vértices**; se versiona en `app/Sources/FrontbotApp/Resources/Mascot/`. El GLB y `scripts/mascot/out/` no se versionan.
- El script de conversión **nunca sobrescribe** el USDZ bueno si falla un paso o se superan los límites.
- Como mucho **dos `MascotView` animadas a la vez**; quietas cuando no se ven o están en reposo.
- **"Reducir movimiento"**: la pose es fija; solo cambia el brillo.
- La mascota y el logo solo sustituyen a Frontbot (`agent.isDefault`); los demás agentes no cambian.
- Textos de la UI en español; comentarios en español, breves, como el resto del código.
- Tests de Swift: `cd app && FRONTBOT_NODE=$(source ~/.nvm/nvm.sh >/dev/null 2>&1; which node) swift test`. Node vía nvm: `source ~/.nvm/nvm.sh`.
- Commits con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **App empaquetada (`build/Frontbot.app`) sin acceso a `app/Sources`**: la mascota y el logo deben salir de `Contents/Resources/Mascot`; si faltan, se ve el símbolo de siempre y nada se rompe. → test de `MascotResources` en la Task 5 (localización por orden) y comprobación en la Task 9.
2. **El agente falla o se cancela a mitad**: la mascota pasa a `sad` y vuelve a `idle`; nunca se queda "pensando". → tests de `MascotMood` (Task 2): `runFinished(ok: false)` y error al lanzar el run.
3. **Cambio de estado a mitad de una animación** (p. ej. llega texto en pleno salto): sin saltos visibles. → test de `blend` y de continuidad (Task 3).
4. **Volver a convertir con un GLB peor** (más vértices o texturas enormes): el USDZ anterior sigue intacto. → test del script con límites forzados (Task 1).
5. **Mascota tapada o recortada por la cámara** en algún estado (salto de `happy`, encogido de `sad`): siempre entera dentro del encuadre. → test de instantáneas con bordes transparentes (Task 4).

---

### Task 1: Conversión del GLB a USDZ

**Files:**
- Create: `scripts/mascot/package.json`
- Create: `scripts/mascot/usdz.mjs`
- Create: `scripts/mascot/usdz.test.mjs`
- Create: `scripts/mascot/convert.mjs`
- Create: `scripts/mascot/convert.test.mjs`
- Create: `scripts/mascot/preview.swift`
- Create (generado): `app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz`
- Modify: `.gitignore`
- Modify: `docs/superpowers/specs/2026-10-16-frontbot-mascota-design.md` (pasos 5 y brillo, ver Step 9)

**Interfaces:**
- Produces: `packUsdz(outPath: string, files: string[])` (el primer archivo es la capa raíz `.usdc`); `convert({ input, output, workDir, maxVerts = 40000, maxBytes = 3_000_000 }) → { verts, tris, bytes }`, que lanza `Error` y no toca `output` si algo falla. El modelo queda centrado en el origen, con su lado mayor = 1, mirando a +Z, con `upAxis = "Y"` y `defaultPrim = "Frontbot"`.

- [ ] **Step 1: Paquete y dependencias**

`scripts/mascot/package.json`:

```json
{
  "name": "frontbot-mascot",
  "private": true,
  "type": "module",
  "scripts": {
    "convert": "node convert.mjs",
    "test": "node --test"
  },
  "dependencies": {
    "@gltf-transform/core": "4.5.1",
    "@gltf-transform/extensions": "4.5.1",
    "@gltf-transform/functions": "4.5.1",
    "meshoptimizer": "1.3.0",
    "sharp": "0.35.5"
  }
}
```

Añadir a `.gitignore`:

```
scripts/mascot/node_modules/
scripts/mascot/out/
```

Run: `cd scripts/mascot && source ~/.nvm/nvm.sh && npm install`
Expected: instala sin errores (unos 25 s).

- [ ] **Step 2: Test del empaquetador USDZ (falla)**

`scripts/mascot/usdz.test.mjs`:

```js
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
```

Run: `cd scripts/mascot && node --test usdz.test.mjs`
Expected: FAIL (`Cannot find module './usdz.mjs'`).

- [ ] **Step 3: Empaquetador**

`scripts/mascot/usdz.mjs`:

```js
// USDZ = zip sin compresión, con los datos de cada archivo alineados a 64 bytes y la capa raíz primero.
// usdcat no sabe escribir .usdz, así que lo empaquetamos aquí.
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { crc32 } from "node:zlib";

export function packUsdz(out, files) {
  const chunks = [], central = [];
  let offset = 0;
  for (const path of files) {
    const data = readFileSync(path), name = Buffer.from(basename(path)), crc = crc32(data);
    // El relleno va en un campo extra (id 0x1986) para que los datos empiecen en múltiplo de 64.
    const pad = (64 - ((offset + 30 + name.length + 4) % 64)) % 64;
    const extra = Buffer.alloc(4 + pad);
    extra.writeUInt16LE(0x1986, 0); extra.writeUInt16LE(pad, 2);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(data.length, 18); local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26); local.writeUInt16LE(extra.length, 28);
    const entry = Buffer.alloc(46);
    entry.writeUInt32LE(0x02014b50, 0); entry.writeUInt16LE(20, 4); entry.writeUInt16LE(20, 6);
    entry.writeUInt32LE(crc, 16); entry.writeUInt32LE(data.length, 20); entry.writeUInt32LE(data.length, 24);
    entry.writeUInt16LE(name.length, 28); entry.writeUInt32LE(offset, 42);
    chunks.push(local, name, extra, data);
    central.push(entry, name);
    offset += 30 + name.length + extra.length + data.length;
  }
  const dir = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(dir.length, 12); end.writeUInt32LE(offset, 16);
  writeFileSync(out, Buffer.concat([...chunks, dir, end]));
}
```

Run: `node --test usdz.test.mjs`
Expected: PASS.

- [ ] **Step 4: Test del conversor (falla)**

`scripts/mascot/convert.test.mjs`. Usa el GLB real si existe; si no, se salta:

```js
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
```

Run: `node --test convert.test.mjs`
Expected: FAIL (`Cannot find module './convert.mjs'`).

- [ ] **Step 5: Conversor**

`scripts/mascot/convert.mjs` (verificado con el GLB real: 162.035 → 36.829 vértices, 2,4 MB, se ve bien de frente y de perfil):

```js
// GLB de Meshy → USDZ para RealityKit. Uso: node convert.mjs <glb> [salida.usdz]
// Pasos: quitar cuantización, aplicar el nodo y KHR_texture_transform, simplificar, centrar/escalar,
// texturas a 1024 px (JPEG color y metal/rugosidad; PNG relieve), USDA → usdc (usdcat) → usdz.
import { NodeIO } from "@gltf-transform/core";
import { ALL_EXTENSIONS } from "@gltf-transform/extensions";
import { dequantize, weld, simplify } from "@gltf-transform/functions";
import { MeshoptSimplifier } from "meshoptimizer";
import sharp from "sharp";
import { writeFileSync, mkdirSync, rmSync, renameSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { packUsdz } from "./usdz.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_OUTPUT = resolve(HERE, "../../app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz");

export async function convert({ input, output = DEFAULT_OUTPUT, workDir = join(HERE, "out"), maxVerts = 40000, maxBytes = 3_000_000 }) {
  const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
  const doc = await io.read(input);
  await MeshoptSimplifier.ready;
  const node = doc.getRoot().listNodes().find((n) => n.getMesh());
  if (!node) throw new Error("El GLB no tiene ninguna malla.");
  const before = node.getMesh().listPrimitives()[0].getAttribute("POSITION").getCount();
  await doc.transform(dequantize(), weld(), simplify({ simplifier: MeshoptSimplifier, ratio: 30000 / before, error: 0.002 }));
  const prim = node.getMesh().listPrimitives()[0];
  const mat = prim.getMaterial();

  // Meshy guarda la escala real en el nodo y comprime las UV con KHR_texture_transform: se aplican a los datos.
  const world = node.getWorldMatrix();
  const tt = mat.getBaseColorTextureInfo()?.getExtension("KHR_texture_transform");
  const [ou, ov] = tt ? tt.getOffset() : [0, 0], [su, sv] = tt ? tt.getScale() : [1, 1];
  const P = prim.getAttribute("POSITION"), N = prim.getAttribute("NORMAL"), T = prim.getAttribute("TEXCOORD_0");
  const idx = Array.from(prim.getIndices().getArray());
  const n = P.getCount();
  if (n > maxVerts) throw new Error(`Demasiados vértices tras simplificar: ${n} (máx. ${maxVerts}).`);
  const mul = (m, x, y, z, w) => [m[0]*x + m[4]*y + m[8]*z + m[12]*w, m[1]*x + m[5]*y + m[9]*z + m[13]*w, m[2]*x + m[6]*y + m[10]*z + m[14]*w];
  const pts = [], nrm = [], uvs = [], v = [];
  for (let i = 0; i < n; i++) {
    P.getElement(i, v); pts.push(mul(world, v[0], v[1], v[2], 1));
    N.getElement(i, v); const q = mul(world, v[0], v[1], v[2], 0), l = Math.hypot(...q) || 1; nrm.push(q.map((c) => c / l));
    T.getElement(i, v); uvs.push([ou + su * v[0], 1 - (ov + sv * v[1])]); // glTF: origen arriba; USD: abajo
  }
  const min = [0, 1, 2].map((k) => Math.min(...pts.map((p) => p[k])));
  const max = [0, 1, 2].map((k) => Math.max(...pts.map((p) => p[k])));
  const center = min.map((m, k) => (m + max[k]) / 2), size = Math.max(...max.map((m, k) => m - min[k]));
  const points = pts.map((p) => p.map((c, k) => (c - center[k]) / size));

  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(workDir, { recursive: true });
  const texture = async (t, name) => {
    if (!t) return null;
    const img = sharp(Buffer.from(t.getImage())).resize(1024, 1024, { fit: "inside" });
    await (name.endsWith(".jpg") ? img.jpeg({ quality: 88 }) : img.png()).toFile(join(workDir, name));
    return name;
  };
  const base = await texture(mat.getBaseColorTexture(), "base.jpg");
  const mr = await texture(mat.getMetallicRoughnessTexture(), "mr.jpg");
  const normal = await texture(mat.getNormalTexture(), "normal.png");

  writeFileSync(join(workDir, "frontbot.usda"), usda({ idx, points, nrm, uvs, doubleSided: mat.getDoubleSided(), base, mr, normal }));
  execFileSync("usdcat", ["-o", join(workDir, "frontbot.usdc"), join(workDir, "frontbot.usda")]);
  const tmp = join(workDir, "frontbot.usdz");
  packUsdz(tmp, [join(workDir, "frontbot.usdc"), ...[base, mr, normal].filter(Boolean).map((f) => join(workDir, f))]);
  execFileSync("usdcat", ["-l", tmp]); // lanza si el paquete no abre
  const bytes = statSync(tmp).size;
  if (bytes > maxBytes) throw new Error(`El USDZ pesa ${bytes} bytes (máx. ${maxBytes}).`);
  mkdirSync(dirname(output), { recursive: true });
  renameSync(tmp, output); // solo ahora se reemplaza el bueno
  return { verts: n, tris: idx.length / 3, bytes };
}

function usda({ idx, points, nrm, uvs, doubleSided, base, mr, normal }) {
  const list = (a) => a.map((x) => `(${x.map((c) => +c.toFixed(6)).join(", ")})`).join(", ");
  const tex = (name, file, outputs, extra) => `
  def Shader "${name}"
  {
   uniform token info:id = "UsdUVTexture"
   asset inputs:file = @${file}@
   float2 inputs:st.connect = </Frontbot/Mat/St.outputs:result>
   token inputs:wrapS = "repeat"
   token inputs:wrapT = "repeat"
${extra}${outputs}
  }`;
  return `#usda 1.0
(
 defaultPrim = "Frontbot"
 metersPerUnit = 1
 upAxis = "Y"
)
def Xform "Frontbot"
{
 def Mesh "Body" (prepend apiSchemas = ["MaterialBindingAPI"])
 {
  uniform bool doubleSided = ${doubleSided ? 1 : 0}
  uniform token subdivisionScheme = "none"
  int[] faceVertexCounts = [${Array(idx.length / 3).fill(3).join(", ")}]
  int[] faceVertexIndices = [${idx.join(", ")}]
  point3f[] points = [${list(points)}]
  normal3f[] normals = [${list(nrm)}] (interpolation = "vertex")
  texCoord2f[] primvars:st = [${list(uvs)}] (interpolation = "vertex")
  rel material:binding = </Frontbot/Mat>
 }
 def Material "Mat"
 {
  token outputs:surface.connect = </Frontbot/Mat/PBR.outputs:surface>
  def Shader "PBR"
  {
   uniform token info:id = "UsdPreviewSurface"
${base ? "   color3f inputs:diffuseColor.connect = </Frontbot/Mat/Base.outputs:rgb>\n" : ""}${mr ? "   float inputs:roughness.connect = </Frontbot/Mat/MR.outputs:g>\n   float inputs:metallic.connect = </Frontbot/Mat/MR.outputs:b>\n" : ""}${normal ? "   normal3f inputs:normal.connect = </Frontbot/Mat/Normal.outputs:rgb>\n" : ""}   token outputs:surface
  }
  def Shader "St"
  {
   uniform token info:id = "UsdPrimvarReader_float2"
   string inputs:varname = "st"
   float2 outputs:result
  }${base ? tex("Base", base, "   float3 outputs:rgb", '   token inputs:sourceColorSpace = "sRGB"\n') : ""}${mr ? tex("MR", mr, "   float outputs:g\n   float outputs:b", '   token inputs:sourceColorSpace = "raw"\n') : ""}${normal ? tex("Normal", normal, "   float3 outputs:rgb", '   token inputs:sourceColorSpace = "raw"\n   float4 inputs:scale = (2, 2, 2, 1)\n   float4 inputs:bias = (-1, -1, -1, 0)\n') : ""}
 }
}
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [input, output] = process.argv.slice(2);
  if (!input) { console.error("Uso: node convert.mjs <modelo.glb> [salida.usdz]"); process.exit(2); }
  try {
    const r = await convert({ input, output: output ?? DEFAULT_OUTPUT });
    console.log(`✓ ${output ?? DEFAULT_OUTPUT}: ${r.verts} vértices, ${r.tris} triángulos, ${(r.bytes / 1e6).toFixed(2)} MB`);
  } catch (err) {
    console.error(`✗ ${err.message}\n  El USDZ anterior no se tocó.`);
    process.exit(1);
  }
}
```

Run: `node --test`
Expected: PASS (3 tests; los dos del conversor tardan unos 2 s).

- [ ] **Step 6: Vista previa para revisar a ojo**

`scripts/mascot/preview.swift` (SceneKit; solo herramienta de revisión, no va en la app):

```swift
// Uso: swift preview.swift <modelo.usdz> <salida.png> [grados de giro]
import SceneKit
import AppKit

let args = CommandLine.arguments
let scene = try SCNScene(url: URL(fileURLWithPath: args[1]))
let pivot = SCNNode()
scene.rootNode.childNodes.forEach { pivot.addChildNode($0) }
scene.rootNode.addChildNode(pivot)
pivot.eulerAngles.y = CGFloat((args.count > 3 ? Double(args[3])! : 0) * .pi / 180)
let camera = SCNNode()
camera.camera = SCNCamera(); camera.camera!.fieldOfView = 30; camera.position = SCNVector3(0, 0, 2.2)
scene.rootNode.addChildNode(camera)
let key = SCNNode()
key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900; key.eulerAngles = SCNVector3(-0.6, 0.4, 0)
scene.rootNode.addChildNode(key)
let ambient = SCNNode()
ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 500
scene.rootNode.addChildNode(ambient)
scene.background.contents = NSColor(white: 0.12, alpha: 1)
let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = scene; renderer.pointOfView = camera
let image = renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 512), antialiasingMode: .multisampling4X)
try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[2]))
```

- [ ] **Step 7: Generar el USDZ real y revisarlo**

```bash
cd scripts/mascot && source ~/.nvm/nvm.sh
node convert.mjs ~/Downloads/frontbot-meshy.glb
swift preview.swift ../../app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz out/front.png 0
swift preview.swift ../../app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz out/side.png 60
```

Expected: `✓ …frontbot.usdz: 36829 vértices, 55800 triángulos, 2.41 MB`. Abrir `out/front.png` y `out/side.png`: la cara (ojos, F dorada, mejillas) mira a cámara, las orejas están enteras y las texturas no se ven corridas. Si algo se ve mal, parar y avisar al usuario antes de seguir.

- [ ] **Step 8: Ajustar la spec a lo comprobado**

En `docs/superpowers/specs/2026-10-16-frontbot-mascota-design.md`:

- Sustituir el paso 5 de "Conversión" por: "Escribe USDA con material `UsdPreviewSurface` (color base, metal/rugosidad y relieve), lo convierte a `.usdc` con `usdcat` y lo empaqueta en `.usdz` con un empaquetador propio (`usdz.mjs`), porque ni `realitytool` ni `usdcat` generan USDZ desde glTF."
- En el paso 2, decir: "texturas a 1024 px: color y metal/rugosidad en JPEG, relieve en PNG".
- En "MascotView", sustituir la frase del brillo por: "El brillo de la pose regula una luz puntual cian delante del modelo (el material no tiene máscara de emisión: modular su emisión teñiría todo el cuerpo). La escena usa una luz ambiental basada en imagen generada en código; sin ella el blanco se ve gris."

- [ ] **Step 9: Commit**

```bash
git add .gitignore scripts/mascot/package.json scripts/mascot/package-lock.json scripts/mascot/*.mjs scripts/mascot/preview.swift \
  app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz docs/superpowers/specs/2026-10-16-frontbot-mascota-design.md
git commit -m "feat(mascot): convert the Meshy model to a USDZ the app can load

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Estados de la mascota (`MascotMood`)

**Files:**
- Create: `app/Sources/FrontbotCore/Mascot/MascotMood.swift`
- Test: `app/Tests/FrontbotCoreTests/MascotMoodTests.swift`

**Interfaces:**
- Produces:
  - `public enum MascotState: String, CaseIterable, Sendable { case idle, listening, thinking, talking, happy, sad }`
  - `public struct MascotMood: Equatable, Sendable`, con `init()`, `mutating func runStarted(at: Date)`, `mutating func agentSpoke(at: Date)`, `mutating func runFinished(ok: Bool, at: Date)` y `func state(at: Date, listening: Bool) -> MascotState`.
  - Constantes: `static let reactionDuration: TimeInterval = 2` y `static let talkingHold: TimeInterval = 1.5`.

- [ ] **Step 1: Tests (fallan)**

`app/Tests/FrontbotCoreTests/MascotMoodTests.swift`:

```swift
import XCTest
@testable import FrontbotCore

final class MascotMoodTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testIdleUntilSomethingHappens() {
        let mood = MascotMood()
        XCTAssertEqual(mood.state(at: t0, listening: false), .idle)
        XCTAssertEqual(mood.state(at: t0, listening: true), .listening)
    }

    func testThinkingThenTalkingWhileTextArrives() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        XCTAssertEqual(mood.state(at: at(0.5), listening: true), .thinking, "el run manda sobre escuchar")
        mood.agentSpoke(at: at(1))
        XCTAssertEqual(mood.state(at: at(2), listening: false), .talking)
        XCTAssertEqual(mood.state(at: at(1 + MascotMood.talkingHold + 0.1), listening: false), .thinking, "sin texto nuevo vuelve a pensar")
    }

    func testHappyThenIdleAfterSuccess() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        mood.runFinished(ok: true, at: at(5))
        XCTAssertEqual(mood.state(at: at(5.5), listening: true), .happy, "la reacción manda sobre escuchar")
        XCTAssertEqual(mood.state(at: at(5 + MascotMood.reactionDuration + 0.1), listening: false), .idle)
        XCTAssertEqual(mood.state(at: at(5 + MascotMood.reactionDuration + 0.1), listening: true), .listening)
    }

    func testSadThenIdleAfterFailureOrCancel() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        mood.agentSpoke(at: at(1))
        mood.runFinished(ok: false, at: at(1.2))
        XCTAssertEqual(mood.state(at: at(1.3), listening: false), .sad, "nunca se queda hablando ni pensando")
        XCTAssertEqual(mood.state(at: at(1.2 + MascotMood.reactionDuration + 0.1), listening: false), .idle)
    }

    func testRunThatFailsToStartStillEndsSad() {
        var mood = MascotMood()
        mood.runStarted(at: at(0))
        mood.runFinished(ok: false, at: at(0)) // send() falla antes de que el agente arranque
        XCTAssertEqual(mood.state(at: at(0.1), listening: false), .sad)
    }

    func testNewRunClearsThePreviousReaction() {
        var mood = MascotMood()
        mood.runFinished(ok: true, at: at(0))
        mood.runStarted(at: at(0.5))
        XCTAssertEqual(mood.state(at: at(0.6), listening: false), .thinking)
    }
}
```

Run: `cd app && swift test --filter MascotMoodTests`
Expected: FAIL (`cannot find 'MascotMood' in scope`).

- [ ] **Step 2: Implementación**

`app/Sources/FrontbotCore/Mascot/MascotMood.swift`:

```swift
import Foundation

/// Lo que está haciendo la mascota.
public enum MascotState: String, CaseIterable, Sendable {
    case idle, listening, thinking, talking, happy, sad
}

/// Decide el estado de la mascota a partir de los eventos del agente, con hora (sin depender de la UI).
/// Prioridad: run en curso (pensando/hablando) > reacción reciente (feliz/triste) > escuchando > reposo.
public struct MascotMood: Equatable, Sendable {
    public static let reactionDuration: TimeInterval = 2
    public static let talkingHold: TimeInterval = 1.5

    private var running = false
    private var lastSpoke: Date?
    private var reaction: (ok: Bool, at: Date)?

    public init() {}

    public mutating func runStarted(at date: Date) {
        running = true
        lastSpoke = nil
        reaction = nil
    }

    public mutating func agentSpoke(at date: Date) {
        lastSpoke = date
    }

    public mutating func runFinished(ok: Bool, at date: Date) {
        running = false
        lastSpoke = nil
        reaction = (ok, date)
    }

    /// `listening`: el notch está abierto o el usuario está escribiendo.
    public func state(at now: Date, listening: Bool) -> MascotState {
        if running {
            if let spoke = lastSpoke, now.timeIntervalSince(spoke) < Self.talkingHold { return .talking }
            return .thinking
        }
        if let reaction, now.timeIntervalSince(reaction.at) < Self.reactionDuration { return reaction.ok ? .happy : .sad }
        return listening ? .listening : .idle
    }

    public static func == (a: MascotMood, b: MascotMood) -> Bool {
        a.running == b.running && a.lastSpoke == b.lastSpoke && a.reaction?.ok == b.reaction?.ok && a.reaction?.at == b.reaction?.at
    }
}
```

Run: `swift test --filter MascotMoodTests`
Expected: PASS (6 tests).

- [ ] **Step 3: Commit**

```bash
git add app/Sources/FrontbotCore/Mascot/MascotMood.swift app/Tests/FrontbotCoreTests/MascotMoodTests.swift
git commit -m "feat(mascot): mascot states driven by agent events

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Movimiento (`MascotMotion`)

**Files:**
- Create: `app/Sources/FrontbotCore/Mascot/MascotMotion.swift`
- Test: `app/Tests/FrontbotCoreTests/MascotMotionTests.swift`

**Interfaces:**
- Consumes: `MascotState` (Task 2).
- Produces:
  - `public struct MascotPose: Equatable, Sendable`, con los campos `offset: SIMD3<Float>`, `yaw: Float`, `pitch: Float`, `roll: Float`, `scale: SIMD3<Float>` y `glow: Float` (0…1), más `static let rest`.
  - `public enum MascotMotion`, con:
    - `static func pose(_ state: MascotState, t: TimeInterval, reduceMotion: Bool) -> MascotPose`, donde `t` son los segundos desde que se entró en el estado;
    - `static func period(_ state: MascotState) -> TimeInterval?` (nil en `happy` y `sad`, que no se repiten);
    - `static func blend(_ a: MascotPose, _ b: MascotPose, progress: Float) -> MascotPose`;
    - `static let blendDuration: TimeInterval = 0.25`;
    - `static func needsFrames(_ state: MascotState, reduceMotion: Bool) -> Bool`.
- Unidades: el lado mayor del modelo mide 1, y los ángulos van en radianes.

- [ ] **Step 1: Tests (fallan)**

`app/Tests/FrontbotCoreTests/MascotMotionTests.swift`:

```swift
import XCTest
@testable import FrontbotCore

final class MascotMotionTests: XCTestCase {
    let times = stride(from: 0.0, through: 6.0, by: 0.05).map { $0 }

    func close(_ a: MascotPose, _ b: MascotPose, _ eps: Float = 1e-3) -> Bool {
        let angle = { (x: Float, y: Float) in abs(remainder(x - y, 2 * .pi)) < eps }
        return simd_distance(a.offset, b.offset) < eps && angle(a.yaw, b.yaw) && angle(a.pitch, b.pitch) && angle(a.roll, b.roll)
            && simd_distance(a.scale, b.scale) < eps && abs(a.glow - b.glow) < eps
    }

    func testEveryStateStaysWithinLimits() {
        for state in MascotState.allCases {
            for t in times {
                let p = MascotMotion.pose(state, t: t, reduceMotion: false)
                XCTAssertLessThanOrEqual(simd_length(p.offset), 0.2, "\(state) t=\(t)")
                XCTAssertLessThanOrEqual(abs(p.pitch), 0.4); XCTAssertLessThanOrEqual(abs(p.roll), 0.4)
                XCTAssertTrue((0.85...1.15).contains(p.scale.x) && (0.85...1.15).contains(p.scale.y) && (0.85...1.15).contains(p.scale.z), "\(state) t=\(t)")
                XCTAssertTrue((0...1).contains(p.glow))
            }
        }
    }

    func testLoopingStatesCloseTheirCycle() {
        for state in MascotState.allCases {
            guard let period = MascotMotion.period(state) else { continue }
            for t in [0.0, 0.3, 1.1, 2.7] {
                XCTAssertTrue(close(MascotMotion.pose(state, t: t, reduceMotion: false), MascotMotion.pose(state, t: t + period, reduceMotion: false)), "\(state) t=\(t)")
            }
        }
        XCTAssertNil(MascotMotion.period(.happy)); XCTAssertNil(MascotMotion.period(.sad))
    }

    func testHappyEndsFacingForwardAtRest() {
        let end = MascotMotion.pose(.happy, t: 1.6, reduceMotion: false)
        XCTAssertTrue(close(end, MascotPose(offset: .zero, yaw: 0, pitch: 0, roll: 0, scale: [1, 1, 1], glow: end.glow)), "acaba de frente y quieta")
    }

    func testReduceMotionKeepsThePoseStill() {
        for state in MascotState.allCases {
            for t in times {
                let p = MascotMotion.pose(state, t: t, reduceMotion: true)
                XCTAssertEqual(p.offset, .zero); XCTAssertEqual(p.yaw, 0); XCTAssertEqual(p.pitch, 0); XCTAssertEqual(p.roll, 0)
                XCTAssertEqual(p.scale, [1, 1, 1])
            }
        }
        XCTAssertNotEqual(MascotMotion.pose(.thinking, t: 0, reduceMotion: true).glow, MascotMotion.pose(.idle, t: 0, reduceMotion: true).glow, "el brillo sí cambia")
    }

    func testBlendIsContinuousBetweenStates() {
        let a = MascotMotion.pose(.happy, t: 0.3, reduceMotion: false), b = MascotMotion.pose(.talking, t: 0, reduceMotion: false)
        XCTAssertTrue(close(MascotMotion.blend(a, b, progress: 0), a))
        XCTAssertTrue(close(MascotMotion.blend(a, b, progress: 1), b))
        let mid = MascotMotion.blend(a, b, progress: 0.5)
        XCTAssertEqual(mid.offset.y, (a.offset.y + b.offset.y) / 2, accuracy: 1e-4)
        XCTAssertTrue(close(MascotMotion.blend(a, b, progress: 3), b), "progress se limita a 0…1")
    }

    func testOnlyRestNeedsNoFrames() {
        XCTAssertFalse(MascotMotion.needsFrames(.idle, reduceMotion: true))
        XCTAssertTrue(MascotMotion.needsFrames(.idle, reduceMotion: false))
        XCTAssertTrue(MascotMotion.needsFrames(.thinking, reduceMotion: true), "el brillo pulsa")
    }
}
```

Run: `swift test --filter MascotMotionTests`
Expected: FAIL (`cannot find 'MascotMotion' in scope`).

- [ ] **Step 2: Implementación**

`app/Sources/FrontbotCore/Mascot/MascotMotion.swift`:

```swift
import Foundation
import simd

/// Pose del modelo respecto a su posición de reposo (lado mayor = 1, ángulos en radianes).
public struct MascotPose: Equatable, Sendable {
    public var offset: SIMD3<Float>
    public var yaw: Float
    public var pitch: Float
    public var roll: Float
    public var scale: SIMD3<Float>
    /// Intensidad de la luz cian, 0…1.
    public var glow: Float

    public init(offset: SIMD3<Float> = .zero, yaw: Float = 0, pitch: Float = 0, roll: Float = 0, scale: SIMD3<Float> = [1, 1, 1], glow: Float = 0.3) {
        self.offset = offset; self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.scale = scale; self.glow = glow
    }

    public static let rest = MascotPose()
}

/// Movimiento de la mascota por estado: funciones puras del tiempo transcurrido en el estado.
public enum MascotMotion {
    public static let blendDuration: TimeInterval = 0.25

    public static func period(_ state: MascotState) -> TimeInterval? {
        switch state {
        case .idle: 4
        case .listening: 3
        case .thinking: 1.6
        case .talking: 0.5
        case .happy, .sad: nil
        }
    }

    /// En reposo con "Reducir movimiento" no cambia nada: la vista puede dejar de pedir fotogramas.
    public static func needsFrames(_ state: MascotState, reduceMotion: Bool) -> Bool {
        !(reduceMotion && (state == .idle || state == .listening))
    }

    public static func pose(_ state: MascotState, t: TimeInterval, reduceMotion: Bool) -> MascotPose {
        let p = motion(state, t: Float(t))
        return reduceMotion ? MascotPose(glow: p.glow) : p
    }

    public static func blend(_ a: MascotPose, _ b: MascotPose, progress: Float) -> MascotPose {
        let k = smooth(min(max(progress, 0), 1))
        let mix = { (x: Float, y: Float) in x + (y - x) * k }
        // El giro va por el camino corto (p. ej. de 2π a 0 no da otra vuelta).
        let yaw = a.yaw + remainder(b.yaw - a.yaw, 2 * .pi) * k
        return MascotPose(offset: a.offset + (b.offset - a.offset) * k, yaw: yaw, pitch: mix(a.pitch, b.pitch), roll: mix(a.roll, b.roll),
                          scale: a.scale + (b.scale - a.scale) * k, glow: mix(a.glow, b.glow))
    }

    // MARK: Estados

    private static func motion(_ state: MascotState, t: Float) -> MascotPose {
        let tau = 2 * Float.pi
        switch state {
        case .idle: // flota despacio y se mece
            let w = tau * t / 4
            return MascotPose(offset: [0, 0.03 * sin(w), 0], roll: 0.03 * sin(w + .pi / 2), glow: 0.3)
        case .listening: // te mira con la cabeza ladeada
            let w = tau * t / 3
            return MascotPose(offset: [0, 0.015 * sin(w), 0], pitch: -0.12, roll: 0.15 + 0.03 * sin(w), glow: 0.6)
        case .thinking: // mira a un lado y a otro; la luz pulsa
            let w = tau * t / 1.6
            return MascotPose(offset: [0, 0.02 * sin(2 * w), 0], yaw: 0.35 * sin(w), roll: 0.05 * sin(w), glow: 0.5 + 0.5 * sin(2 * w) * 0.8)
        case .talking: // rebotes cortos al ritmo de las respuestas
            let b = abs(sin(.pi * t / 0.5))
            return MascotPose(offset: [0, 0.04 * b, 0], scale: [1 - 0.02 * b, 1 + 0.03 * b, 1 - 0.02 * b], glow: 0.6 + 0.3 * b)
        case .happy: // se agacha, salta girando una vuelta entera y aterriza
            let crouch = t < 0.15 ? sin(.pi * t / 0.15) : 0
            let jump = (0.15..<0.75).contains(t) ? sin(.pi * (t - 0.15) / 0.6) : 0
            let spin = tau * smooth(min(max((t - 0.2) / 1.0, 0), 1))
            return MascotPose(offset: [0, 0.15 * jump - 0.03 * crouch, 0], yaw: spin == tau ? 0 : spin,
                              scale: [1 + 0.06 * crouch - 0.03 * jump, 1 - 0.1 * crouch + 0.06 * jump, 1 + 0.06 * crouch - 0.03 * jump], glow: 1)
        case .sad: // se encoge y baja la mirada
            let k = smooth(min(t / 0.3, 1))
            return MascotPose(offset: [0, -0.04 * k, 0], pitch: 0.25 * k, scale: [1 - 0.08 * k, 1 - 0.08 * k, 1 - 0.08 * k], glow: 0.3 - 0.2 * k)
        }
    }

    private static func smooth(_ x: Float) -> Float { x * x * (3 - 2 * x) }
}
```

Run: `swift test --filter MascotMotionTests`
Expected: PASS (6 tests).

- [ ] **Step 3: Commit**

```bash
git add app/Sources/FrontbotCore/Mascot/MascotMotion.swift app/Tests/FrontbotCoreTests/MascotMotionTests.swift
git commit -m "feat(mascot): procedural whole-body motion per state

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Escena RealityKit (`MascotScene`) y macOS 15

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Sources/FrontbotCore/Mascot/MascotScene.swift`
- Test: `app/Tests/FrontbotCoreTests/MascotSceneTests.swift`

**Interfaces:**
- Consumes: `MascotPose`, `MascotMotion` y `MascotState` (Tasks 2-3); el USDZ de la Task 1.
- Produces: `@MainActor public final class MascotScene`, con:
  - `root: Entity`, que lo contiene todo (modelo, luces y cámara);
  - `camera: PerspectiveCamera`;
  - `static func load(from url: URL) async throws -> MascotScene`, que cachea el modelo por URL y clona;
  - `func apply(_ pose: MascotPose)`;
  - `static func vertexCount(of entity: Entity) -> Int`.

- [ ] **Step 1: Subir a macOS 15 y excluir los recursos del target**

En `app/Package.swift`:

```swift
    platforms: [.macOS(.v15)],
```

```swift
        // Los recursos de la mascota los copia build-app.sh (Bundle.module no funciona dentro de un .app).
        .executableTarget(name: "FrontbotApp", dependencies: ["FrontbotCore"], exclude: ["Resources"]),
```

Run: `cd app && swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!` (puede haber avisos nuevos de APIs obsoletas en macOS 15: anotarlos, no corregirlos aquí).

- [ ] **Step 2: Tests (fallan)**

`app/Tests/FrontbotCoreTests/MascotSceneTests.swift`. Renderiza sin ventana con `RealityRenderer` (comprobado en esta máquina) y guarda las PNG para revisarlas:

```swift
import XCTest
import RealityKit
import Metal
import CoreImage
@testable import FrontbotCore

@MainActor
final class MascotSceneTests: XCTestCase {
    static let usdz = AgentClientTests.repoRoot.appendingPathComponent("app/Sources/FrontbotApp/Resources/Mascot/frontbot.usdz")
    static let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("frontbot-mascot-snapshots", isDirectory: true)

    func testBundledModelIsWithinBudget() async throws {
        let size = try FileManager.default.attributesOfItem(atPath: Self.usdz.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 3_000_000)
        let scene = try await MascotScene.load(from: Self.usdz)
        let verts = MascotScene.vertexCount(of: scene.root)
        XCTAssertGreaterThan(verts, 1000); XCTAssertLessThan(verts, 40_000)
    }

    func testMissingModelThrows() async {
        do { _ = try await MascotScene.load(from: URL(fileURLWithPath: "/nope/frontbot.usdz")); XCTFail("debía fallar") } catch {}
    }

    /// Cada estado en su momento más extremo: la mascota se ve y no se sale del encuadre.
    func testEveryStateStaysInFrame() async throws {
        try FileManager.default.createDirectory(at: Self.snapshots, withIntermediateDirectories: true)
        let scene = try await MascotScene.load(from: Self.usdz)
        let moments: [(MascotState, TimeInterval)] = [(.idle, 1), (.listening, 0.5), (.thinking, 0.4), (.talking, 0.25), (.happy, 0.45), (.happy, 0.7), (.sad, 1)]
        for (state, t) in moments {
            scene.apply(MascotMotion.pose(state, t: t, reduceMotion: false))
            let pixels = try await Self.render(scene, size: 256, to: Self.snapshots.appendingPathComponent("\(state.rawValue)-\(t).png"))
            let coverage = Double(pixels.alpha.filter { $0 > 0 }.count) / Double(pixels.alpha.count)
            XCTAssertTrue((0.15...0.75).contains(coverage), "\(state) t=\(t): cobertura \(coverage)")
            XCTAssertEqual(pixels.borderAlpha, 0, "\(state) t=\(t): toca el borde (se sale del encuadre)")
        }
        print("Instantáneas en \(Self.snapshots.path)")
    }

    struct Pixels { let alpha: [UInt8]; let borderAlpha: Int }

    static func render(_ scene: MascotScene, size: Int, to url: URL) async throws -> Pixels {
        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        renderer.activeCamera = scene.camera
        let device = MTLCreateSystemDefaultDevice()!
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let color = device.makeTexture(descriptor: desc)!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: color))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in c.resume() }) } catch { c.resume(throwing: error) }
        }
        renderer.entities.removeAll() // la escena vuelve a estar libre para el siguiente render
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        color.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let ci = CIImage(mtlTexture: color, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])!.oriented(.downMirrored)
        try CIContext().writePNGRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        var border = 0
        for i in 0..<size { border += Int(alpha[i]) + Int(alpha[(size - 1) * size + i]) + Int(alpha[i * size]) + Int(alpha[i * size + size - 1]) }
        return Pixels(alpha: alpha, borderAlpha: border)
    }
}
```

Run: `swift test --filter MascotSceneTests`
Expected: FAIL (`cannot find 'MascotScene' in scope`).

- [ ] **Step 3: Implementación**

`app/Sources/FrontbotCore/Mascot/MascotScene.swift`:

```swift
import Foundation
import RealityKit
import CoreGraphics

/// La mascota lista para RealityKit: modelo, luces (incluida la ambiental, sin la que el blanco se ve gris) y cámara.
/// `apply` mueve solo el modelo; luces y cámara quedan fijas.
@MainActor
public final class MascotScene {
    public let root = Entity()
    public let camera = PerspectiveCamera()
    private let pivot = Entity()
    private let glowLight = PointLight()

    /// Una carga por URL; cada escena usa un clon.
    private static var templates: [URL: Entity] = [:]
    private static var environment: EnvironmentResource?

    public static func load(from url: URL) async throws -> MascotScene {
        let template: Entity
        if let cached = templates[url] { template = cached } else {
            template = try await Entity(contentsOf: url)
            templates[url] = template
        }
        let scene = MascotScene()
        try await scene.build(model: template.clone(recursive: true))
        return scene
    }

    private func build(model: Entity) async throws {
        pivot.addChild(model)
        root.addChild(pivot)

        camera.camera.fieldOfViewInDegrees = 30
        camera.position = [0, 0, 2.6] // margen para el salto y el giro
        root.addChild(camera)

        let ambient = Entity()
        ambient.components.set(ImageBasedLightComponent(source: .single(try await Self.ambientEnvironment()), intensityExponent: 0.8))
        root.addChild(ambient)
        model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ambient))

        let key = DirectionalLight()
        key.light.intensity = 3000
        key.look(at: .zero, from: [1, 1.5, 2], relativeTo: nil)
        root.addChild(key)

        glowLight.light.color = .init(red: 0.37, green: 0.89, blue: 0.84, alpha: 1)
        glowLight.light.attenuationRadius = 2
        glowLight.position = [0, 0.1, 0.9]
        root.addChild(glowLight)
        apply(.rest)
    }

    public func apply(_ pose: MascotPose) {
        pivot.position = pose.offset
        pivot.orientation = simd_quatf(angle: pose.yaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.pitch, axis: [1, 0, 0]) * simd_quatf(angle: pose.roll, axis: [0, 0, 1])
        pivot.scale = pose.scale
        glowLight.light.intensity = 300 + 2700 * pose.glow
    }

    public static func vertexCount(of entity: Entity) -> Int {
        var count = 0
        if let model = entity.components[ModelComponent.self] {
            for m in model.mesh.contents.models { for part in m.parts { count += part.positions.count } }
        }
        return count + entity.children.reduce(0) { $0 + vertexCount(of: $1) }
    }

    /// Degradado vertical (arriba claro, abajo gris) como entorno equirectangular.
    private static func ambientEnvironment() async throws -> EnvironmentResource {
        if let environment { return environment }
        let w = 256, h = 128
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let v = UInt8(max(70, 255 - y * 185 / h))
            for x in 0..<w { let i = (y * w + x) * 4; px[i] = v; px[i + 1] = v; px[i + 2] = v }
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let resource = try await EnvironmentResource(equirectangular: image)
        environment = resource
        return resource
    }
}
```

Run: `swift test --filter MascotSceneTests`
Expected: PASS (3 tests). Si `testEveryStateStaysInFrame` falla por el borde, alejar la cámara (`camera.position.z`) en pasos de 0,2, nunca por encima de 3,2. Si falla por cobertura baja, acercarla. Abrir las PNG de la ruta impresa y comprobar que se ve como en `scripts/mascot/out/front.png`: de frente, blanca y con dorados.

- [ ] **Step 4: Suite completa y commit**

Run: `FRONTBOT_NODE=$(source ~/.nvm/nvm.sh >/dev/null 2>&1; which node) swift test 2>&1 | grep -E "Executed .* tests|error:" | tail -2`
Expected: 0 failures.

```bash
git add app/Package.swift app/Sources/FrontbotCore/Mascot/MascotScene.swift app/Tests/FrontbotCoreTests/MascotSceneTests.swift
git commit -m "feat(mascot): RealityKit scene with lighting, camera and poses; require macOS 15

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Logo e icono

**Files:**
- Create: `scripts/mascot/cutout.swift`
- Create: `scripts/mascot/make-icon.swift`
- Create: `scripts/mascot/make-icon.sh`
- Create (generados): `app/Sources/FrontbotApp/Resources/Mascot/logo.png`, `app/Sources/FrontbotApp/Resources/AppIcon.icns`
- Create: `app/Sources/FrontbotApp/MascotAssets.swift`
- Modify: `app/Sources/FrontbotApp/Theme.swift` (`AgentAvatar`, nuevo `FrontbotLogo`)
- Modify: `app/Sources/FrontbotApp/BrandsView.swift:16`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Produces:
  - `enum MascotAssets { static func url(_ name: String, resources: URL?) -> URL?; static var model: URL? { get }; static var logo: NSImage? { get } }`. Busca primero en `<resources>/Mascot/` y después en `app/Sources/FrontbotApp/Resources/Mascot/`, la ruta de desarrollo derivada de `#filePath`.
  - `struct FrontbotLogo: View { var size: CGFloat }`. Si no hay logo, usa el SF Symbol de antes.

- [ ] **Step 1: Recorte con Vision**

`scripts/mascot/cutout.swift` (verificado: recorta una sola figura de 716×587 con transparencia):

```swift
// Uso: swift cutout.swift <dibujo.jpeg> <logo.png>
// Aísla la mascota del fondo (como "aislar sujeto" en Fotos) y la guarda recortada a 512 px como máximo.
import Vision
import CoreImage

let args = CommandLine.arguments
guard args.count == 3, let source = CIImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    print("Uso: swift cutout.swift <dibujo.jpeg> <logo.png>"); exit(2)
}
let handler = VNImageRequestHandler(ciImage: source)
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])
guard let result = request.results?.first, !result.allInstances.isEmpty else { print("✗ Vision no encontró la mascota en el dibujo."); exit(1) }
let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
var cut = CIImage(cvPixelBuffer: buffer)
let scale = min(1, 512 / max(cut.extent.width, cut.extent.height))
cut = cut.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
try CIContext().writePNGRepresentation(of: cut, to: URL(fileURLWithPath: args[2]), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
print("✓ \(args[2]): \(Int(cut.extent.width))×\(Int(cut.extent.height))")
```

Run: `cd scripts/mascot && swift cutout.swift ~/Downloads/frontbot.jpeg ../../app/Sources/FrontbotApp/Resources/Mascot/logo.png`
Expected: `✓ …logo.png: 512×420` (aprox.). Abrir la imagen: mascota entera, sin fondo blanco alrededor.

- [ ] **Step 2: Icono**

`scripts/mascot/make-icon.swift`: pinta un cuadrado redondeado con el fondo de la app (`#0B0B0C`) y el logo al 78 % del ancho, en una imagen de 1024 px:

```swift
// Uso: swift make-icon.swift <logo.png> <icono-1024.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]) else { print("Uso: swift make-icon.swift <logo.png> <salida.png>"); exit(2) }
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Margen y radio de la plantilla de iconos de macOS (824 px de 1024, radio ~185).
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185).fill()
    let w = plate.width * 0.78, h = w * logo.size.height / logo.size.width
    logo.draw(in: NSRect(x: plate.midX - w / 2, y: plate.midY - h / 2, width: w, height: h))
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("✓ \(args[2])")
```

`scripts/mascot/make-icon.sh`:

```bash
#!/bin/bash
# Genera AppIcon.icns a partir de logo.png. Uso: scripts/mascot/make-icon.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../../app/Sources/FrontbotApp/Resources"
WORK="$HERE/out/AppIcon.iconset"
rm -rf "$WORK" && mkdir -p "$WORK"
swift "$HERE/make-icon.swift" "$RES/Mascot/logo.png" "$HERE/out/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$HERE/out/icon-1024.png" --out "$WORK/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$HERE/out/icon-1024.png" --out "$WORK/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK" -o "$RES/AppIcon.icns"
echo "✓ $RES/AppIcon.icns"
```

Run: `chmod +x scripts/mascot/make-icon.sh && scripts/mascot/make-icon.sh && open scripts/mascot/out/icon-1024.png`
Expected: `✓ …/AppIcon.icns`. El icono muestra la mascota sobre un cuadrado redondeado oscuro.

- [ ] **Step 3: Test de localización de recursos (falla)**

El target de la app no tiene tests, así que la lógica de búsqueda va en una función pura dentro de Core: `MascotResources.locate(_ name: String, candidates: [URL]) -> URL?`. Devuelve el primer candidato que existe.

`app/Tests/FrontbotCoreTests/MascotResourcesTests.swift`:

```swift
import XCTest
@testable import FrontbotCore

final class MascotResourcesTests: XCTestCase {
    func testPrefersTheAppBundleThenTheSourceTree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = base.appendingPathComponent("Bundle/Mascot"), source = base.appendingPathComponent("Source/Mascot")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("s".utf8).write(to: source.appendingPathComponent("logo.png"))
        XCTAssertEqual(MascotResources.locate("logo.png", candidates: [bundled, source])?.path, source.appendingPathComponent("logo.png").path)
        try Data("b".utf8).write(to: bundled.appendingPathComponent("logo.png"))
        XCTAssertEqual(MascotResources.locate("logo.png", candidates: [bundled, source])?.path, bundled.appendingPathComponent("logo.png").path)
        XCTAssertNil(MascotResources.locate("frontbot.usdz", candidates: [bundled, source]), "sin el archivo, nil (la app usa el símbolo)")
    }
}
```

Run: `cd app && swift test --filter MascotResourcesTests`
Expected: FAIL (`cannot find 'MascotResources' in scope`).

- [ ] **Step 4: `MascotResources` (Core), `MascotAssets` y `FrontbotLogo` (app)**

Añadir al final de `app/Sources/FrontbotCore/Mascot/MascotScene.swift`:

```swift
/// Dónde están los archivos de la mascota: dentro del .app (Contents/Resources/Mascot) o, en desarrollo, en las fuentes.
public enum MascotResources {
    public static func locate(_ name: String, candidates: [URL]) -> URL? {
        candidates.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
```

`app/Sources/FrontbotApp/MascotAssets.swift`:

```swift
import AppKit
import FrontbotCore

/// Archivos de la mascota de esta app (los copia build-app.sh; con `swift run` se leen de las fuentes).
enum MascotAssets {
    private static let candidates: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("Mascot", isDirectory: true),
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Mascot", isDirectory: true),
    ].compactMap { $0 }

    static var model: URL? { MascotResources.locate("frontbot.usdz", candidates: candidates) }
    static let logo: NSImage? = MascotResources.locate("logo.png", candidates: candidates).flatMap(NSImage.init(contentsOf:))
}
```

En `app/Sources/FrontbotApp/Theme.swift`, añadir:

```swift
/// Logo de Frontbot (la mascota en 2D). Sin el archivo, el símbolo de siempre.
struct FrontbotLogo: View {
    var size: CGFloat = 18

    var body: some View {
        if let logo = MascotAssets.logo {
            Image(nsImage: logo).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "rectangle.roundedtop").font(.system(size: size * 0.8)).foregroundStyle(Theme.accent).frame(width: size, height: size)
        }
    }
}
```

En `AgentAvatar.body`, Frontbot usa el logo en vez del SF Symbol:

```swift
    var body: some View {
        if agent.isDefault {
            FrontbotLogo(size: size).opacity(agent.status == .draft ? 0.55 : 1)
        } else {
            let tone = Self.tones[abs(agent.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.tones.count]
            Image(systemName: agent.icon)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(Color(hex: tone.1))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Color(hex: tone.0)))
                .opacity(agent.status == .draft ? 0.55 : 1)
        }
    }
```

En `app/Sources/FrontbotApp/BrandsView.swift:16`, sustituir `Image(systemName: "rectangle.roundedtop").foregroundStyle(Theme.accent)` por `FrontbotLogo(size: 20)`.

Run: `swift test --filter MascotResourcesTests && swift build 2>&1 | grep -E "error|Build complete"`
Expected: PASS y `Build complete!`.

- [ ] **Step 5: Empaquetar recursos e icono en el .app**

En `scripts/build-app.sh`, después de la línea que copia los `*.bundle` (línea 23):

```bash
# Mascota (modelo 3D y logo) e icono de la app.
cp -R "$ROOT/app/Sources/FrontbotApp/Resources/Mascot" "$APP/Contents/Resources/"
cp "$ROOT/app/Sources/FrontbotApp/Resources/AppIcon.icns" "$APP/Contents/Resources/"
```

Y en el `Info.plist`, después de `CFBundlePackageType`:

```xml
  <key>CFBundleIconFile</key><string>AppIcon</string>
```

Comprobar también la clave `LSMinimumSystemVersion` del plist: si existe, ponerla a `15.0`; si no, añadirla con `<key>LSMinimumSystemVersion</key><string>15.0</string>`.

Run: `scripts/build-app.sh && ls build/Frontbot.app/Contents/Resources/Mascot build/Frontbot.app/Contents/Resources/AppIcon.icns`
Expected: aparecen `frontbot.usdz`, `logo.png` y `AppIcon.icns`.

- [ ] **Step 6: Commit**

```bash
git add scripts/mascot/cutout.swift scripts/mascot/make-icon.swift scripts/mascot/make-icon.sh scripts/build-app.sh \
  app/Sources/FrontbotApp/Resources/Mascot/logo.png app/Sources/FrontbotApp/Resources/AppIcon.icns \
  app/Sources/FrontbotCore/Mascot/MascotScene.swift app/Tests/FrontbotCoreTests/MascotResourcesTests.swift \
  app/Sources/FrontbotApp/MascotAssets.swift app/Sources/FrontbotApp/Theme.swift app/Sources/FrontbotApp/BrandsView.swift
git commit -m "feat(mascot): Frontbot logo and app icon from the 2D design

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `MascotView` y estados en `AppModel`

**Files:**
- Create: `app/Sources/FrontbotApp/MascotView.swift`
- Modify: `app/Sources/FrontbotApp/AppModel.swift` (`send`, `listen`, `finish`)

**Interfaces:**
- Consumes: `MascotScene`, `MascotMotion`, `MascotState` y `MascotMood` (Tasks 2-4); `MascotAssets.model` y `FrontbotLogo` (Task 5).
- Produces:
  - `struct MascotView: View`, con `init(state: MascotState, size: CGFloat, animated: Bool = true)`;
  - `AppModel.mascot: MascotMood`, alimentado por los eventos del agente.

- [ ] **Step 1: Alimentar `MascotMood` desde `AppModel`**

En `AppModel`, junto a `var notchExpanded = false`:

```swift
    /// Estado de la mascota (las vistas lo leen con la hora actual).
    var mascot = MascotMood()
```

En `send(prompt:)`:
- justo después de `isRunning = true`, añadir `mascot.runStarted(at: Date())`;
- en el `catch` del `Task`, después de `isRunning = false`, añadir `mascot.runFinished(ok: false, at: Date())`.

En `listen()`, dentro de `if type == "text" {`, añadir `mascot.agentSpoke(at: Date())`.

En `finish(_ run: AgentRun)`, después de `isRunning = false`, añadir `mascot.runFinished(ok: run.status == .done, at: Date())`.

Run: `cd app && swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`.

- [ ] **Step 2: `MascotView`**

`app/Sources/FrontbotApp/MascotView.swift`:

```swift
import SwiftUI
import RealityKit
import FrontbotCore

/// La mascota en 3D. Pide fotogramas solo mientras se ve y su estado se mueve; si el modelo no carga, muestra el logo.
struct MascotView: View {
    let state: MascotState
    let size: CGFloat
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var scene: MascotScene?
    @State private var failed = false
    @State private var visible = false
    @State private var since = Date()
    @State private var tracker = PoseTracker()

    /// Última pose aplicada: al cambiar de estado se mezcla desde ella (sin saltos).
    @MainActor final class PoseTracker { var last = MascotPose.rest; var from = MascotPose.rest }

    private var reduceMotion: Bool { systemReduceMotion || !animated }

    var body: some View {
        Group {
            if failed || MascotAssets.model == nil {
                FrontbotLogo(size: size * 0.8)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !visible || !MascotMotion.needsFrames(state, reduceMotion: reduceMotion))) { context in
                    reality(pose: pose(at: context.date))
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: state) { _, _ in
            tracker.from = tracker.last
            since = Date()
        }
        .accessibilityHidden(true)
    }

    private func pose(at date: Date) -> MascotPose {
        let t = date.timeIntervalSince(since)
        let target = MascotMotion.pose(state, t: t, reduceMotion: reduceMotion)
        return MascotMotion.blend(tracker.from, target, progress: Float(t / MascotMotion.blendDuration))
    }

    private func reality(pose: MascotPose) -> some View {
        RealityView { content in
            guard let url = MascotAssets.model, let loaded = try? await MascotScene.load(from: url) else {
                failed = true
                return
            }
            content.add(loaded.root)
            scene = loaded
        } update: { _ in
            scene?.apply(pose)
            tracker.last = pose
        }
        .realityViewCameraControls(.none)
    }
}
```

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`.

- [ ] **Step 3: Comprobación visual mínima (usuario)**

Añadir temporalmente `MascotView(state: .thinking, size: 140)` al final del `VStack` de `emptyState` en `ChatView`, ejecutar `swift run FrontbotApp` y pedirle al usuario que confirme:
1. Se ve la mascota de frente y entera, con fondo transparente (sin cuadro negro ni gris).
2. Se mueve de lado a lado y se ilumina en cian.

Si el fondo no es transparente o no se ve nada, la cámara de `MascotScene` no es la que usa `RealityView` en macOS. En ese caso, en el bloque `make`, tras `content.add(loaded.root)`, añadir `content.camera = .virtual` y mover el modelo en vez de la cámara: `loaded.root.position = [0, 0, -2.6]`, quitando la cámara de `root` solo para `MascotView`. Volver a pedir confirmación. Después, quitar la línea temporal.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/FrontbotApp/MascotView.swift app/Sources/FrontbotApp/AppModel.swift
git commit -m "feat(mascot): animated MascotView fed by the agent's events

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Mascota en el notch

**Files:**
- Modify: `app/Sources/FrontbotApp/Notch/NotchView.swift`

**Interfaces:**
- Consumes: `MascotView`, `FrontbotLogo` y `AppModel.mascot` (Tasks 5-6).

- [ ] **Step 1: Notch cerrado**

En `collapsed`, como primer elemento del `HStack` (antes del contador de tareas):

```swift
            // Quieta en reposo (logo); viva mientras el agente trabaja o reacciona.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let state = model.mascot.state(at: context.date, listening: false)
                if state == .idle { FrontbotLogo(size: 18) } else { MascotView(state: state, size: 22) }
            }
```

- [ ] **Step 2: Notch abierto**

En `expanded`, sustituir `Image(systemName: "rectangle.roundedtop").foregroundStyle(Theme.accent)` dentro de la fila de la respuesta por:

```swift
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        MascotView(state: model.mascot.state(at: context.date, listening: true), size: 56)
                    }
```

- [ ] **Step 3: Compilar y comprobación del usuario**

Run: `cd app && swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`.

Pedir al usuario, con `swift run FrontbotApp`, que compruebe:
- **Notch cerrado**: el logo a la izquierda. Al mandar un mensaje desde el chat, la mascota se mueve, y al terminar salta y vuelve al logo.
- **Notch abierto (⌥ Espacio)**: tras una respuesta, la mascota de 56 pt te mira con la cabeza ladeada, piensa mientras trabaja y celebra al terminar.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/FrontbotApp/Notch/NotchView.swift
git commit -m "feat(mascot): Frontbot lives in the notch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Mascota en el chat

**Files:**
- Modify: `app/Sources/FrontbotApp/ChatView.swift` (`emptyState` y la fila "pensando…")

**Interfaces:**
- Consumes: `MascotView` y `AppModel.mascot` (Task 6).

- [ ] **Step 1: Conversación nueva con Frontbot**

En `emptyState`, en la rama `else` (Frontbot), antes de `Text("¿Qué hacemos hoy?")`:

```swift
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    MascotView(state: model.mascot.state(at: context.date, listening: !draft.isEmpty), size: 140)
                }
                .padding(.bottom, 4)
```

y cambiar `.padding(.top, 80)` del final de `emptyState` por `.padding(.top, 40)`, porque la mascota ocupa ese espacio.

- [ ] **Step 2: "Pensando…" con la mascota**

En el `HStack` de `if model.isRunningHere {`, sustituir `ProgressView().controlSize(.small)` por:

```swift
                            if model.selectedAgent?.isDefault == true {
                                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                                    MascotView(state: model.mascot.state(at: context.date, listening: false), size: 28)
                                }
                            } else {
                                ProgressView().controlSize(.small)
                            }
```

- [ ] **Step 3: Compilar, suite y comprobación del usuario**

Run: `cd app && swift build 2>&1 | grep -E "error|Build complete" && FRONTBOT_NODE=$(source ~/.nvm/nvm.sh >/dev/null 2>&1; which node) swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: `Build complete!` y 0 failures.

Pedir al usuario, con `swift run FrontbotApp`, que compruebe:
- **Nueva conversación con Frontbot**: la mascota grande flota, y al escribir te mira.
- **Al enviar**: aparece la mascota pequeña pensando y la grande desaparece.
- **Con otro agente**: todo sigue como antes.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/FrontbotApp/ChatView.swift
git commit -m "feat(mascot): Frontbot greets you in new chats and thinks while answering

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: App empaquetada y repaso final

**Files:** ninguno nuevo (solo verificación; corregir lo que salga en el task que corresponda).

- [ ] **Step 1: Suites completas**

```bash
cd scripts/mascot && source ~/.nvm/nvm.sh && node --test
cd ../../agent && npx vitest run
cd ../app && FRONTBOT_NODE=$(source ~/.nvm/nvm.sh >/dev/null 2>&1; which node) swift test 2>&1 | grep -E "Executed .* tests" | tail -1
```

Expected: todo en verde.

- [ ] **Step 2: App empaquetada**

```bash
cd .. && scripts/build-app.sh && build/Frontbot.app/Contents/MacOS/Frontbot --self-check
```

Expected: el build termina y el self-check pasa. Pedir al usuario que cierre la app (⌘Q), abra `build/Frontbot.app` y repase esta lista:
1. El icono del Dock es la mascota.
2. El logo aparece en la barra lateral y en el avatar de Frontbot.
3. La mascota se ve en el notch (cerrado y abierto) y en el chat.
4. Con Ajustes del Sistema → Accesibilidad → Pantalla → "Reducir movimiento" activado, la mascota no se mueve y solo cambia el brillo.
5. En el Monitor de Actividad, con la app en reposo y el notch cerrado, Frontbot no gasta CPU de forma sostenida.

- [ ] **Step 3: Push**

Solo si el usuario lo pide: `git push origin main`.

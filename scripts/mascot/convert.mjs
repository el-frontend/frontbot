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
import { fileURLToPath, pathToFileURL } from "node:url";
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

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
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

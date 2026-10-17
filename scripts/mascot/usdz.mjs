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

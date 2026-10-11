// Minimal GPT reader for a 512-byte-sector eMMC.

import { SECTOR_SIZE } from "./firehose.js";

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

export function crc32(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * @param {(startSector: number, numSectors: number) => Promise<Uint8Array>} readSectors
 * @returns {Promise<{partitions: {name: string, start: number, sectors: number}[], lastLba: number}>}
 */
export async function readGpt(readSectors) {
  const header = await readSectors(1, 1);
  const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
  if (new TextDecoder().decode(header.subarray(0, 8)) !== "EFI PART") {
    throw new Error("no GPT on this device (bad signature)");
  }
  const headerSize = view.getUint32(12, true);
  const headerCrc = view.getUint32(16, true);
  const forCrc = header.slice(0, headerSize);
  new DataView(forCrc.buffer).setUint32(16, 0, true);
  if (crc32(forCrc) !== headerCrc) throw new Error("GPT header checksum mismatch");

  const lastLba = Number(view.getBigUint64(32, true));
  const entriesLba = Number(view.getBigUint64(72, true));
  const numEntries = view.getUint32(80, true);
  const entrySize = view.getUint32(84, true);
  const entriesCrc = view.getUint32(88, true);
  if (entrySize < 128 || numEntries > 1024) throw new Error("implausible GPT entry table");

  const tableBytes = numEntries * entrySize;
  const table = (await readSectors(entriesLba, Math.ceil(tableBytes / SECTOR_SIZE))).subarray(0, tableBytes);
  if (crc32(table) !== entriesCrc) throw new Error("GPT partition table checksum mismatch");

  const partitions = [];
  const utf16 = new TextDecoder("utf-16le");
  for (let i = 0; i < numEntries; i++) {
    const entry = table.subarray(i * entrySize, (i + 1) * entrySize);
    if (entry.subarray(0, 16).every((b) => b === 0)) continue;
    const e = new DataView(entry.buffer, entry.byteOffset, entry.byteLength);
    const first = Number(e.getBigUint64(32, true));
    const last = Number(e.getBigUint64(40, true));
    const name = utf16.decode(entry.subarray(56, 128)).replace(/\0.*$/, "");
    partitions.push({ name, start: first, sectors: last - first + 1 });
  }
  return { partitions, lastLba };
}

// A pretend phone in EDL mode, speaking Sahara then Firehose over a WebUSB-
// shaped object. It encodes this project's reading of both protocols, so
// passing against it shows the flasher is self-consistent, not that a real
// boot ROM agrees.

import { crc32 } from "../js/gpt.js";
import { LAYOUTS } from "../js/layouts.js";

const SECTOR = 512;
const DISK_SECTORS = 61071360;

const words = (...v) => new Uint8Array(new Uint32Array(v).buffer);

function buildGpt(layout) {
  const entries = new Uint8Array(128 * 128);
  layout.forEach(([name, start, sectors], i) => {
    const e = new DataView(entries.buffer, i * 128, 128);
    e.setUint8(0, 0xa5); // any non-zero type GUID
    e.setUint8(16, i + 1);
    e.setBigUint64(32, BigInt(start), true);
    e.setBigUint64(40, BigInt(start + sectors - 1), true);
    [...name].forEach((ch, j) => e.setUint16(56 + j * 2, ch.charCodeAt(0), true));
  });
  const header = new Uint8Array(SECTOR);
  const h = new DataView(header.buffer);
  header.set(new TextEncoder().encode("EFI PART"));
  h.setUint32(8, 0x00010000, true);
  h.setUint32(12, 92, true);
  h.setBigUint64(24, 1n, true);
  h.setBigUint64(32, BigInt(DISK_SECTORS - 1), true);
  h.setBigUint64(40, 34n, true);
  h.setBigUint64(48, BigInt(DISK_SECTORS - 34), true);
  h.setBigUint64(72, 2n, true);
  h.setUint32(80, 128, true);
  h.setUint32(84, 128, true);
  h.setUint32(88, crc32(entries), true);
  h.setUint32(16, crc32(header.subarray(0, 92)), true);
  return { header, entries };
}

export class MockPhone {
  /**
   * @param {object} o
   * @param {string} o.variant which phone this is: "pvg100" or "pvg100e"
   * @param {Record<string, Uint8Array>} o.loaders the programmer each variant's boot ROM accepts
   * @param {boolean} [o.inFirehose] start with a programmer already running
   * @param {number} [o.maxPayload] largest payload the programmer accepts
   * @param {boolean} [o.chatty] with inFirehose: the running programmer has log lines waiting to be read
   * @param {boolean} [o.readDataFirst] answer <read> with the data straight away, no ACK in front
   * @param {[string, number, number][]} [o.layout] override the partition layout
   */
  constructor({ variant, loaders, inFirehose = false, maxPayload = 1048576, readDataFirst = false, chatty = false, layout }) {
    this.accepts = loaders[variant];
    this.maxPayload = maxPayload;
    this.readDataFirst = readDataFirst;
    this.sectors = new Map(); // sector number -> 512 bytes
    this.writes = []; // [startSector, numSectors] per <program>
    this.inbox = [];
    this.waiters = [];
    this.raw = null;
    this.opened = false;
    this.configuration = {
      interfaces: [
        {
          interfaceNumber: 0,
          alternates: [
            {
              endpoints: [
                { type: "bulk", direction: "in", endpointNumber: 1, packetSize: 512 },
                { type: "bulk", direction: "out", endpointNumber: 1, packetSize: 512 },
              ],
            },
          ],
        },
      ],
    };

    const { header, entries } = buildGpt(layout ?? LAYOUTS[variant]);
    this.#store(1, header);
    this.#store(2, entries);

    this.mode = inFirehose ? "firehose" : "sahara";
    if (!inFirehose) this.#hello();
    else if (chatty) this.#queue(this.#xml(`<log value="ERROR: XML not formed correctly"/>`));
  }

  // --- WebUSB surface -------------------------------------------------------

  async open() {
    this.opened = true;
  }
  async close() {
    this.opened = false;
  }
  async selectConfiguration() {}
  async claimInterface() {}
  async clearHalt() {}

  transferIn(_endpoint, length) {
    return new Promise((resolve) => {
      this.waiters.push({ length, resolve });
      this.#pump();
    });
  }

  async transferOut(_endpoint, data) {
    const bytes = new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength);
    if (bytes.length) this.#receive(bytes.slice());
    return { status: "ok", bytesWritten: bytes.length };
  }

  // --- plumbing -------------------------------------------------------------

  #queue(bytes) {
    this.inbox.push(bytes);
    this.#pump();
  }

  #pump() {
    while (this.waiters.length && this.inbox.length) {
      const { length, resolve } = this.waiters.shift();
      const head = this.inbox[0];
      const part = head.subarray(0, length);
      if (part.length === head.length) this.inbox.shift();
      else this.inbox[0] = head.subarray(length);
      resolve({ status: "ok", data: new DataView(part.buffer, part.byteOffset, part.byteLength) });
    }
  }

  #store(startSector, bytes) {
    for (let i = 0; i * SECTOR < bytes.length; i++) {
      this.sectors.set(startSector + i, bytes.slice(i * SECTOR, (i + 1) * SECTOR));
    }
  }

  /** Bytes currently on the pretend eMMC. */
  readDisk(startSector, numSectors) {
    const out = new Uint8Array(numSectors * SECTOR);
    for (let i = 0; i < numSectors; i++) {
      const sector = this.sectors.get(startSector + i);
      if (sector) out.set(sector, i * SECTOR);
    }
    return out;
  }

  #receive(bytes) {
    if (this.raw) return this.#rawData(bytes);
    if (this.mode === "sahara") return this.#sahara(bytes);
    return this.#firehose(new TextDecoder().decode(bytes));
  }

  // --- Sahara ---------------------------------------------------------------

  #hello() {
    this.#queue(words(0x01, 0x30, 2, 1, 0x400, 0, 0, 0, 0, 0, 0, 0));
  }

  #requestImage() {
    const { got, want } = this.image;
    if (got.length === 0) return this.#queue(words(0x03, 0x14, 13, 0, 52)); // ELF header first
    const length = Math.min(4096, want - got.length);
    this.#queue(words(0x03, 0x14, 13, got.length, length));
  }

  #sahara(bytes) {
    if (this.image?.expect) {
      const merged = new Uint8Array(this.image.got.length + bytes.length);
      merged.set(this.image.got);
      merged.set(bytes, this.image.got.length);
      this.image.got = merged;
      this.image.expect = false;
      if (this.image.got.length < this.image.want) {
        this.image.expect = true;
        return this.#requestImage();
      }
      const ok = this.accepts.length === merged.length && this.accepts.every((b, i) => b === merged[i]);
      return this.#queue(words(0x04, 0x10, 13, ok ? 0 : 0x21));
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const cmd = view.getUint32(0, true);
    if (cmd === 0x02) {
      // A real boot ROM sizes the image from its ELF headers; the mock just knows the size it wants.
      this.image = { got: new Uint8Array(0), want: this.accepts.length, expect: true };
      return this.#requestImage();
    }
    if (cmd === 0x05) {
      this.#queue(words(0x06, 0x0c, 0));
      this.mode = "firehose";
      // A starting programmer announces itself unprompted.
      this.#queue(this.#xml(`<log value="Binary build date: Jan  1 2019 @ 00:00:00"/>`));
      return;
    }
    throw new Error(`mock: unexpected Sahara command 0x${cmd.toString(16)}`);
  }

  // --- Firehose -------------------------------------------------------------

  #xml(inner) {
    return new TextEncoder().encode(`<?xml version="1.0" encoding="UTF-8" ?><data>${inner}</data>`);
  }

  #firehose(text) {
    const tag = text.match(/<data><(\w+)/)?.[1];
    const attr = (name) => text.match(new RegExp(`${name}="([^"]*)"`))?.[1];
    if (tag === "nop") {
      return this.#queue(this.#xml(`<log value="nop"/><response value="ACK" rawmode="false"/>`));
    }
    if (tag === "configure") {
      const asked = Number(attr("MaxPayloadSizeToTargetInBytes"));
      if (attr("MemoryName") !== "emmc") return this.#queue(this.#xml(`<response value="NAK"/>`));
      if (asked > this.maxPayload) {
        return this.#queue(
          this.#xml(`<response value="NAK" MaxPayloadSizeToTargetInBytesSupported="${this.maxPayload}"/>`),
        );
      }
      // Log and response arrive as separate transfers, as they do from a real programmer.
      this.#queue(this.#xml(`<log value="Calling handler for configure"/>`));
      return this.#queue(
        this.#xml(`<response value="ACK" MemoryName="emmc" MaxPayloadSizeToTargetInBytes="${asked}"/>`),
      );
    }
    if (tag === "read" || tag === "program") {
      const start = Number(attr("start_sector"));
      const count = Number(attr("num_partition_sectors"));
      if (attr("SECTOR_SIZE_IN_BYTES") !== "512" || attr("physical_partition_number") !== "0") {
        return this.#queue(this.#xml(`<response value="NAK" rawmode="false"/>`));
      }
      if (tag === "program" || !this.readDataFirst) this.#queue(this.#xml(`<response value="ACK" rawmode="true"/>`));
      if (tag === "read") {
        const data = this.readDisk(start, count);
        for (let o = 0; o < data.length; o += 16384) this.#queue(data.subarray(o, o + 16384));
        return this.#queue(this.#xml(`<response value="ACK" rawmode="false"/>`));
      }
      this.writes.push([start, count]);
      this.raw = { sector: start, left: count * SECTOR };
      return;
    }
    if (tag === "power") {
      this.wasReset = true;
      return this.#queue(this.#xml(`<response value="ACK" rawmode="false"/>`));
    }
    throw new Error(`mock: unexpected Firehose command ${tag}`);
  }

  #rawData(bytes) {
    if (bytes.length % SECTOR || bytes.length > this.maxPayload || bytes.length > this.raw.left) {
      throw new Error(`mock: bad raw payload of ${bytes.length} bytes`);
    }
    this.#store(this.raw.sector, bytes);
    this.raw.sector += bytes.length / SECTOR;
    this.raw.left -= bytes.length;
    if (this.raw.left === 0) {
      this.raw = null;
      this.#queue(this.#xml(`<response value="ACK" rawmode="false"/>`));
    }
  }
}

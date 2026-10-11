// Firehose: the XML protocol spoken by the programmer once it is running.
// Follows linux-msm/qdl's firehose.c. eMMC only: 512-byte sectors, one
// physical partition.

import { TimeoutError } from "./usb.js";

export const SECTOR_SIZE = 512;
const PHYSICAL_PARTITION = 0;
const XML_START = new TextEncoder().encode("<?xml");

function toXml(tag, attrs) {
  const body = Object.entries(attrs)
    .map(([k, v]) => `${k}="${v}"`)
    .join(" ");
  return `<?xml version="1.0" encoding="UTF-8" ?><data><${tag} ${body}/></data>`;
}

function parseAttrs(text) {
  const attrs = {};
  for (const m of text.matchAll(/([\w.]+)="([^"]*)"/g)) attrs[m[1]] = m[2];
  return attrs;
}

export class FirehoseError extends Error {
  constructor(message) {
    super(message);
    this.name = "FirehoseError";
  }
}

export class Firehose {
  /**
   * @param {import("./usb.js").UsbTransport} usb
   * @param {(line: string) => void} log
   */
  constructor(usb, log = () => {}) {
    this.usb = usb;
    this.log = log;
    this.maxPayload = 1048576;
    this.text = "";
    this.decoder = new TextDecoder();
  }

  async #send(tag, attrs) {
    await this.usb.write(new TextEncoder().encode(toXml(tag, attrs)));
  }

  /**
   * Read XML documents until one carries a <response>. Device <log> lines go
   * to the log. Returns the response attributes, or null on timeout.
   */
  /** Consume buffered XML documents up to the first <response>. Null if none is complete yet. */
  #buffered() {
    for (;;) {
      const end = this.text.indexOf("</data>");
      if (end < 0) return null;
      const doc = this.text.slice(0, end);
      this.text = this.text.slice(end + "</data>".length);
      for (const m of doc.matchAll(/<log\b([^>]*)>/g)) {
        this.log(`device: ${parseAttrs(m[1]).value ?? ""}`);
      }
      const response = doc.match(/<response\b([^>]*)>/);
      if (response) return parseAttrs(response[1]);
    }
  }

  async #response(timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const response = this.#buffered();
      if (response) return response;
      const left = deadline - Date.now();
      if (left <= 0) return null;
      try {
        const data = await this.usb.read(4096, left);
        this.text += this.decoder.decode(data, { stream: true });
      } catch (e) {
        if (e instanceof TimeoutError) return null;
        throw e;
      }
    }
  }

  async #ack(what, timeoutMs) {
    const response = await this.#response(timeoutMs);
    if (!response) throw new FirehoseError(`${what}: no response from programmer`);
    if (response.value !== "ACK") throw new FirehoseError(`${what}: programmer answered ${response.value}`);
    return response;
  }

  /** Hand over bytes that another reader took off the wire but that belong to this protocol. */
  feed(bytes) {
    this.text += this.decoder.decode(bytes, { stream: true });
  }

  /** Is a programmer already running? Used when the boot ROM does not greet us. */
  async probe() {
    await this.#response(300);
    await this.#send("nop", { value: "ping" });
    return (await this.#response(2000)) !== null;
  }

  async configure() {
    // A freshly started programmer talks first; let it finish.
    await this.#response(500);
    for (let attempt = 0; attempt < 2; attempt++) {
      await this.#send("configure", {
        MemoryName: "emmc",
        MaxPayloadSizeToTargetInBytes: this.maxPayload,
        Verbose: 0,
        ZlpAwareHost: 1,
        SkipStorageInit: 0,
      });
      const response = await this.#response(5000);
      if (!response) throw new FirehoseError("configure: no response from programmer");
      const supported = Number(response.MaxPayloadSizeToTargetInBytesSupported ?? 0);
      const granted = Number(response.MaxPayloadSizeToTargetInBytes ?? 0);
      if (response.value === "ACK") {
        if (granted) this.maxPayload = granted;
        this.log(`Firehose configured, ${this.maxPayload} byte payloads`);
        return;
      }
      if (!supported || supported === this.maxPayload) break;
      this.maxPayload = supported;
    }
    throw new FirehoseError("configure: programmer refused the configuration");
  }

  /**
   * Read `numSectors` sectors starting at `startSector`, handing the data to
   * `sink` piece by piece so a whole partition never sits in memory.
   * @param {(chunk: Uint8Array) => Promise<void>|void} sink
   * @param {(bytesRead: number) => void} [onProgress]
   */
  async readStream(startSector, numSectors, sink, onProgress) {
    await this.#send("read", {
      SECTOR_SIZE_IN_BYTES: SECTOR_SIZE,
      num_partition_sectors: numSectors,
      physical_partition_number: PHYSICAL_PARTITION,
      start_sector: startSector,
    });
    const total = numSectors * SECTOR_SIZE;
    let got = 0;
    const take = async (chunk) => {
      got += chunk.length;
      await sink(chunk);
      onProgress?.(got);
    };

    // Programmers differ in how a read starts. The usual order is an ACK, then
    // the data. The PVG100 programmer has been seen (scripts/fh_dump.py) to
    // send the data straight away with no ACK in front. Accept either: XML
    // here is the ACK (or log lines), anything else is already sector data.
    let acked = false;
    while (!acked && got === 0) {
      // Never ask for more than is left, or the trailing response would be swallowed.
      const chunk = await this.usb.read(Math.min(total, 1048576), 10000);
      if (chunk.length === 0) continue;
      if (this.text.length || XML_START.every((byte, i) => chunk[i] === byte)) {
        this.text += this.decoder.decode(chunk, { stream: true });
        const response = this.#buffered();
        if (!response) continue;
        if (response.value !== "ACK") throw new FirehoseError(`read: programmer answered ${response.value}`);
        acked = true;
      } else {
        await take(chunk);
      }
    }
    while (got < total) {
      const chunk = await this.usb.read(Math.min(total - got, 1048576), 30000);
      if (chunk.length) await take(chunk);
    }
    await this.#ack("read", 10000);
  }

  /** @returns {Promise<Uint8Array>} */
  async read(startSector, numSectors) {
    const data = new Uint8Array(numSectors * SECTOR_SIZE);
    let offset = 0;
    await this.readStream(startSector, numSectors, (chunk) => {
      data.set(chunk, offset);
      offset += chunk.length;
    });
    return data;
  }

  /**
   * Write `numSectors` sectors starting at `startSector`.
   * @param {AsyncIterable<Uint8Array>} chunks whole sectors, each no larger than maxPayload
   * @param {(bytesWritten: number) => void} [onProgress]
   */
  async program(startSector, numSectors, chunks, onProgress) {
    await this.#send("program", {
      SECTOR_SIZE_IN_BYTES: SECTOR_SIZE,
      num_partition_sectors: numSectors,
      physical_partition_number: PHYSICAL_PARTITION,
      start_sector: startSector,
    });
    const begin = await this.#ack("program", 10000);
    if (begin.rawmode !== "true") throw new FirehoseError("program: programmer did not enter raw mode");

    const total = numSectors * SECTOR_SIZE;
    let written = 0;
    for await (const chunk of chunks) {
      if (chunk.length % SECTOR_SIZE || chunk.length > this.maxPayload || written + chunk.length > total) {
        throw new FirehoseError("program: bad chunk size");
      }
      await this.usb.write(chunk);
      written += chunk.length;
      onProgress?.(written);
    }
    if (written !== total) {
      throw new FirehoseError(`program: image ended after ${written} of ${total} bytes`);
    }
    await this.#ack("program", 60000);
  }

  async reset() {
    await this.#send("power", { value: "reset", DelayInSeconds: 2 });
    await this.#ack("reset", 5000);
    await this.#response(1000);
  }
}

// Sahara: the boot ROM protocol that accepts the Firehose programmer.
// Follows linux-msm/qdl's sahara.c, the tool the pepito release already uses.

import { TimeoutError } from "./usb.js";

const CMD = {
  HELLO: 0x01,
  HELLO_RESP: 0x02,
  READ_DATA: 0x03,
  END_OF_IMAGE: 0x04,
  DONE: 0x05,
  DONE_RESP: 0x06,
  READ_DATA64: 0x12,
};

const MODE_IMAGE_TX_PENDING = 0;

function words(...values) {
  const out = new Uint8Array(values.length * 4);
  const view = new DataView(out.buffer);
  values.forEach((v, i) => view.setUint32(i * 4, v, true));
  return out;
}

export class SaharaError extends Error {
  constructor(message, status) {
    super(message);
    this.name = "SaharaError";
    this.status = status;
  }
}

export class Sahara {
  /**
   * @param {import("./usb.js").UsbTransport} usb
   * @param {(line: string) => void} log
   */
  constructor(usb, log = () => {}) {
    this.usb = usb;
    this.log = log;
    this.hello = null;
    // Bytes read while looking for HELLO that turned out to be Firehose XML.
    this.stray = null;
  }

  async #packet(timeoutMs = 5000) {
    const data = await this.usb.read(4096, timeoutMs);
    if (data.length < 8) throw new SaharaError(`short Sahara packet (${data.length} bytes)`);
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    return { cmd: view.getUint32(0, true), length: view.getUint32(4, true), view, data };
  }

  /**
   * Wait for the boot ROM's HELLO. Returns false if the device stays silent,
   * which is what a device with a programmer already running looks like.
   */
  async waitHello(timeoutMs = 2000) {
    let pkt;
    try {
      pkt = await this.#packet(timeoutMs);
    } catch (e) {
      if (e instanceof TimeoutError) return false;
      throw e;
    }
    // "<?xm": a programmer is already running and talking Firehose.
    if (pkt.cmd === 0x6d783f3c) {
      this.stray = pkt.data;
      return false;
    }
    if (pkt.cmd !== CMD.HELLO || pkt.length !== 0x30) {
      throw new SaharaError(`expected Sahara HELLO, got command 0x${pkt.cmd.toString(16)}`);
    }
    this.hello = {
      version: pkt.view.getUint32(8, true),
      compatible: pkt.view.getUint32(12, true),
      mode: pkt.view.getUint32(20, true),
    };
    this.log(`Sahara HELLO: version ${this.hello.version}, mode ${this.hello.mode}`);
    return true;
  }

  async #helloResp(mode) {
    await this.usb.write(words(CMD.HELLO_RESP, 0x30, 2, 1, 0, mode, 0, 0, 0, 0, 0, 0));
  }

  /**
   * Serve the programmer to the boot ROM.
   * @param {Uint8Array} image
   */
  async upload(image) {
    await this.#helloResp(this.hello?.mode ?? MODE_IMAGE_TX_PENDING);
    for (;;) {
      const pkt = await this.#packet();
      if (pkt.cmd === CMD.READ_DATA || pkt.cmd === CMD.READ_DATA64) {
        let offset, length;
        if (pkt.cmd === CMD.READ_DATA) {
          offset = pkt.view.getUint32(12, true);
          length = pkt.view.getUint32(16, true);
        } else {
          offset = Number(pkt.view.getBigUint64(16, true));
          length = Number(pkt.view.getBigUint64(24, true));
        }
        if (offset + length > image.length) {
          throw new SaharaError(`boot ROM asked for bytes ${offset}+${length}, past the end of the programmer`);
        }
        await this.usb.write(image.subarray(offset, offset + length));
      } else if (pkt.cmd === CMD.END_OF_IMAGE) {
        const status = pkt.view.getUint32(12, true);
        if (status !== 0) {
          throw new SaharaError(`boot ROM rejected the programmer (status 0x${status.toString(16)})`, status);
        }
        await this.usb.write(words(CMD.DONE, 0x08));
      } else if (pkt.cmd === CMD.DONE_RESP) {
        this.log("Programmer accepted");
        return;
      } else {
        throw new SaharaError(`unexpected Sahara command 0x${pkt.cmd.toString(16)} during upload`);
      }
    }
  }
}

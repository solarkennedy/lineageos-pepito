// WebUSB transport for a Qualcomm device in EDL (9008) mode.

export const EDL_FILTERS = [{ vendorId: 0x05c6, productId: 0x9008 }];

export class TimeoutError extends Error {
  constructor(ms) {
    super(`no data from device within ${ms} ms`);
    this.name = "TimeoutError";
  }
}

export class UsbTransport {
  /** @param {USBDevice} device */
  constructor(device) {
    this.device = device;
    this.epIn = 0;
    this.epOut = 0;
    this.outPacketSize = 512;
    // WebUSB transfers cannot be cancelled. A read that timed out is still
    // queued in the browser and will swallow the next thing the device sends,
    // so it is kept here and handed to the next read() instead of dropped.
    this.pending = null;
  }

  async open() {
    const d = this.device;
    await d.open();
    if (!d.configuration) await d.selectConfiguration(1);
    for (const iface of d.configuration.interfaces) {
      const alt = iface.alternates[0];
      const bulkIn = alt.endpoints.find((e) => e.type === "bulk" && e.direction === "in");
      const bulkOut = alt.endpoints.find((e) => e.type === "bulk" && e.direction === "out");
      if (!bulkIn || !bulkOut) continue;
      await d.claimInterface(iface.interfaceNumber);
      this.epIn = bulkIn.endpointNumber;
      this.epOut = bulkOut.endpointNumber;
      this.outPacketSize = bulkOut.packetSize;
      return;
    }
    throw new Error("EDL device has no bulk in/out interface");
  }

  async close() {
    try {
      await this.device.close();
    } catch {
      // already gone, e.g. after a reset
    }
  }

  /**
   * One bulk IN transfer of at most maxLen bytes. Returns what arrived, which
   * may be empty (zero-length packet). Throws TimeoutError after timeoutMs.
   */
  async read(maxLen = 4096, timeoutMs = 1000) {
    if (!this.pending) {
      this.pending = this.device.transferIn(this.epIn, maxLen).then(
        (result) => ({ result }),
        (error) => ({ error }),
      );
    }
    let timer;
    const timeout = new Promise((resolve) => {
      timer = setTimeout(() => resolve(null), timeoutMs);
    });
    const settled = await Promise.race([this.pending, timeout]);
    clearTimeout(timer);
    if (!settled) throw new TimeoutError(timeoutMs);
    this.pending = null;
    if (settled.error) throw settled.error;
    const { status, data } = settled.result;
    if (status === "stall") {
      await this.device.clearHalt("in", this.epIn);
      return new Uint8Array(0);
    }
    if (!data) return new Uint8Array(0);
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  }

  /** Read exactly `length` bytes, across as many transfers as it takes. */
  async readExact(length, timeoutMs = 5000) {
    const out = new Uint8Array(length);
    let got = 0;
    while (got < length) {
      const chunk = await this.read(length - got, timeoutMs);
      if (got + chunk.length > length) throw new Error("device sent more data than requested");
      out.set(chunk, got);
      got += chunk.length;
    }
    return out;
  }

  /**
   * One logical write. Like qdl, a write that is an exact multiple of the
   * endpoint packet size is followed by a zero-length packet so the device
   * sees the end of the transfer.
   */
  async write(data) {
    const result = await this.device.transferOut(this.epOut, data);
    if (result.status !== "ok") throw new Error(`USB write failed: ${result.status}`);
    if (data.byteLength > 0 && data.byteLength % this.outPacketSize === 0) {
      await this.device.transferOut(this.epOut, new Uint8Array(0));
    }
  }
}

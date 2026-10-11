// End-to-end runs of the flasher against the pretend phone in mock-device.mjs.
// Run: node --test test/

import assert from "node:assert/strict";
import { test } from "node:test";
import zlib from "node:zlib";
import { backup, backupPlan, buildPlan, connect, flash, FlashError } from "../js/flash.js";
import { crc32 } from "../js/gpt.js";
import { LAYOUTS } from "../js/layouts.js";
import { UsbTransport } from "../js/usb.js";
import { MockPhone } from "./mock-device.mjs";

function bytes(length, seed) {
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = (i * 31 + seed) & 0xff;
  return out;
}

// Same length: the mock boot ROM asks for as many bytes as its own programmer has.
const LOADERS = { pvg100: bytes(9000, 1), pvg100e: bytes(9000, 2) };

// Sizes chosen to hit the awkward cases: not a sector multiple, an exact
// payload multiple, and larger than one payload.
const FILES = {
  "pvg100_firehose.elf": LOADERS.pvg100,
  "pvg100e_firehose.elf": LOADERS.pvg100e,
  "boot.bin": bytes(70001, 3),
  "boot-magisk.bin": bytes(70001, 4),
  "recovery.bin": bytes(65536, 5),
  "system.bin": bytes(3 * 1048576 + 700, 6),
  "vendor.bin": bytes(1048576, 7),
};

function memorySource(files = FILES) {
  return {
    has: (name) => name in files,
    size: (name) => files[name].length,
    bytes: async (name) => files[name],
    // Deliver in odd-sized pieces, as a network stream would.
    stream: async (name) =>
      new ReadableStream({
        start(controller) {
          for (let o = 0; o < files[name].length; o += 50000) controller.enqueue(files[name].subarray(o, o + 50000));
          controller.close();
        },
      }),
  };
}

async function open(phone) {
  const usb = new UsbTransport(phone);
  await usb.open();
  return usb;
}

function phoneFor(variant, extra = {}) {
  return new MockPhone({ variant, loaders: LOADERS, ...extra });
}

function partition(variant, name) {
  const [, start, sectors] = LAYOUTS[variant].find(([label]) => label === name);
  return { start, sectors };
}

function assertOnDisk(phone, variant, name, expected) {
  const { start } = partition(variant, name);
  const sectors = Math.ceil(expected.length / 512);
  const disk = phone.readDisk(start, sectors);
  assert.deepEqual(disk.subarray(0, expected.length), expected, `${name} contents`);
  assert.ok(disk.subarray(expected.length).every((b) => b === 0), `${name} tail padding`);
}

test("crc32 agrees with zlib", () => {
  const data = bytes(5000, 9);
  assert.equal(crc32(data), zlib.crc32(data));
});

for (const variant of ["pvg100", "pvg100e"]) {
  test(`${variant}: writes each image to that variant's offsets`, async () => {
    const phone = phoneFor(variant);
    const source = memorySource();
    const session = await connect(await open(phone), source, { variant });
    assert.equal(session.variant, variant);
    assert.equal(phone.writes.length, 0, "connect must not write");

    const plan = buildPlan(session, source);
    const seen = [];
    await flash(session, plan, source, (p) => seen.push(p));

    assertOnDisk(phone, variant, "boot", FILES["boot.bin"]);
    assertOnDisk(phone, variant, "recovery", FILES["recovery.bin"]);
    assertOnDisk(phone, variant, "system", FILES["system.bin"]);
    assertOnDisk(phone, variant, "vendor", FILES["vendor.bin"]);
    assert.deepEqual(
      phone.writes.map(([start]) => start),
      ["boot", "recovery", "system", "vendor", "config"].map((n) => partition(variant, n).start),
    );
    const config = partition(variant, "config");
    assert.deepEqual(phone.writes.at(-1), [config.start, config.sectors]);
    assert.equal(seen.at(-1).written, seen.at(-1).total);

    await session.firehose.reset();
    assert.ok(phone.wasReset);
  });
}

test("root option swaps in the Magisk boot image", async () => {
  const phone = phoneFor("pvg100");
  const source = memorySource();
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  await flash(session, buildPlan(session, source, { root: true }), source);
  assertOnDisk(phone, "pvg100", "boot", FILES["boot-magisk.bin"]);
});

test("no variant chosen is refused before talking to the phone", async () => {
  const phone = phoneFor("pvg100");
  await assert.rejects(connect(await open(phone), memorySource(), {}), /Choose PVG100 or PVG100E/);
});

test("wrong variant chosen: the boot ROM rejects the programmer, nothing is written", async () => {
  const phone = phoneFor("pvg100e");
  await assert.rejects(
    connect(await open(phone), memorySource(), { variant: "pvg100" }),
    (e) => e instanceof FlashError && /rejected the PVG100 programmer/.test(e.message),
  );
  assert.equal(phone.writes.length, 0);
});

test("a partition table that matches neither layout is refused", async () => {
  const layout = LAYOUTS.pvg100.map(([name, start, sectors]) => [name, name === "system" ? start + 8 : start, sectors]);
  const phone = phoneFor("pvg100", { layout });
  await assert.rejects(connect(await open(phone), memorySource(), { variant: "pvg100" }), /matches no known Palm layout/);
  assert.equal(phone.writes.length, 0);
});

test("a partition table of the other variant is refused", async () => {
  // A PVG100 boot ROM in front of a PVG100E-shaped disk.
  const phone = phoneFor("pvg100", { layout: LAYOUTS.pvg100e });
  await assert.rejects(
    connect(await open(phone), memorySource(), { variant: "pvg100" }),
    /partition table is a PVG100E layout/,
  );
  assert.equal(phone.writes.length, 0);
});

test("resumes when a programmer is already running", async () => {
  const phone = phoneFor("pvg100e", { inFirehose: true });
  const source = memorySource();
  const session = await connect(await open(phone), source, { variant: "pvg100e" });
  await flash(session, buildPlan(session, source), source);
  assertOnDisk(phone, "pvg100e", "system", FILES["system.bin"]);
});

test("resuming with the wrong variant chosen is refused by the partition table check", async () => {
  const phone = phoneFor("pvg100e", { inFirehose: true });
  await assert.rejects(
    connect(await open(phone), memorySource(), { variant: "pvg100" }),
    /partition table is a PVG100E layout/,
  );
  assert.equal(phone.writes.length, 0);
});

test("falls back to the payload size the programmer supports", async () => {
  const phone = phoneFor("pvg100", { maxPayload: 16384 });
  const source = memorySource();
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  assert.equal(session.firehose.maxPayload, 16384);
  await flash(session, buildPlan(session, source), source);
  assertOnDisk(phone, "pvg100", "system", FILES["system.bin"]);
});

test("an image too large for its partition is refused at planning", async () => {
  const phone = phoneFor("pvg100");
  const big = { ...FILES, "recovery.bin": { length: 131072 * 512 + 1 } };
  const source = memorySource(big);
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  assert.throws(() => buildPlan(session, source), /does not fit in recovery/);
});

test("a build missing an image is refused at planning", async () => {
  const phone = phoneFor("pvg100");
  const { "vendor.bin": _dropped, ...partial } = FILES;
  const source = memorySource(partial);
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  assert.throws(() => buildPlan(session, source), /no vendor.bin/);
});

test("backup reads partitions back byte-for-byte and writes a restore manifest", async () => {
  const phone = phoneFor("pvg100");
  const source = memorySource();
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  await flash(session, buildPlan(session, source), source);
  const writesBefore = phone.writes.length;

  const full = backupPlan(session);
  assert.equal(full[0].file, "gpt-lun0.bin");
  assert.ok(!full.some((step) => step.name === "userdata"), "userdata is left out by default");
  assert.equal(full.length, LAYOUTS.pvg100.length); // every partition but userdata, plus the GPT

  // The mock holds whole reads in memory, so keep to the small partitions.
  const plan = full.filter((step) => ["PrimaryGPT", "modemst1", "boot", "config"].includes(step.name));
  const files = {};
  const createFile = async (name) => {
    const parts = [];
    return {
      write: async (data) => void parts.push(typeof data === "string" ? new TextEncoder().encode(data) : data.slice()),
      close: async () => void (files[name] = Buffer.concat(parts)),
    };
  };
  const seen = [];
  await backup(session, plan, createFile, (p) => seen.push(p));

  assert.equal(phone.writes.length, writesBefore, "backup must not write to the phone");
  const boot = partition("pvg100", "boot");
  assert.equal(files["boot.bin"].length, boot.sectors * 512);
  assert.deepEqual(new Uint8Array(files["boot.bin"]), phone.readDisk(boot.start, boot.sectors));
  assert.deepEqual(new Uint8Array(files["boot.bin"].subarray(0, 70001)), FILES["boot.bin"]);
  assert.deepEqual(new Uint8Array(files["gpt-lun0.bin"]), phone.readDisk(0, 34));
  assert.equal(seen.at(-1).read, seen.at(-1).total);

  const manifest = files["rawprogram_restore.xml"].toString();
  assert.match(manifest, new RegExp(`filename="boot.bin" label="boot" num_partition_sectors="${boot.sectors}" physical_partition_number="0" start_sector="${boot.start}"`));
  assert.doesNotMatch(manifest, /gpt-lun0/);
});

test("copes with a programmer that sends read data before any ACK", async () => {
  const phone = phoneFor("pvg100", { readDataFirst: true });
  const source = memorySource();
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  await flash(session, buildPlan(session, source), source);
  const boot = partition("pvg100", "boot");
  const data = await session.firehose.read(boot.start, 200);
  assert.deepEqual(data, phone.readDisk(boot.start, 200));
});

test("a missing loader is refused before the phone is touched, so a retry still works", async () => {
  const phone = phoneFor("pvg100");
  const usb = await open(phone);
  await assert.rejects(connect(usb, { bytes: async () => undefined }, { variant: "pvg100" }), /No pvg100_firehose.elf available/);
  const session = await connect(usb, memorySource(), { variant: "pvg100" });
  assert.equal(session.variant, "pvg100");
});

test("resumes when the running programmer speaks before we do", async () => {
  const phone = phoneFor("pvg100", { inFirehose: true, chatty: true });
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  assert.equal(session.variant, "pvg100");
});

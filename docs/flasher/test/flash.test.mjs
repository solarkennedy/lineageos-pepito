// End-to-end runs of the flasher against the pretend phone in mock-device.mjs.
// Run: node --test test/

import assert from "node:assert/strict";
import { test } from "node:test";
import zlib from "node:zlib";
import { backup, backupPlan, buildPlan, connect, flash, FlashError, imagePlan, PER_PHONE, restorePlan } from "../js/flash.js";
import { crc32 } from "../js/gpt.js";
import { LAYOUTS } from "../js/layouts.js";
import { PARTITION_GROUPS } from "../js/partitions.js";
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
    // Size-only stand-ins have no bytes; they read as zeros.
    head: async (name, length) => files[name].subarray?.(0, length) ?? new Uint8Array(length),
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

test("the boot logo is written when the build has one, and skipped when not", async () => {
  const splash = bytes(131072, 8);
  const phone = phoneFor("pvg100");
  const source = memorySource({ ...FILES, "splash.bin": splash });
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  const plan = buildPlan(session, source);
  assert.deepEqual(plan.map((step) => step.partition), ["boot", "recovery", "system", "vendor", "splash", "config"]);
  const step = plan.find((s) => s.partition === "splash");
  assert.equal(step.sectors, 256, "only the image's own sectors, not the whole partition");
  await flash(session, plan, source);
  assertOnDisk(phone, "pvg100", "splash", splash);

  const without = buildPlan(session, memorySource());
  assert.ok(!without.some((s) => s.partition === "splash"));
});

test("root option swaps in the Magisk boot image", async () => {
  const phone = phoneFor("pvg100");
  const source = memorySource();
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  await flash(session, buildPlan(session, source, { root: true }), source);
  assertOnDisk(phone, "pvg100", "boot", FILES["boot-magisk.bin"]);
});

test("a build may name its images .img", async () => {
  const phone = phoneFor("pvg100");
  const { "boot.bin": boot, "system.bin": system, ...rest } = FILES;
  const source = memorySource({ ...rest, "boot.img": boot, "system.img": system });
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  const plan = buildPlan(session, source);
  assert.deepEqual(plan.map((step) => step.file), ["boot.img", "recovery.bin", "system.img", "vendor.bin", null]);
  await flash(session, plan, source);
  assertOnDisk(phone, "pvg100", "boot", FILES["boot.bin"]);
  assertOnDisk(phone, "pvg100", "system", FILES["system.bin"]);
});

test("a build with both boot.bin and boot.img is refused at planning", async () => {
  const phone = phoneFor("pvg100");
  const source = memorySource({ ...FILES, "boot.img": FILES["boot.bin"] });
  const session = await connect(await open(phone), source, { variant: "pvg100" });
  assert.throws(() => buildPlan(session, source), /both boot.bin and boot.img/);
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

// --- restore ------------------------------------------------------------------

/** A phone whose factory record holds `seed`, as every real unit's differs. */
function phoneWithIdentity(variant, seed) {
  const phone = phoneFor(variant);
  phone.writeDisk(partition(variant, "traceability").start, bytes(4096, seed));
  return phone;
}

/**
 * The backup folder a phone would produce. Only the files a test actually
 * restores carry data; the rest are stand-ins of the right size.
 */
function backupOf(phone, variant, overrides = {}) {
  const files = { "gpt-lun0.bin": phone.readDisk(0, 34) };
  for (const [name, start, sectors] of LAYOUTS[variant]) {
    if (name === "userdata") continue;
    files[`${name}.bin`] = ["traceability", "modemst1", "sec", "config"].includes(name)
      ? phone.readDisk(start, sectors)
      : { length: sectors * 512 };
  }
  return memorySource({ ...files, ...overrides });
}

const actions = (rows) => Object.fromEntries(rows.map((row) => [row.partition, row.action]));
const writes = (rows) => rows.filter((row) => row.action === "write");

test("restore of a whole backup of the same phone writes every partition but userdata", async () => {
  const phone = phoneWithIdentity("pvg100", 11);
  const modemst1 = partition("pvg100", "modemst1");
  phone.writeDisk(modemst1.start, bytes(modemst1.sectors * 512, 12));
  const source = backupOf(phone, "pvg100");
  // What the phone holds now differs from the backup, as it would after flashing.
  phone.writeDisk(modemst1.start, bytes(modemst1.sectors * 512, 13));

  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const rows = await restorePlan(session, source);
  assert.equal(phone.writes.length, 0, "planning must not write");
  assert.equal(rows.length, LAYOUTS.pvg100.length, "one row per partition");
  assert.equal(writes(rows).length, LAYOUTS.pvg100.length - 1);
  assert.equal(actions(rows).userdata, "never");
  assert.equal(actions(rows).modemst1, "write");

  const small = writes(rows).filter((row) => ["modemst1", "sec", "config"].includes(row.partition));
  await flash(session, small, source);
  assert.deepEqual(phone.readDisk(modemst1.start, modemst1.sectors), bytes(modemst1.sectors * 512, 12));
});

test("restore of a folder with only boot.bin writes just boot", async () => {
  const phone = phoneFor("pvg100");
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const source = memorySource({ "boot.bin": FILES["boot.bin"] });
  const rows = await restorePlan(session, source);
  assert.deepEqual(writes(rows).map((row) => row.partition), ["boot"]);
  assert.equal(actions(rows).system, "no-file");

  await flash(session, writes(rows), source);
  assertOnDisk(phone, "pvg100", "boot", FILES["boot.bin"]);
  assert.equal(phone.writes.length, 1);
});

test("restore takes .img files as well as .bin, but not both for one partition", async () => {
  const phone = phoneWithIdentity("pvg100", 61);
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const traceability = partition("pvg100", "traceability");
  const source = memorySource({
    "boot.img": FILES["boot.bin"],
    "recovery.bin": FILES["recovery.bin"],
    // A firmware package's name for the factory record still proves the folder's origin.
    "traceability.img": phone.readDisk(traceability.start, traceability.sectors),
    "modemst1.img": bytes(partition("pvg100", "modemst1").sectors * 512, 62),
  });
  const rows = await restorePlan(session, source);
  assert.deepEqual(
    writes(rows).map((row) => [row.partition, row.file]),
    [
      ["modemst1", "modemst1.img"],
      ["traceability", "traceability.img"],
      ["boot", "boot.img"],
      ["recovery", "recovery.bin"],
    ].sort((a, b) => partition("pvg100", a[0]).start - partition("pvg100", b[0]).start),
  );
  await flash(session, writes(rows).filter((row) => row.partition === "boot"), source);
  assertOnDisk(phone, "pvg100", "boot", FILES["boot.bin"]);

  const both = memorySource({ "boot.img": FILES["boot.bin"], "boot.bin": FILES["boot.bin"] });
  await assert.rejects(restorePlan(session, both), /both boot.bin and boot.img/);
});

test("restore skips per-phone partitions when nothing proves the folder is from this phone", async () => {
  const phone = phoneWithIdentity("pvg100", 51);
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const modemst1 = partition("pvg100", "modemst1");
  const rows = await restorePlan(
    session,
    memorySource({ "boot.bin": FILES["boot.bin"], "modemst1.bin": bytes(modemst1.sectors * 512, 52) }),
  );
  assert.equal(actions(rows).modemst1, "unverified");
  assert.deepEqual(writes(rows).map((row) => row.partition), ["boot"]);

  // A blank factory record proves nothing either.
  const blank = await restorePlan(
    session,
    memorySource({ "modemst1.bin": bytes(modemst1.sectors * 512, 52), "traceability.bin": new Uint8Array(1048576) }),
  );
  assert.equal(actions(blank).modemst1, "unverified");
  assert.equal(actions(blank).traceability, "unverified");
});

test("restore refuses a backup of a different phone", async () => {
  const source = backupOf(phoneWithIdentity("pvg100", 21), "pvg100");
  const phone = phoneWithIdentity("pvg100", 22);
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  await assert.rejects(restorePlan(session, source), /backup of a different phone/);
  assert.equal(phone.writes.length, 0);
});

test("restore refuses a backup of the other model", async () => {
  const source = backupOf(phoneWithIdentity("pvg100e", 31), "pvg100e");
  const phone = phoneWithIdentity("pvg100", 31);
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  await assert.rejects(restorePlan(session, source), /another phone or model/);
  assert.equal(phone.writes.length, 0);
});

test("restore refuses an image too large, empty or sparse", async () => {
  const phone = phoneFor("pvg100");
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const big = memorySource({ "recovery.bin": { length: 131072 * 512 + 1 } });
  await assert.rejects(restorePlan(session, big), /does not fit in recovery/);
  await assert.rejects(restorePlan(session, memorySource({ "boot.bin": new Uint8Array(0) })), /boot.bin is empty/);
  const sparse = memorySource({ "system.bin": Uint8Array.of(0x3a, 0xff, 0x26, 0xed, 0, 0, 0, 0) });
  await assert.rejects(restorePlan(session, sparse), /system.bin is an Android sparse image/);
  assert.equal(phone.writes.length, 0);
});

test("restore of a folder with no matching files writes nothing", async () => {
  const phone = phoneFor("pvg100");
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const rows = await restorePlan(session, memorySource({ "notes.bin": bytes(10, 1) }));
  assert.equal(writes(rows).length, 0);
});

// --- advanced -----------------------------------------------------------------

test("one image goes to the partition picked for it, whatever its name", async () => {
  const phone = phoneFor("pvg100");
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const source = memorySource({ "my-recovery.img": FILES["recovery.bin"] });
  const plan = await imagePlan(session, source, "my-recovery.img", "recovery");
  assert.equal(phone.writes.length, 0, "planning must not write");
  await flash(session, plan, source);
  assertOnDisk(phone, "pvg100", "recovery", FILES["recovery.bin"]);
  assert.equal(phone.writes.length, 1);
});

test("one image is refused when it does not fit, is empty, is sparse or names no partition", async () => {
  const phone = phoneFor("pvg100");
  const session = await connect(await open(phone), memorySource(), { variant: "pvg100" });
  const source = memorySource({
    "big.img": { length: 64 * 512 + 1 },
    "empty.img": new Uint8Array(0),
    "sparse.img": Uint8Array.of(0x3a, 0xff, 0x26, 0xed, 0, 0, 0, 0),
  });
  await assert.rejects(imagePlan(session, source, "big.img", "config"), /does not fit in config/);
  await assert.rejects(imagePlan(session, source, "empty.img", "config"), /is empty/);
  await assert.rejects(imagePlan(session, source, "sparse.img", "system"), /sparse image/);
  await assert.rejects(imagePlan(session, source, "sparse.img", "nonesuch"), /No nonesuch partition/);
  assert.equal(phone.writes.length, 0);
});

// --- partitions tab -----------------------------------------------------------

test("every partition of both models is described, once", () => {
  const described = PARTITION_GROUPS.flatMap((group) => group.partitions.map(([name]) => name));
  assert.equal(new Set(described).size, described.length, "no partition described twice");
  const inLayouts = new Set([...LAYOUTS.pvg100, ...LAYOUTS.pvg100e].map(([name]) => name));
  assert.deepEqual([...inLayouts].filter((name) => !described.includes(name)), [], "undescribed partitions");
  assert.deepEqual(described.filter((name) => !inLayouts.has(name)), [], "described partitions no layout has");
});

test("the partitions restore treats as per-phone are the ones the Partitions tab calls unique", () => {
  const unique = PARTITION_GROUPS.flatMap((group) => group.partitions)
    .filter(([, , uniqueness]) => uniqueness.startsWith("unit"))
    .map(([name]) => name);
  assert.deepEqual([...unique].sort(), [...PER_PHONE].sort());
});

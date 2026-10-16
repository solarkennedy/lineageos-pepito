// The flashing procedure, free of any UI so it can be driven by tests.

import { IMAGE_EXTENSIONS, VARIANTS, WRITES } from "./device.js";
import { Firehose, SECTOR_SIZE } from "./firehose.js";
import { readGpt } from "./gpt.js";
import { LAYOUTS } from "./layouts.js";
import { Sahara, SaharaError } from "./sahara.js";

export class FlashError extends Error {
  constructor(message) {
    super(message);
    this.name = "FlashError";
  }
}

/**
 * Compare a GPT with a known layout. Every partition must sit exactly where
 * the layout says. The last one (userdata) only has to start there, since its
 * length follows the size of the eMMC.
 */
function layoutProblems(gpt, layout) {
  const byName = new Map(gpt.partitions.map((p) => [p.name, p]));
  const problems = [];
  layout.forEach(([name, start, sectors], i) => {
    const part = byName.get(name);
    if (!part) problems.push(`${name} missing`);
    else if (part.start !== start) problems.push(`${name} at sector ${part.start}, expected ${start}`);
    else if (i < layout.length - 1 && part.sectors !== sectors) {
      problems.push(`${name} is ${part.sectors} sectors, expected ${sectors}`);
    }
  });
  return problems;
}

/**
 * The file in `source` that holds an image: `<image>.bin` or `<image>.img`.
 * Undefined if it has neither. Both at once is refused rather than guessed at.
 */
export function imageFile(source, image) {
  const found = IMAGE_EXTENSIONS.map((ext) => image + ext).filter((file) => source.has(file));
  if (found.length > 1) throw new FlashError(`The folder has both ${found.join(" and ")}; keep one. Nothing was written.`);
  return found[0];
}

export function matchLayout(gpt) {
  const report = {};
  for (const [variant, layout] of Object.entries(LAYOUTS)) {
    report[variant] = layoutProblems(gpt, layout);
    if (report[variant].length === 0) return { variant, report };
  }
  return { variant: null, report };
}

/**
 * Bring a phone in EDL mode up to a running programmer and confirm it is the
 * variant the user chose. Reads only; nothing is written to the phone's storage.
 *
 * @param {import("./usb.js").UsbTransport} usb
 * @param {{bytes(name: string): Promise<Uint8Array|undefined>}} loaders where the model's Firehose loader comes from
 * @param {{variant: string, log?: (line: string) => void}} options
 */
export async function connect(usb, loaders, { variant, log = () => {} }) {
  if (!VARIANTS[variant]) throw new FlashError("Choose PVG100 or PVG100E first.");
  // Fetch the loader before answering the boot ROM: once its greeting has been
  // read it will not repeat it, so failing here must leave the phone untouched.
  const loader = VARIANTS[variant].loader;
  const image = await loaders.bytes(loader);
  if (!image) throw new FlashError(`No ${loader} available`);
  const sahara = new Sahara(usb, log);
  const firehose = new Firehose(usb, log);

  if (await sahara.waitHello()) {
    log(`Phone is in EDL mode. Sending ${loader}`);
    try {
      await sahara.upload(image);
    } catch (e) {
      if (e instanceof SaharaError && e.status !== undefined) {
        throw new FlashError(
          `The phone rejected the ${VARIANTS[variant].name} programmer. Check the model on the back of the phone. ` +
            "Then hold power for about 15 seconds, re-enter EDL mode and try again.",
        );
      }
      throw e;
    }
  } else {
    if (sahara.stray) firehose.feed(sahara.stray);
    if (!(await firehose.probe())) {
      throw new FlashError("The phone is not answering. Hold power for about 15 seconds, re-enter EDL mode and try again.");
    }
    log("A programmer is already running on the phone");
  }

  await firehose.configure();
  const gpt = await readGpt((start, count) => firehose.read(start, count));
  const layout = matchLayout(gpt);
  if (!layout.variant) {
    const detail = Object.entries(layout.report)
      .map(([v, problems]) => `vs ${VARIANTS[v].name}: ${problems.slice(0, 3).join("; ")}`)
      .join(" | ");
    throw new FlashError(`This phone's partition table matches no known Palm layout, so nothing was written. ${detail}`);
  }
  if (layout.variant !== variant) {
    throw new FlashError(
      `You chose ${VARIANTS[variant].name} but the partition table is a ${VARIANTS[layout.variant].name} layout. Nothing was written.`,
    );
  }
  log(`Partition table is a ${VARIANTS[variant].name} layout (${gpt.partitions.length} partitions)`);
  return { variant, firehose, gpt };
}

/**
 * Decide what gets written where. Offsets come from the phone's own GPT.
 * @returns {{partition: string, file: string|null, start: number, sectors: number, bytes: number}[]}
 */
export function buildPlan(session, source, { root = false } = {}) {
  return WRITES.filter((write) => !write.optional || imageFile(source, write.image)).map((write) => {
    const part = session.gpt.partitions.find((p) => p.name === write.partition);
    if (!part) throw new FlashError(`No ${write.partition} partition on this phone`);
    const capacity = part.sectors * SECTOR_SIZE;
    if (write.zero) {
      return { partition: write.partition, file: null, start: part.start, sectors: part.sectors, bytes: capacity };
    }
    const image = root && write.rootImage ? write.rootImage : write.image;
    const file = imageFile(source, image);
    if (!file) throw new FlashError(`The build has no ${image}.bin or ${image}.img`);
    const bytes = source.size(file);
    if (bytes > capacity) {
      throw new FlashError(`${file} (${bytes} bytes) does not fit in ${write.partition} (${capacity} bytes)`);
    }
    return { partition: write.partition, file, start: part.start, sectors: Math.ceil(bytes / SECTOR_SIZE), bytes };
  });
}

/** Cut a byte stream into payload-sized chunks, zero-padding the tail to a whole sector. */
async function* chunked(stream, chunkSize) {
  const reader = stream.getReader();
  let chunk = new Uint8Array(chunkSize);
  let fill = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    let offset = 0;
    while (offset < value.length) {
      const take = Math.min(chunkSize - fill, value.length - offset);
      chunk.set(value.subarray(offset, offset + take), fill);
      fill += take;
      offset += take;
      if (fill === chunkSize) {
        yield chunk;
        chunk = new Uint8Array(chunkSize);
        fill = 0;
      }
    }
  }
  if (fill) yield chunk.subarray(0, Math.ceil(fill / SECTOR_SIZE) * SECTOR_SIZE);
}

async function* zeros(bytes, chunkSize) {
  for (let left = bytes; left > 0; left -= chunkSize) yield new Uint8Array(Math.min(left, chunkSize));
}

/**
 * Write the plan to the phone.
 * @param {(progress: {step: number, partition: string, written: number, total: number}) => void} [onProgress]
 */
export async function flash(session, plan, source, onProgress = () => {}) {
  const { firehose } = session;
  const chunkSize = Math.floor(firehose.maxPayload / SECTOR_SIZE) * SECTOR_SIZE;
  const total = plan.reduce((sum, step) => sum + step.sectors * SECTOR_SIZE, 0);
  let before = 0;
  for (const [i, step] of plan.entries()) {
    const chunks = step.file ? chunked(await source.stream(step.file), chunkSize) : zeros(step.bytes, chunkSize);
    await firehose.program(step.start, step.sectors, chunks, (written) => {
      onProgress({ step: i, partition: step.partition, written: before + written, total });
    });
    before += step.sectors * SECTOR_SIZE;
  }
}

const GPT_SECTORS = 34; // protective MBR, GPT header, 32 sectors of entries

/**
 * Decide what a backup reads: every partition except the excluded ones. The
 * default leaves out userdata, which is most of the disk and holds nothing a
 * reinstall needs.
 * @returns {{name: string, file: string, start: number, sectors: number}[]}
 */
export function backupPlan(session, { exclude = ["userdata"] } = {}) {
  return [
    { name: "PrimaryGPT", file: "gpt-lun0.bin", start: 0, sectors: GPT_SECTORS },
    ...session.gpt.partitions
      .filter((p) => !exclude.includes(p.name))
      .map((p) => ({ name: p.name, file: `${p.name}.bin`, start: p.start, sectors: p.sectors })),
  ];
}

/** A manifest that linux-msm qdl can flash to put the backup back. Same shape as scripts/qdl-dump.sh writes. */
export function restoreManifest(plan) {
  const lines = plan
    .filter((step) => step.name !== "PrimaryGPT")
    .map(
      (step) =>
        `  <program SECTOR_SIZE_IN_BYTES="${SECTOR_SIZE}" filename="${step.file}" label="${step.name}" ` +
        `num_partition_sectors="${step.sectors}" physical_partition_number="0" start_sector="${step.start}"/>`,
    );
  return `<?xml version="1.0" ?>\n<data>\n${lines.join("\n")}\n</data>\n`;
}

// The phone's factory record: serial numbers and model, written at the factory
// and never since. Every unit seen so far has its own, and it survives
// flashing, so it tells one phone from another.
const IDENTITY_PARTITION = "traceability";

// Partitions that belong to one phone: the factory record, the modem's
// identity, calibration and keys, sensor calibration, memory training. A
// restore writes them only from a folder proven to come from this phone. The
// Partitions tab marks the same ones unique (js/partitions.js); a test keeps
// the two in step.
export const PER_PHONE = ["traceability", "modemst1", "modemst2", "fsg", "ssd", "persist", "tunning", "simlock", "DDR"];

// Android sparse images start with this magic. Written as-is they would
// produce a corrupt partition.
const SPARSE_MAGIC = [0x3a, 0xff, 0x26, 0xed];

export const isSparse = (head) => SPARSE_MAGIC.every((byte, i) => head[i] === byte);

function list(names) {
  return names.length > 4 ? `${names.slice(0, 4).join(", ")} and ${names.length - 4} more` : names.join(", ");
}

/**
 * Match a folder of partition images against the connected phone. Each
 * `<partition>.bin` or `<partition>.img` goes to the partition it is named after, at the offset in
 * the phone's own partition table; partitions with no file are left alone, and
 * userdata is never written. Reads from the phone; writes nothing.
 *
 * A folder that is another phone's backup is refused outright: its
 * gpt-lun0.bin or traceability.bin, when present, must match this phone.
 * Per-phone partitions are written only when traceability.bin proves the
 * folder came from this phone, and skipped otherwise.
 *
 * Each row's action is "write", "no-file", "unverified" (a per-phone partition
 * without that proof) or "never" (userdata).
 * @returns {Promise<{partition: string, file: string, start: number, sectors: number, bytes: number, action: string}[]>}
 */
export async function restorePlan(session, source) {
  const phone = session.gpt.partitions;

  const files = new Map(phone.map((p) => [p.name, imageFile(source, p.name)]));

  if (source.has("gpt-lun0.bin")) {
    const table = await source.bytes("gpt-lun0.bin");
    let gpt;
    try {
      gpt = await readGpt(async (start, count) => table.subarray(start * SECTOR_SIZE, (start + count) * SECTOR_SIZE));
    } catch (e) {
      throw new FlashError(`The folder's gpt-lun0.bin is damaged (${e.message}). Nothing was written.`);
    }
    const sameTable =
      gpt.partitions.length === phone.length &&
      gpt.partitions.every((p, i) => p.name === phone[i].name && p.start === phone[i].start && p.sectors === phone[i].sectors);
    if (!sameTable) {
      throw new FlashError(
        "The folder's gpt-lun0.bin differs from this phone's partition table, so it is a backup of another phone or model. Nothing was written.",
      );
    }
  }

  let verified = false;
  const identity = phone.find((p) => p.name === IDENTITY_PARTITION);
  if (identity && files.get(IDENTITY_PARTITION)) {
    const saved = await source.bytes(files.get(IDENTITY_PARTITION));
    // A blank record proves nothing either way, so per-phone partitions stay skipped.
    if (saved.some((byte) => byte !== 0)) {
      const current = await session.firehose.read(identity.start, identity.sectors);
      if (saved.length !== current.length || saved.some((byte, i) => byte !== current[i])) {
        throw new FlashError(
          `The folder's ${files.get(IDENTITY_PARTITION)} does not match this phone's factory record, so it is a backup of a different phone. ` +
            "Restoring it would copy that phone's identity and radio calibration onto this one. Nothing was written.",
        );
      }
      verified = true;
    }
  }

  const rows = phone.map((p) => {
    const file = files.get(p.name);
    const row = { partition: p.name, file, start: p.start, sectors: p.sectors, bytes: 0 };
    if (p.name === "userdata") return { ...row, action: "never" };
    if (!file) return { ...row, action: "no-file" };
    const bytes = source.size(file);
    if (PER_PHONE.includes(p.name) && !verified) return { ...row, bytes, action: "unverified" };
    const capacity = p.sectors * SECTOR_SIZE;
    if (bytes === 0) throw new FlashError(`${file} is empty. Nothing was written.`);
    if (bytes > capacity) {
      throw new FlashError(`${file} (${bytes} bytes) does not fit in ${p.name} (${capacity} bytes). Nothing was written.`);
    }
    return { ...row, bytes, sectors: Math.ceil(bytes / SECTOR_SIZE), action: "write" };
  });

  const sparse = [];
  for (const row of rows.filter((r) => r.action === "write")) {
    if (isSparse(await source.head(row.file, 4))) sparse.push(row.file);
  }
  if (sparse.length) {
    throw new FlashError(
      `${list(sparse)} is an Android sparse image, which this page cannot write. Convert it to a raw image with simg2img first. Nothing was written.`,
    );
  }
  return rows;
}

/**
 * Plan writing one image to one partition the user picked. Checks only that
 * the partition exists and the image is raw, not empty and fits; which
 * partition an image belongs in is the user's call.
 * @returns {Promise<{partition: string, file: string, start: number, sectors: number, bytes: number}[]>}
 */
export async function imagePlan(session, source, file, partitionName) {
  const part = session.gpt.partitions.find((p) => p.name === partitionName);
  if (!part) throw new FlashError(`No ${partitionName} partition on this phone`);
  const bytes = source.size(file);
  const capacity = part.sectors * SECTOR_SIZE;
  if (bytes === 0) throw new FlashError(`${file} is empty.`);
  if (bytes > capacity) throw new FlashError(`${file} (${bytes} bytes) does not fit in ${part.name} (${capacity} bytes).`);
  if (isSparse(await source.head(file, 4))) {
    throw new FlashError(`${file} is an Android sparse image, which this page cannot write. Convert it to a raw image with simg2img first.`);
  }
  return [{ partition: part.name, file, start: part.start, sectors: Math.ceil(bytes / SECTOR_SIZE), bytes }];
}

/**
 * Read the plan off the phone into files. Reads only.
 * @param {(name: string) => Promise<{write(data: Uint8Array|string): Promise<void>, close(): Promise<void>}>} createFile
 * @param {(progress: {name: string, read: number, total: number}) => void} [onProgress]
 */
export async function backup(session, plan, createFile, onProgress = () => {}) {
  const total = plan.reduce((sum, step) => sum + step.sectors * SECTOR_SIZE, 0);
  let before = 0;
  for (const step of plan) {
    const file = await createFile(step.file);
    await session.firehose.readStream(
      step.start,
      step.sectors,
      (chunk) => file.write(chunk),
      (read) => onProgress({ name: step.name, read: before + read, total }),
    );
    await file.close();
    before += step.sectors * SECTOR_SIZE;
  }
  const manifest = await createFile("rawprogram_restore.xml");
  await manifest.write(restoreManifest(plan));
  await manifest.close();
}

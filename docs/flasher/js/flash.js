// The flashing procedure, free of any UI so it can be driven by tests.

import { VARIANTS, WRITES } from "./device.js";
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
  return WRITES.map((write) => {
    const part = session.gpt.partitions.find((p) => p.name === write.partition);
    if (!part) throw new FlashError(`No ${write.partition} partition on this phone`);
    const capacity = part.sectors * SECTOR_SIZE;
    if (write.zero) {
      return { partition: write.partition, file: null, start: part.start, sectors: part.sectors, bytes: capacity };
    }
    const file = root && write.rootFile ? write.rootFile : write.file;
    if (!source.has(file)) throw new FlashError(`The build has no ${file}`);
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

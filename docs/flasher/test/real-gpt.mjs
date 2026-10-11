// Check the GPT parser and layout matcher against real gpt_main0.bin dumps.
// Usage: node test/real-gpt.mjs <gpt_main0.bin>...
import { readFileSync } from "node:fs";
import { matchLayout } from "../js/flash.js";
import { readGpt } from "../js/gpt.js";

let failed = false;
for (const path of process.argv.slice(2)) {
  const disk = readFileSync(path);
  try {
    const gpt = await readGpt(async (start, count) => new Uint8Array(disk.subarray(start * 512, (start + count) * 512)));
    const { variant, report } = matchLayout(gpt);
    console.log(`${variant ?? "NO MATCH"}\t${gpt.partitions.length} parts\tlastLba ${gpt.lastLba}\t${path}`);
    if (!variant) {
      failed = true;
      for (const [v, problems] of Object.entries(report)) console.log(`   vs ${v}: ${problems.slice(0, 4).join("; ")}`);
    }
  } catch (e) {
    failed = true;
    console.log(`ERROR ${e.message}\t${path}`);
  }
}
process.exit(failed ? 1 : 0);

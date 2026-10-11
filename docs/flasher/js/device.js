// What this flasher knows about the Palm PVG100 family.

// The two hardware variants take the same OS images. They differ in the signed
// Firehose programmer the boot ROM will accept and in partition layout.
export const VARIANTS = {
  pvg100: { name: "PVG100", loader: "pvg100_firehose.elf" },
  pvg100e: { name: "PVG100E", loader: "pvg100e_firehose.elf" },
};

// The only partitions this flasher will ever write, in order. Nothing in a
// build directory can add to this list.
export const WRITES = [
  { partition: "boot", file: "boot.bin", rootFile: "boot-magisk.bin" },
  { partition: "recovery", file: "recovery.bin" },
  { partition: "system", file: "system.bin" },
  { partition: "vendor", file: "vendor.bin" },
  // Zero-filled so factory reset protection state cannot outlive the install.
  { partition: "config", zero: true },
];

export const BUILD_FILES = [
  ...Object.values(VARIANTS).map((v) => v.loader),
  ...WRITES.flatMap((w) => [w.file, w.rootFile]).filter(Boolean),
];

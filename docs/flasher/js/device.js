// What this flasher knows about the Palm PVG100 family.

// The two hardware variants take the same OS images. They differ in the signed
// Firehose programmer the boot ROM will accept and in partition layout.
export const VARIANTS = {
  pvg100: { name: "PVG100", loader: "pvg100_firehose.elf" },
  pvg100e: { name: "PVG100E", loader: "pvg100e_firehose.elf" },
};

// The only partitions this flasher will ever write, in order. Nothing in a
// build directory can add to this list.
// Images are named without an extension: see IMAGE_EXTENSIONS.
export const WRITES = [
  { partition: "boot", image: "boot", rootImage: "boot-magisk" },
  { partition: "recovery", image: "recovery" },
  { partition: "system", image: "system" },
  { partition: "vendor", image: "vendor" },
  // The boot logo (the first 128 KiB of splash). Optional: kits from before
  // it was added have no splash.bin, and those still flash.
  { partition: "splash", image: "splash", optional: true },
  // Zero-filled so factory reset protection state cannot outlive the install.
  { partition: "config", zero: true },
];

// An image file is <image>.bin, as ota2raw and backups name them, or
// <image>.img, as firmware packages do.
export const IMAGE_EXTENSIONS = [".bin", ".img"];

export const BUILD_IMAGES = WRITES.flatMap((w) => [w.image, w.rootImage]).filter(Boolean);

export const BUILD_FILES = [
  ...Object.values(VARIANTS).map((v) => v.loader),
  ...BUILD_IMAGES.flatMap((image) => IMAGE_EXTENSIONS.map((ext) => image + ext)),
];

// Where the images come from: a folder on the user's disk. Files are handed
// back as byte streams, so a 3 GB system image goes from disk to the phone
// without ever being held in memory.

import { BUILD_FILES } from "./device.js";

/** A folder picked from the user's disk: an extracted EDL bundle, or a backup. */
export class FileSource {
  /**
   * @param {Iterable<File>} files
   * @param {(file: File) => boolean} [wanted] which files to keep; by default the build's images and loaders
   */
  constructor(files, label = "local folder", wanted = (file) => BUILD_FILES.includes(file.name)) {
    this.label = label;
    this.files = new Map();
    for (const file of files) {
      if (wanted(file)) this.files.set(file.name, file);
    }
  }

  /** A folder of partition images: the .bin and .img files at its top level, never ones in a subfolder. */
  static backup(files, label) {
    return new FileSource(
      files,
      label,
      (file) => /\.(bin|img)$/.test(file.name) && file.webkitRelativePath.split("/").length === 2,
    );
  }

  get count() {
    return this.files.size;
  }

  get totalBytes() {
    let total = 0;
    for (const file of this.files.values()) total += file.size;
    return total;
  }

  has(name) {
    return this.files.has(name);
  }

  size(name) {
    return this.files.get(name)?.size;
  }

  async stream(name) {
    return this.files.get(name).stream();
  }

  /** The first `length` bytes of a file. */
  async head(name, length) {
    return new Uint8Array(await this.files.get(name).slice(0, length).arrayBuffer());
  }

  async bytes(name) {
    return new Uint8Array(await this.files.get(name).arrayBuffer());
  }
}

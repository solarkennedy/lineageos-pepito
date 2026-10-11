// Where the images come from: a folder on the user's disk. Files are handed
// back as byte streams, so a 3 GB system image goes from disk to the phone
// without ever being held in memory.

import { BUILD_FILES } from "./device.js";

/** A build picked from the user's disk: an extracted EDL bundle. */
export class FileSource {
  /** @param {Iterable<File>} files */
  constructor(files, label = "local folder") {
    this.label = label;
    this.files = new Map();
    for (const file of files) {
      if (BUILD_FILES.includes(file.name)) this.files.set(file.name, file);
    }
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

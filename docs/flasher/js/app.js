// Page logic: wires the build picker, the phone connection and the flash run
// to the DOM. All protocol work lives in flash.js.

import { BUILD_IMAGES, VARIANTS, WRITES } from "./device.js";
import {
  backup,
  backupPlan,
  buildPlan,
  connect,
  flash,
  imageFile,
  imagePlan,
  isSparse,
  PER_PHONE,
  restorePlan,
} from "./flash.js";
import { LAYOUTS } from "./layouts.js";
import { tailorInstructions } from "./os.js";
import { BOOT_CHAIN, PARTITION_GROUPS, UNIQUENESS } from "./partitions.js";
import { FileSource } from "./sources.js";
import { EDL_FILTERS, UsbTransport } from "./usb.js";

const $ = (id) => document.getElementById(id);

// A folder needs the four images; only the loader for the chosen model is needed, and connect() checks that.
const REQUIRED_IMAGES = ["boot", "recovery", "system", "vendor"];

const state = {
  source: null,
  backup: null,
  restoreRows: null,
  image: null, // { source, file } for the Flash (advanced) tab
  imagePlan: null,
  usb: null,
  session: null,
  busy: false,
};

function log(line) {
  const time = new Date().toLocaleTimeString([], { hour12: false });
  $("log").textContent += `${time}  ${line}\n`;
  $("log").scrollTop = $("log").scrollHeight;
}

function formatBytes(n) {
  if (n >= 1 << 30) return `${(n / (1 << 30)).toFixed(2)} GiB`;
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(1)} MiB`;
  return `${(n / 1024).toFixed(0)} KiB`;
}

function table(element, head, rows) {
  element.replaceChildren();
  const addRow = (cells, tag) => {
    const tr = element.insertRow();
    for (const cell of cells) {
      const td = document.createElement(tag);
      if (cell && typeof cell === "object") {
        td.textContent = cell.text;
        td.className = cell.className;
        for (const tag of cell.tags ?? []) {
          const span = document.createElement("span");
          span.className = "tag";
          span.textContent = tag;
          td.append(" ", span);
        }
      } else {
        td.textContent = cell;
      }
      tr.append(td);
    }
  };
  addRow(head, "th");
  for (const row of rows) addRow(row, "td");
  element.hidden = false;
}

/** Show a message in one of the notice boxes: "result" (flash) or "connect-result" (phone). */
function showResult(message, bad = false, id = "result") {
  $(id).textContent = message;
  $(id).classList.toggle("bad", bad);
  $(id).hidden = false;
}

const NO_FOLDER_SAVE =
  "This browser has saving to a folder turned off. Chrome and Edge have it on. In Brave, open brave://flags/#file-system-access-api, set it to Enabled and relaunch.";

/**
 * Say what a step is still waiting for, or hide the line when it is ready.
 * `warning` is shown too but does not count as missing: the step stays usable.
 */
function needs(id, missing, warning = "") {
  const parts = [];
  if (missing.length) parts.push(`Needs: ${missing.join("; ")}.`);
  if (warning) parts.push(warning);
  $(id).hidden = parts.length === 0;
  $(id).textContent = parts.join(" ");
}

function refresh() {
  const noUsb = navigator.usb
    ? []
    : [window.isSecureContext ? "a Chromium browser (Chrome or Edge)" : "this page opened from https:// or http://localhost"];
  const noPhone = state.session ? [] : ["a connected phone (Connect the phone)"];
  const noRom = state.source ? [] : ["a ROM folder with all four images (Get the ROM)"];

  needs("connect-needs", noUsb);
  needs("backup-needs", noPhone, window.showDirectoryPicker ? "" : NO_FOLDER_SAVE);
  needs("flash-needs", [...noRom, ...noPhone]);
  const noBackup = state.backup ? [] : ["a folder of partition images"];
  needs("restore-needs", [...noBackup, ...noPhone]);
  const nothingToRestore = !state.restoreRows?.some((row) => row.action === "write");

  // Connecting needs no ROM folder: it is also how to check the phone is in
  // EDL mode, and a backup needs only the loader shipped with this page.
  $("connect-button").disabled = state.busy || noUsb.length > 0;
  $("flash-button").disabled = state.busy || noRom.length > 0 || noPhone.length > 0;
  $("reboot-button").disabled = state.busy || noPhone.length > 0;
  $("backup-button").disabled = state.busy || noPhone.length > 0;
  $("folder-button").disabled = state.busy;
  $("restore-button").disabled = state.busy || nothingToRestore;
  $("restore-folder-button").disabled = state.busy;
  needs("write-needs", [...(state.image ? [] : ["an image file"]), ...noPhone]);
  $("write-button").disabled = state.busy || !state.imagePlan;
  $("image-button").disabled = state.busy;
  $("partition-select").disabled = state.busy || noPhone.length > 0;
  needs("read-needs", noPhone, window.showSaveFilePicker ? "" : NO_FOLDER_SAVE);
  $("read-select").disabled = state.busy || noPhone.length > 0;
  $("read-button").disabled = state.busy || noPhone.length > 0 || !$("read-select").value;
}

// --- 1. build ---------------------------------------------------------------

async function showSource(source) {
  state.source = null;
  $("file-table").hidden = true;
  refresh();
  // Each image's file, .bin or .img. A folder with both for one image is refused.
  let files;
  try {
    files = new Map(BUILD_IMAGES.map((image) => [image, imageFile(source, image)]));
  } catch (e) {
    $("build-problem").textContent = e.message;
    $("build-problem").hidden = false;
    return;
  }
  table(
    $("file-table"),
    ["File", "Size"],
    BUILD_IMAGES.map((image) => [
      files.get(image) ?? `${image}.bin`,
      files.get(image)
        ? { text: formatBytes(source.size(files.get(image))), className: "n" }
        : { text: REQUIRED_IMAGES.includes(image) ? "missing" : "not in this folder", className: "n missing" },
    ]),
  );
  const missing = REQUIRED_IMAGES.filter((image) => !files.get(image)).map((image) => `${image}.bin`);
  const sparse = [];
  for (const file of files.values()) {
    if (file && isSparse(await source.head(file, 4))) sparse.push(file);
  }
  $("build-problem").hidden = missing.length === 0 && sparse.length === 0;
  if (sparse.length) {
    $("build-problem").textContent =
      `${sparse.join(", ")} is an Android sparse image, which this page cannot flash. Convert it to a raw image with simg2img first.`;
    return;
  }
  $("build-problem").textContent =
    `This folder is missing ${missing.join(", ")}. Choose the edl folder from the extracted zip, and run ota2raw in it first: that is what creates the .bin images.`;
  if (missing.length) return;
  state.source = source;
  $("root-check").disabled = !files.get("boot-magisk");
  if ($("root-check").disabled) $("root-check").checked = false;
  log(`Build: ${source.label}`);
  showPlan();
  refresh();
}

$("folder-button").onclick = () => $("folder-input").click();
$("folder-input").onchange = (event) => {
  const files = [...event.target.files];
  if (files.length === 0) return;
  const folder = files[0].webkitRelativePath.split("/")[0] || "local folder";
  $("folder-name").textContent = folder;
  showSource(new FileSource(files, folder));
};
$("root-check").onchange = showPlan;
$("variant-select").onchange = refresh;

// --- 2. phone ---------------------------------------------------------------

function showPhone(session) {
  const rows = [
    ["Variant", VARIANTS[session.variant].name],
    ["Partition table", `${session.gpt.partitions.length} partitions, matches the ${VARIANTS[session.variant].name} layout`],
  ];
  const dl = $("phone-info");
  dl.replaceChildren();
  for (const [term, value] of rows) {
    const dt = document.createElement("dt");
    const dd = document.createElement("dd");
    dt.textContent = term;
    dd.textContent = value;
    dl.append(dt, dd);
  }
  dl.hidden = false;

  const option = (p) =>
    new Option(`${p.name} (${formatBytes(p.sectors * 512)}${PER_PHONE.includes(p.name) ? ", this phone only" : ""})`, p.name);
  $("partition-select").replaceChildren(new Option("Choose a partition", ""), ...session.gpt.partitions.map(option));
  // Reads start from the backup plan, which also covers the partition table.
  $("read-select").replaceChildren(
    new Option("Choose a partition", ""),
    ...backupPlan(session, { exclude: [] }).map((step) =>
      step.name === "PrimaryGPT" ? new Option(`Partition table (${step.file})`, step.name) : option(step),
    ),
  );
  pickPartitionFor(state.image?.file);
  showImagePlan();
}

function showPlan() {
  $("plan-table").hidden = true;
  if (!state.session || !state.source) return null;
  try {
    const plan = buildPlan(state.session, state.source, { root: $("root-check").checked });
    table(
      $("plan-table"),
      ["Partition", "Image", "Size", "At sector"],
      plan.map((step) => [
        step.partition,
        step.file ?? "zero-fill",
        { text: formatBytes(step.bytes), className: "n" },
        { text: String(step.start), className: "n" },
      ]),
    );
    return plan;
  } catch (e) {
    showResult(e.message, true);
    return null;
  }
}

async function run(what, action, resultId = "result") {
  state.busy = true;
  $(resultId).hidden = true;
  refresh();
  try {
    await action();
  } catch (e) {
    log(`${what} failed: ${e.message}`);
    showResult(e.message, true, resultId);
  } finally {
    state.busy = false;
    refresh();
  }
}

async function dropConnection() {
  await state.usb?.close();
  state.usb = null;
  state.session = null;
  $("phone-info").hidden = true;
  $("plan-table").hidden = true;
  clearRestore();
  $("partition-select").replaceChildren(new Option("Connect the phone first", ""));
  $("read-select").replaceChildren(new Option("Connect the phone first", ""));
  showImagePlan();
}

/**
 * The Firehose loader for a model: from the chosen ROM folder if it has one,
 * else the copy shipped with this page in loaders/.
 */
const loaders = {
  async bytes(name) {
    if (state.source?.has(name)) return state.source.bytes(name);
    const response = await fetch(`loaders/${name}`).catch(() => null);
    return response?.ok ? new Uint8Array(await response.arrayBuffer()) : undefined;
  },
};

$("connect-button").onclick = () =>
  run(
    "Connect",
    async () => {
      const say = (message, bad = false) => showResult(message, bad, "connect-result");
      await dropConnection();
      let device;
      try {
        // The picker lists only phones in EDL mode, so a phone appearing in it is the check.
        device = await navigator.usb.requestDevice({ filters: EDL_FILTERS });
      } catch (e) {
        if (e.name !== "NotFoundError") throw e;
        say("No phone was chosen. If the list was empty, the phone is not in EDL mode.", true);
        return;
      }
      log("Phone found in EDL mode");
      const variant = $("variant-select").value;
      const usb = new UsbTransport(device);
      try {
        await usb.open();
        state.session = await connect(usb, loaders, { variant, log });
      } catch (e) {
        await usb.close();
        throw e;
      }
      state.usb = usb;
      showPhone(state.session);
      showPlan();
      await showRestore().catch((e) => showResult(e.message, true, "restore-problem"));
      say("Phone checked and ready. Nothing has been written.");
    },
    "connect-result",
  );

// --- 3. backup --------------------------------------------------------------

/** Keep the page awake and warn before leaving while the phone is mid-transfer. */
async function guarded(action) {
  const wakeLock = await navigator.wakeLock?.request("screen").catch(() => null);
  const warnOnLeave = (event) => event.preventDefault();
  window.addEventListener("beforeunload", warnOnLeave);
  try {
    return await action();
  } finally {
    window.removeEventListener("beforeunload", warnOnLeave);
    await wakeLock?.release();
  }
}

function progressLine(what, done, total, started) {
  const rate = done / ((performance.now() - started) / 1000);
  return `${what}: ${formatBytes(done)} of ${formatBytes(total)}, ${formatBytes(rate)}/s, about ${Math.ceil((total - done) / rate / 60)} min left`;
}

$("backup-button").onclick = () =>
  run("Backup", async () => {
    if (!window.showDirectoryPicker) throw new Error(NO_FOLDER_SAVE);
    let parent;
    try {
      parent = await window.showDirectoryPicker({ mode: "readwrite" });
    } catch (e) {
      if (e.name === "AbortError") return; // picker dismissed
      throw e;
    }
    // Local time, so the folder name matches the clock the user sees.
    const now = new Date();
    const stamp = new Date(now - now.getTimezoneOffset() * 60000).toISOString().slice(0, 16).replace(/[:T]/g, "-");
    const name = `palm-${state.session.variant}-backup-${stamp}`;
    const folder = await parent.getDirectoryHandle(name, { create: true });
    const createFile = async (file) => (await folder.getFileHandle(file, { create: true })).createWritable();

    const plan = backupPlan(state.session);
    log(`Backing up ${plan.length - 1} partitions to ${parent.name}/${name}`);
    $("backup-progress").hidden = false;
    const started = performance.now();
    let current = "";
    await guarded(() =>
      backup(state.session, plan, createFile, ({ name: partition, read, total }) => {
        if (partition !== current) {
          current = partition;
          log(`Reading ${partition}`);
        }
        $("backup-bar").value = read / total;
        $("backup-text").textContent = progressLine(partition, read, total, started);
      }),
    );
    const minutes = ((performance.now() - started) / 60000).toFixed(1);
    log(`Backup complete in ${minutes} min`);
    $("backup-text").textContent = `Done in ${minutes} min`;
    $("backup-note").textContent = `Saved to ${parent.name}/${name}`;
    showResult(
      `Backup saved to ${parent.name}/${name}. Keep it somewhere safe; it cannot be recreated after flashing.`,
      false,
      "backup-result",
    );
  }, "backup-result");

// --- 4. flash ---------------------------------------------------------------

async function reboot() {
  log("Rebooting the phone");
  await state.session.firehose.reset();
  await dropConnection();
}

$("reboot-button").onclick = () => run("Restart", reboot, "connect-result");

$("flash-button").onclick = () =>
  run("Flash", async () => {
    const plan = showPlan();
    if (!plan) return;
    const variant = VARIANTS[state.session.variant].name;
    if (!confirm(`Flash ${state.source.label} to this ${variant}?\n\nDo not unplug the phone until it finishes.`)) return;

    $("progress").hidden = false;
    const started = performance.now();
    let current = -1;
    try {
      await guarded(() =>
        flash(state.session, plan, state.source, ({ step, partition, written, total }) => {
          if (step !== current) {
            current = step;
            log(`Writing ${partition}`);
          }
          $("progress-bar").value = written / total;
          $("progress-text").textContent = progressLine(partition, written, total, started);
        }),
      );
    } catch (e) {
      // A partition is half-written. The phone stays in EDL with the
      // programmer running, so Flash can simply be pressed again.
      throw new Error(`${e.message}. The phone may not boot until a flash completes; leave it connected and press Flash again.`);
    }
    const minutes = ((performance.now() - started) / 60000).toFixed(1);
    log(`Flash complete in ${minutes} min`);
    $("progress-text").textContent = `Done in ${minutes} min`;
    await reboot();
    showResult("Flash complete. The first boot takes a few minutes. After a major change, erase data next (Erase data, below).");
  });

// --- 6. back up (advanced) -------------------------------------------------

$("read-select").onchange = refresh;

$("read-button").onclick = () =>
  run(
    "Read",
    async () => {
      if (!window.showSaveFilePicker) throw new Error(NO_FOLDER_SAVE);
      const step = backupPlan(state.session, { exclude: [] }).find((s) => s.name === $("read-select").value);
      let handle;
      try {
        handle = await window.showSaveFilePicker({ suggestedName: step.file });
      } catch (e) {
        if (e.name === "AbortError") return; // picker dismissed
        throw e;
      }
      const out = await handle.createWritable();
      $("read-progress").hidden = false;
      const started = performance.now();
      const total = step.sectors * 512;
      log(`Reading ${step.name} to ${handle.name}`);
      try {
        await guarded(() =>
          state.session.firehose.readStream(
            step.start,
            step.sectors,
            (chunk) => out.write(chunk),
            (read) => {
              $("read-bar").value = read / total;
              $("read-text").textContent = progressLine(step.name, read, total, started);
            },
          ),
        );
      } catch (e) {
        await out.abort().catch(() => {});
        throw e;
      }
      await out.close();
      const seconds = ((performance.now() - started) / 1000).toFixed(0);
      log(`Saved ${step.name} in ${seconds} s`);
      $("read-text").textContent = `Done in ${seconds} s`;
      showResult(`Saved ${step.name} to ${handle.name}. The phone is still in EDL mode.`, false, "read-result");
    },
    "read-result",
  );

// --- 7. flash (advanced) ----------------------------------------------------

/** Choose the partition an image is named after, as in aboot.img or modemst1.bin. */
function pickPartitionFor(file) {
  const name = file?.replace(/\.(bin|img)$/, "");
  if ([...$("partition-select").options].some((option) => option.value === name)) $("partition-select").value = name;
}

/** Check the chosen image against the chosen partition and say what writing it would risk. */
async function showImagePlan() {
  state.imagePlan = null;
  const partition = $("partition-select").value;
  const warn = (message) => {
    $("image-warning").textContent = message;
    $("image-warning").hidden = !message;
  };
  warn("");
  if (state.image && state.session && partition) {
    try {
      state.imagePlan = await imagePlan(state.session, state.image.source, state.image.file, partition);
      if (PER_PHONE.includes(partition)) {
        warn(`${partition} holds this phone's own identity or calibration. Only write a copy taken from this same phone.`);
      } else if (BOOT_CHAIN.includes(partition)) {
        warn(`${partition} is part of the bootloader. A wrong image stops the phone from starting until it is rewritten from EDL mode.`);
      } else if (partition === "userdata") {
        warn("Writing userdata replaces all personal data on the phone.");
      }
    } catch (e) {
      warn(e.message);
    }
  }
  refresh();
}

$("image-button").onclick = () => $("image-input").click();
$("image-input").onchange = (event) => {
  const [file] = event.target.files;
  if (!file) return;
  state.image = { source: new FileSource([file], file.name, () => true), file: file.name };
  $("image-name").textContent = `${file.name}, ${formatBytes(file.size)}`;
  pickPartitionFor(file.name);
  showImagePlan();
};
$("partition-select").onchange = showImagePlan;

$("write-button").onclick = () =>
  run(
    "Write",
    async () => {
      const [step] = state.imagePlan;
      const variant = VARIANTS[state.session.variant].name;
      if (PER_PHONE.includes(step.partition)) {
        const typed = prompt(
          `${step.partition} holds this phone's own identity or calibration. Writing another phone's copy clones that phone onto this one.\n\n` +
            `Type ${step.partition} to write ${step.file} to it.`,
        );
        if (typed?.trim() !== step.partition) return;
      } else if (!confirm(`Write ${step.file} to ${step.partition} on this ${variant}?\n\nDo not unplug the phone until it finishes.`)) {
        return;
      }

      $("write-progress").hidden = false;
      const started = performance.now();
      log(`Writing ${step.file} to ${step.partition}`);
      await guarded(() =>
        flash(state.session, state.imagePlan, state.image.source, ({ written, total }) => {
          $("write-bar").value = written / total;
          $("write-text").textContent = progressLine(step.partition, written, total, started);
        }),
      );
      const seconds = ((performance.now() - started) / 1000).toFixed(0);
      log(`Wrote ${step.partition} in ${seconds} s`);
      $("write-text").textContent = `Done in ${seconds} s`;
      showResult(
        `Wrote ${step.file} to ${step.partition}. The phone is still in EDL mode: write another image, or press Restart the phone.`,
        false,
        "write-result",
      );
    },
    "write-result",
  );

// --- 8. partitions ---------------------------------------------------------

/** Size of a partition on one model, or null if that model has none. The last one fills the rest of the storage. */
function partitionSize(variant, name) {
  const layout = LAYOUTS[variant];
  const i = layout.findIndex(([label]) => label === name);
  if (i < 0) return null;
  return i === layout.length - 1 ? "rest of storage" : formatBytes(layout[i][2] * 512);
}

function showPartitions() {
  const container = $("partition-groups");
  for (const group of PARTITION_GROUPS) {
    const heading = document.createElement("h3");
    heading.textContent = group.title;
    const intro = document.createElement("p");
    intro.className = "muted";
    intro.textContent = group.intro;
    const t = document.createElement("table");
    t.className = "files partitions";
    table(
      t,
      ["Partition", "Size", { text: "What it holds", className: "l" }, { text: "Unique", className: "l" }],
      group.partitions.map(([name, text, uniqueness]) => {
        const sizes = [partitionSize("pvg100", name) ?? "none", partitionSize("pvg100e", name) ?? "none"];
        const tags = [
          WRITES.some((w) => w.partition === name) && (name === "config" ? "Flash clears" : "Flash writes"),
          BOOT_CHAIN.includes(name.replace(/bak$/, "")) && "Bootloader",
        ].filter(Boolean);
        return [
          { text: name, className: "name" },
          { text: sizes[0] === sizes[1] ? sizes[0] : sizes.join(" / "), className: "n" },
          { text, className: "", tags },
          { text: UNIQUENESS[uniqueness], className: uniqueness.startsWith("unit") ? "unique" : "muted" },
        ];
      }),
    );
    container.append(heading, intro, t);
  }
}

// --- tabs -------------------------------------------------------------------

// Each tab is one task. Elements carry data-tabs listing the tabs they appear
// on; the phone connection is shared, so it survives a switch. Steps are
// numbered per tab.
const TABS = ["backup", "flash", "restore", "backup-advanced", "flash-advanced", "partitions"];

function showTab() {
  const hash = location.hash.slice(1);
  const tab = TABS.includes(hash) ? hash : "backup";
  let step = 0;
  for (const element of document.querySelectorAll("[data-tabs]")) {
    element.hidden = !element.dataset.tabs.split(" ").includes(tab);
    const num = element.querySelector(".num");
    if (num && !element.hidden) num.textContent = ++step;
  }
  for (const button of document.querySelectorAll("[role=tab]")) {
    button.setAttribute("aria-selected", button.dataset.tab === tab);
  }
}

for (const button of document.querySelectorAll("[role=tab]")) {
  button.onclick = () => (location.hash = button.dataset.tab);
}
window.addEventListener("hashchange", showTab);

// --- 5. restore -------------------------------------------------------------

const RESTORE_STATUS = {
  write: "restore",
  "no-file": "no file, left as it is",
  unverified: "skipped: no traceability.bin proves this file is from this phone",
  never: "never restored",
};

const RESTORE_ORDER = ["write", "unverified", "no-file", "never"];

function clearRestore() {
  state.restoreRows = null;
  $("restore-list").hidden = true;
  $("restore-summary").hidden = true;
  $("restore-problem").hidden = true;
}

/** Match the chosen folder against the phone and show what a restore would write. Reads from the phone. */
async function showRestore() {
  clearRestore();
  if (!state.backup || !state.session) return;
  const rows = await restorePlan(state.session, state.backup);
  state.restoreRows = rows;
  table(
    $("restore-table"),
    ["Partition", { text: "Status", className: "l" }, "Size"],
    // Partitions with a file first, so a folder of a few images is not lost in the list.
    [...rows]
      .sort((a, b) => RESTORE_ORDER.indexOf(a.action) - RESTORE_ORDER.indexOf(b.action))
      .map((row) => [
        row.partition,
        { text: RESTORE_STATUS[row.action], className: row.action === "write" ? "good" : "muted" },
        { text: row.bytes ? formatBytes(row.bytes) : "", className: "n" },
      ]),
  );
  $("restore-list").hidden = false;

  const written = rows.filter((row) => row.action === "write").map((row) => row.partition);
  const unverified = rows.filter((row) => row.action === "unverified").length;
  let summary = written.length
    ? `Restores ${written.length} of ${rows.length} partitions: ${written.length > 6 ? `${written.slice(0, 6).join(", ")} and ${written.length - 6} more` : written.join(", ")}.`
    : "Nothing in this folder can be restored: no .bin or .img file is named after a partition on this phone, such as boot.bin or boot.img.";
  if (unverified) {
    summary += ` ${unverified} per-phone ${unverified === 1 ? "partition is" : "partitions are"} skipped because the folder has no traceability.bin from this phone.`;
  }
  $("restore-summary").textContent = summary;
  $("restore-summary").hidden = false;
}

$("restore-folder-button").onclick = () => $("restore-folder-input").click();
$("restore-folder-input").onchange = (event) => {
  const files = [...event.target.files];
  if (files.length === 0) return;
  const folder = files[0].webkitRelativePath.split("/")[0] || "local folder";
  state.backup = FileSource.backup(files, folder);
  $("restore-folder-name").textContent = `${folder}: ${state.backup.count} images, ${formatBytes(state.backup.totalBytes)}`;
  log(`Restore folder: ${folder}`);
  run("Check folder", showRestore, "restore-problem");
};

$("restore-button").onclick = () =>
  run(
    "Restore",
    async () => {
      // Checked again against the phone as it is now; every check runs before the question is asked.
      await showRestore();
      const plan = state.restoreRows.filter((row) => row.action === "write");
      if (plan.length === 0) return;
      const names = plan.map((row) => row.partition);
      const variant = VARIANTS[state.session.variant].name;
      const bootChain = names.some((name) => BOOT_CHAIN.includes(name)) ? " This includes the bootloader." : "";
      if (
        !confirm(
          `Restore ${plan.length} ${plan.length === 1 ? "partition" : "partitions"} from ${state.backup.label} to this ${variant}?\n\n` +
            `${names.length > 12 ? `${names.slice(0, 12).join(", ")} and ${names.length - 12} more` : names.join(", ")}.${bootChain}\n\n` +
            "Do not unplug the phone until it finishes.",
        )
      )
        return;

      $("restore-progress").hidden = false;
      const started = performance.now();
      let current = -1;
      try {
        await guarded(() =>
          flash(state.session, plan, state.backup, ({ step, partition, written, total }) => {
            if (step !== current) {
              current = step;
              log(`Writing ${partition}`);
            }
            $("restore-bar").value = written / total;
            $("restore-text").textContent = progressLine(partition, written, total, started);
          }),
        );
      } catch (e) {
        throw new Error(`${e.message}. The phone may not boot until a restore completes; leave it connected and press Restore again.`);
      }
      const minutes = ((performance.now() - started) / 60000).toFixed(1);
      log(`Restore complete in ${minutes} min`);
      $("restore-text").textContent = `Done in ${minutes} min`;
      await reboot();
      showResult(
        "Restore complete. If the phone stays on the boot logo or asks to reset, do a factory reset from recovery (see below).",
        false,
        "restore-result",
      );
    },
    "restore-result",
  );

// --- startup ----------------------------------------------------------------

if (!navigator.usb) {
  $("unsupported").textContent = window.isSecureContext
    ? "This browser cannot talk to USB devices, so nothing on this page will work. Open it in Chrome, Edge or another Chromium browser on a desktop computer."
    : "WebUSB needs a secure page. Open this flasher from https:// or http://localhost.";
  $("unsupported").hidden = false;
} else {
  navigator.usb.addEventListener("disconnect", (event) => {
    if (event.device !== state.usb?.device) return;
    log("Phone disconnected");
    if (!state.busy) dropConnection().then(refresh);
  });
}

$("copy-log").onclick = () => navigator.clipboard.writeText($("log").textContent);

showPartitions();
showTab();
refresh();
tailorInstructions();

// Page logic: wires the build picker, the phone connection and the flash run
// to the DOM. All protocol work lives in flash.js.

import { BUILD_FILES, VARIANTS } from "./device.js";
import { backup, backupPlan, buildPlan, connect, flash } from "./flash.js";
import { tailorInstructions } from "./os.js";
import { FileSource } from "./sources.js";
import { EDL_FILTERS, UsbTransport } from "./usb.js";

const $ = (id) => document.getElementById(id);

// A folder needs the four images; only the loader for the chosen model is needed, and connect() checks that.
const REQUIRED_FILES = ["boot.bin", "recovery.bin", "system.bin", "vendor.bin"];

const state = {
  source: null,
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
  const noPhone = state.session ? [] : ["a connected phone (step 2)"];
  const noRom = state.source ? [] : ["a ROM folder with all four images (step 1)"];

  needs("connect-needs", noUsb);
  needs("backup-needs", noPhone, window.showDirectoryPicker ? "" : NO_FOLDER_SAVE);
  needs("flash-needs", [...noRom, ...noPhone]);

  // Connecting needs no ROM folder: it is also how to check the phone is in
  // EDL mode, and a backup needs only the loader shipped with this page.
  $("connect-button").disabled = state.busy || noUsb.length > 0;
  $("flash-button").disabled = state.busy || noRom.length > 0 || noPhone.length > 0;
  $("reboot-button").disabled = state.busy || noPhone.length > 0;
  $("backup-button").disabled = state.busy || noPhone.length > 0;
  $("folder-button").disabled = state.busy;
}

// --- 1. build ---------------------------------------------------------------

// Android sparse images start with this magic. Written as-is they would
// produce a corrupt partition, so such a build is refused outright.
const SPARSE_MAGIC = [0x3a, 0xff, 0x26, 0xed];

async function sparseImages(source) {
  const sparse = [];
  for (const name of BUILD_FILES.filter((file) => file.endsWith(".bin") && source.has(file))) {
    const head = await source.head(name, 4);
    if (SPARSE_MAGIC.every((byte, i) => head[i] === byte)) sparse.push(name);
  }
  return sparse;
}

async function showSource(source) {
  state.source = null;
  refresh();
  table(
    $("file-table"),
    ["File", "Size"],
    BUILD_FILES.filter((name) => name.endsWith(".bin")).map((name) => [
      name,
      source.has(name)
        ? { text: formatBytes(source.size(name)), className: "n" }
        : { text: REQUIRED_FILES.includes(name) ? "missing" : "not in this folder", className: "n missing" },
    ]),
  );
  const missing = REQUIRED_FILES.filter((name) => !source.has(name));
  const sparse = await sparseImages(source);
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
  $("root-check").disabled = !source.has("boot-magisk.bin");
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
      say(
        showPlan()
          ? "Phone checked and ready to back up or flash. Nothing has been written."
          : "Phone checked and ready to back up. To flash, choose a ROM folder in step 1.",
      );
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
    showResult("Flash complete. The first boot takes a few minutes. After a major change, erase data next (step 5).");
  });

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

refresh();
tailorInstructions();

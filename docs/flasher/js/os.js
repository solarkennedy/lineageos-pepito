// Tailor the instructions to the visitor's computer. Elements marked
// data-os="windows|linux|macos" are hidden by style.css unless they match.
// An unrecognised system shows everything.

const NAMES = { windows: "Windows", linux: "Linux", macos: "macOS" };

// The ota2raw build for each system and CPU, as named in the release zip.
const OTA2RAW = {
  linux: { x86: "ota2raw-linux-x86_64", arm: "ota2raw-linux-arm64" },
  macos: { x86: "ota2raw-macos-x86_64", arm: "ota2raw-macos-arm64" },
};

function detectOs() {
  const platform = (navigator.userAgentData?.platform ?? navigator.platform ?? "").toLowerCase();
  if (platform.startsWith("win")) return "windows";
  if (platform.startsWith("mac")) return "macos";
  if (platform.startsWith("linux") && !/android/i.test(navigator.userAgent)) return "linux";
  return null;
}

export async function tailorInstructions() {
  const os = detectOs();
  if (!os) return;
  const root = document.documentElement;
  root.dataset.os = os;
  document.getElementById("os-name").textContent = NAMES[os];
  document.getElementById("os-note").hidden = false;
  document.getElementById("os-all").onclick = () => {
    delete root.dataset.os;
    delete root.dataset.arch;
    document.getElementById("os-note").hidden = true;
  };

  // Only Chromium reports the CPU; without it both builds stay mentioned.
  const hints = await navigator.userAgentData?.getHighEntropyValues(["architecture"]).catch(() => null);
  const file = OTA2RAW[os]?.[hints?.architecture];
  if (!file) return;
  root.dataset.arch = hints.architecture;
  for (const el of document.querySelectorAll(`[data-ota2raw="${os}"]`)) el.textContent = file;
}

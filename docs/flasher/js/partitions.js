// What each partition holds, for the Partitions tab. Every partition in either
// layout (js/layouts.js) must appear here; test/flash.test.mjs checks that.
//
// Descriptions come from Qualcomm's MSM8937 conventions and from looking at
// a PVG100 backup (unit 9c2e6b00, 2026-10-11). "Empty" means all zeros there.

// Bootloader partitions. A wrong image in one of these stops the phone from starting.
export const BOOT_CHAIN = ["sbl1", "rpm", "tz", "aboot", "devcfg", "cmnlib", "cmnlib64", "keymaster"];

// Whether a partition's contents are unique to one phone, found by comparing
// eight units' backups, and one unit's backups six weeks apart. Keys are the
// third field of each entry below.
export const UNIQUENESS = {
  unit: "Yes",
  "unit-live": "Yes, changes as it runs",
  same: "No, identical",
  firmware: "No, per firmware",
  rom: "No, per ROM",
  use: "No, changes with use",
};

/** @type {{title: string, intro: string, partitions: [string, string, keyof UNIQUENESS][]}[]} */
export const PARTITION_GROUPS = [
  {
    title: "Bootloader",
    intro:
      "Signed code that starts the phone, in the order it runs. Each has a second copy ending in bak, kept so an update can fail safely. All of it is signed by TCL, the phone's maker; the chip refuses anything else. Flash leaves all of these alone.",
    partitions: [
      ["sbl1", "Secondary bootloader: the first code the chip's boot ROM loads. It sets up the memory and loads everything below.", "firmware"],
      ["rpm", "Firmware for the resource power manager, a small processor that controls power and clocks.", "firmware"],
      ["tz", "TrustZone: the secure operating system that runs beside Android and guards keys and secure storage.", "firmware"],
      ["devcfg", "TrustZone's settings for this chip.", "firmware"],
      ["cmnlib", "Shared library for TrustZone apps (32-bit).", "firmware"],
      ["cmnlib64", "Shared library for TrustZone apps (64-bit).", "firmware"],
      ["keymaster", "The TrustZone app behind Android's hardware-backed keys, used for the lock screen and storage encryption.", "firmware"],
      [
        "aboot",
        "The Android bootloader (LK). It shows the PALM logo, checks and starts boot or recovery, and provides fastboot.",
        "firmware",
      ],
      ["sbl1bak", "Second copy of sbl1.", "firmware"],
      ["rpmbak", "Second copy of rpm.", "firmware"],
      ["tzbak", "Second copy of tz.", "firmware"],
      ["devcfgbak", "Second copy of devcfg.", "firmware"],
      ["cmnlibbak", "Second copy of cmnlib.", "firmware"],
      ["cmnlib64bak", "Second copy of cmnlib64.", "firmware"],
      ["keymasterbak", "Second copy of keymaster.", "firmware"],
      ["abootbak", "Second copy of aboot.", "firmware"],
      [
        "devinfo",
        "Settings the bootloader keeps for itself, such as whether the bootloader is unlocked.",
        "use",
      ],
      ["sec", "Qualcomm's record of the security fuses set at the factory.", "same"],
      [
        "DDR",
        "Memory training results: timings sbl1 measured for this phone's RAM chip, saved so later starts are faster.",
        "unit",
      ],
      ["splash", "The PALM logo shown while the phone starts.", "firmware"],
    ],
  },
  {
    title: "Modem and radio",
    intro:
      "Firmware for the cellular modem and its companions, and the modem's own files. The per-phone partitions here are the main reason to keep a backup: they cannot be recreated, and another phone's copies do not work properly in this one.",
    partitions: [
      [
        "modem",
        "Firmware for the modem and for the Wi-Fi, Bluetooth, GPS and video chips. Android reads it at start-up; nothing writes to it.",
        "firmware",
      ],
      ["dsp", "Firmware and libraries for the audio and sensor processor.", "firmware"],
      [
        "modemst1",
        "The modem's live file system: the phone's IMEI, radio calibration and network settings. The modem writes it as it runs.",
        "unit-live",
      ],
      ["modemst2", "Second copy of modemst1. The modem keeps the two in step.", "unit-live"],
      [
        "fsg",
        "A copy of the modem's file system taken at the factory. The modem falls back to it if both modemst1 and modemst2 are lost.",
        "unit",
      ],
      ["fsc", "A marker that tells the modem to restore from fsg. Empty in normal use.", "same"],
      ["ssd", "Keys for the modem's encrypted settings.", "unit"],
      ["tunning", "TCL's factory radio calibration and test records.", "unit"],
      ["simlock", "Carrier lock (SIM lock) data written at the factory.", "unit"],
      ["traceability", "The factory record: board serial number, model and build codes.", "unit"],
      ["mcfg", "Space for carrier configuration files. Empty: this phone keeps them inside modem.", "same"],
    ],
  },
  {
    title: "Android",
    intro: "The operating system, its data, and the partitions Android and the bootloader use to talk to each other.",
    partitions: [
      ["boot", "The Linux kernel and the first files Android starts with. The root option on the Flash tab swaps in a Magisk-patched copy.", "rom"],
      ["recovery", "The recovery system: factory reset, installing updates from a zip, rebooting to EDL.", "rom"],
      ["system", "Android itself: the framework and the built-in apps.", "rom"],
      ["vendor", "The hardware-specific half of Android: drivers and services for this phone's chips.", "rom"],
      ["userdata", "Apps, settings, photos, everything personal. Encrypted. Never backed up or restored by this page.", "use"],
      ["cache", "Scratch space: recovery's logs and files waiting to be installed.", "use"],
      [
        "persist",
        "Calibration and settings that must survive a factory reset: sensors, Wi-Fi and Bluetooth.",
        "unit-live",
      ],
      [
        "oem",
        "Stock firmware keeps carrier customisation here. LineageOS reuses it as /metadata, for bookkeeping that storage encryption and updates need.",
        "use",
      ],
      ["config", "Factory reset protection: who last signed in to Google on this phone. Flash clears it.", "use"],
      ["misc", "Messages between Android, recovery and the bootloader, such as \"start in recovery next time\".", "use"],
      ["fotadata", "Where the stock updater downloads system updates. LineageOS does not use it. PVG100 only.", "use"],
    ],
  },
  {
    title: "Unused",
    intro: "Partitions empty on every unit seen. They are reserved for features this phone does not use.",
    partitions: [
      ["apdp", "Debug policy for the main processor. Only used on development phones.", "same"],
      ["msadp", "Debug policy for the modem. Only used on development phones.", "same"],
      ["dpo", "Debug policy override. Only used on development phones.", "same"],
      ["keystore", "Reserved for key storage. Android keeps its keys elsewhere.", "same"],
      ["limits", "Reserved for power and temperature limits.", "same"],
      ["logdump", "Space for crash logs.", "same"],
      ["mdtp", "Qualcomm's theft protection app. Present but never switched on.", "firmware"],
      ["dip", "Data for that theft protection. Empty.", "same"],
      ["redbend", "Reserved for a third-party update tool (Red Bend).", "same"],
      ["mota", "Reserved for an update tool. Empty.", "same"],
      ["syscfg", "Reserved for system settings. Empty.", "same"],
    ],
  },
];

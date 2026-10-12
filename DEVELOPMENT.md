# Developing Bluechip

Notes for working on Bluechip itself. For installing and using it, see
[README.md](README.md).

## Background

Bluechip started as a clone of Omarchy's built-in Bluetooth widget
(`omarchy plugin clone omarchy.bluetooth`). The goal was a Bluetooth panel that
stays native to the Omarchy shell (same components, same theme, same place in
the bar) and adds what the stock widget lacks:

- **Battery for devices whose driver reports it outside Bluetooth.** For
  example, an 8BitDo Pro 2 on the xpadneo driver publishes only a coarse level
  such as "Full" under `/sys/class/power_supply`.
- **Device details:** type, advertised name, address, status, profiles and
  hardware ID.
- **Rename** (BlueZ alias), plus **Trusted** and **Blocked** switches.
- **Device-type icons.**

The manifest keeps `"omarchy": { "clonedFrom": "omarchy.bluetooth" }`. With
that in place:

- `omarchy plugin add … --enable` puts Bluechip in the stock widget's spot in
  the bar.
- The shell routes calls for `omarchy.bluetooth`, such as the default
  `Super+Ctrl+B` (`omarchy-shell shell toggle omarchy.bluetooth`), to Bluechip
  through `PluginRegistry.resolveEnabledId`.

`Panel.qml` keeps the stock `moduleName` / `ipcTarget` (`omarchy.bluetooth`)
for the same reason.

## Files

| File | Role |
|------|------|
| `manifest.json` | Plugin manifest (ID `io.github.chizzler.bluechip`) |
| `Panel.qml` | Bar button and panel. The stock widget plus the details card, rename field, switches, gauge and icons |
| `Model.js` | Pure helpers: labels, device rows, battery gauge model, device type names and glyphs |
| `bt-details` | Bash + jq helper. Prints extra per-device details as JSON |

Upstream original, for comparison:
`/usr/share/omarchy/shell/plugins/panels/bluetooth/`.

## How it works

- **`bt-details <mac>…`** prints JSON keyed by lowercase MAC. It runs three
  processes in total (bash, one `busctl`, one `jq`), however many devices
  there are.
  - `profiles` and `hardwareId`: read from BlueZ's `Device1` properties
    (`UUIDs`, `Modalias`) with a single `ObjectManager.GetManagedObjects`
    call. Common SIG UUIDs map to names; others show as `0x….`
  - `battery`: `{source, percent, level, status}` from the
    `/sys/class/power_supply` entry whose HID parent's `uevent` has
    `HID_UNIQ=<mac>`. That works whatever the driver names the supply. If
    `HID_UNIQ` is missing or isn't a MAC (wired controllers can carry a USB
    serial there), it falls back to a MAC in the supply's name, as with
    hid-sony, hid-playstation and hid-nintendo (`ps-controller-battery-<mac>`
    and similar). `-`/`_` separators are normalised to `:`.
    Batteries BlueZ itself reports come through Quickshell's
    `device.battery`, so the helper doesn't repeat them.
- **`Panel.qml`** runs the helper through a Quickshell `Process`:
  - when the panel opens
  - every 10 s while it's open
  - when the set of connected devices changes (`connectedKey`), not on every
    list update during a scan

  It covers connected devices plus the one whose card is open. An identical
  result is ignored, so bindings don't re-run for nothing.
- **Details cards** are built by a `Loader` only while open, so at most one
  exists.
- **Rename / Trusted / Blocked** write `name`, `trusted` and `blocked` on
  Quickshell's `BluetoothDevice`. These map directly onto BlueZ `Device1`
  properties. An empty name clears the alias.
- **Labels** prefer the alias (`device.name`), so renames show. Address-like
  aliases fall back to `deviceName`.
- **Battery gauge:** five segments, one per kernel `capacity_level` (Critical,
  Low, Normal, High, Full), or one per 20% when a percentage is available.
  - Colours are the theme's `Color.accent`, switching to `Color.urgent` at
    Low/Critical (20% or below).
  - The charge state comes from the supply's `status`: Charging, Full
    (shown as "Charged") or Not charging. Discharging/Unknown are omitted. It
    applies even when BlueZ supplies the percentage.
  - Empty segments are the bar foreground at 18% opacity.
- **Icons:** BlueZ icon names (`input-gaming`, `audio-headset`, …) map to
  Nerd Font Material glyphs. Unknown types keep the Bluetooth glyph.

## Workflow and gotchas

- **Restart after edits.** Hot reload logs "Local plugin changed" but keeps
  serving the cached component, so run `omarchy restart shell`.
- **A symlinked checkout works.** The scanner globs `"$dir"/*/`, so
  `~/.config/omarchy/plugins/io.github.chizzler.bluechip` can be a symlink to
  a working copy.
- **`console.log` output from the plugin doesn't reach `quickshell log`.** To
  inspect state, add a temporary `IpcHandler` with a function that returns a
  string, and call it with `omarchy-shell <target> <function>`.
- **The panel grabs the keyboard while it's open, and `x` forgets the selected
  device.** When testing with `wtype`, close the panel in the same command.
- **The panel opens on the focused monitor.** Screenshot that one.
- **QML `visible` trap:** a child reads as hidden while its parent is hidden.
  Never bind a container's `visible` to its children's `visible`.

## Ideas

- Battery on the bar icon, or a tooltip
- Low-battery notification
- Wake-allowed switch
- Headphone profile switch (A2DP / HFP)
- Background reconnect for devices that don't reconnect themselves

## Keeping up with upstream

After Omarchy updates, compare `Panel.qml` and `Model.js` with the upstream
copies and bring over relevant fixes.

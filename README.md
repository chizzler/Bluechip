# Bluechip

A more capable Bluetooth widget for the Omarchy bar. It builds on Omarchy's
own Bluetooth widget, so it looks and behaves like the rest of the desktop.

Started 2026-10-12, after pairing an 8BitDo Pro 2 controller.

## Goals

- **Native to Omarchy.** It lives in the bar and uses the shell's own UI
  components and theme. No separate app.
- **Battery for every device.** That includes game controllers whose driver
  reports battery outside Bluetooth (the 8BitDo on xpadneo reports only a rough
  level, such as "Full").
- **Device details.** Type, original name, address, status, battery, Bluetooth
  profiles, and hardware ID.
- **Rename devices.** Uses BlueZ aliases. An empty name goes back to the
  device's own name.
- **Device controls.** Switches for trusted (auto-reconnect) and blocked.
- **Survives Omarchy updates.** It's a user plugin cloned from the built-in
  one, and nothing under `/usr/share/omarchy` is touched.

### Not possible / out of scope

- **"Pairing type"** can't be chosen from the PC. The device decides how it
  presents itself (on the 8BitDo, that's the X/D/S switch on the back).
- **Third-party plugins we looked at:**
  - [Device Batteries](https://github.com/diegoalveslv/omarchy-device-batteries)
  - [Peripheral Battery Indicator](https://github.com/diogocezar/omarchy-peripheral-battery)
  - [vinicgobbi's battery plugin](https://github.com/vinicgobbi/omarchy-plugin-battery)

  All are battery-only, brand new (0–1 GitHub stars), and not in Omarchy's
  catalog. Standalone apps like Blueman and bluetuith were ruled out because
  they aren't integrated with the desktop.

## Where things live

| What | Path |
|------|------|
| Plugin source (this repo) | `~/Projects/Bluechip/plugin/` |
| Where Omarchy loads it (symlink → `plugin/`) | `~/.config/omarchy/plugins/chee.bluetooth` |
| Panel UI | `plugin/Panel.qml` |
| Data helpers | `plugin/Model.js` |
| Details helper script | `plugin/bt-details` |
| Bar layout (uses `chee.bluetooth`) | `~/.config/omarchy/shell.json` |
| `Super+Ctrl+B` override | `~/.config/hypr/bindings.lua` |
| Original it was cloned from (read-only) | `/usr/share/omarchy/shell/plugins/panels/bluetooth/` |

## Status: working

What's been tested on screen (2026-10-12):

- **Battery:** the controller row shows "Battery Full".
- **Details card** (ⓘ button or `i`) shows name, type, device name, address,
  status, battery, profiles and hardware ID. It matches the theme.
- **Rename** (pencil button or `r`) opens with the current name selected. Enter
  saves and BlueZ's alias updates. Saving an empty name resets to the device's
  own name.
- **`Super+Ctrl+B`** opens this panel.

Not tested by clicking yet: the Trusted and Blocked switches. They work the
same way as rename (writing a device property), which is tested.

## Features

- **Details card per paired or connected device:**
  - type (from the BlueZ icon), the device's own name, address, status
  - battery, from BlueZ or from the input driver via `/sys/class/power_supply`
  - Bluetooth profiles
  - hardware ID (vendor:product)
- **Inline rename** (writes the BlueZ alias). Leave it empty to reset.
- **Trusted / Blocked switches.**
- **Battery gauge in the row subtitle.** Five segments map one-to-one onto
  the kernel's levels (Critical, Low, Normal, High, Full), or 20% each when a
  device reports a percentage. Filled segments use the theme accent, switching
  to the theme urgent colour at Low/Critical (20% or below). The level word
  follows, with a bolt when charging.
- **Keyboard:** `j`/`k` move, `i` details, `r` rename, `x` forget,
  Enter connect/disconnect, Esc close.

## How it works

- **`bt-details <mac>…`** (bash + jq) prints JSON keyed by lowercase MAC:
  - `profiles` and `hardwareId`, from `bluetoothctl info`
  - `battery`: finds a `/sys/class/power_supply/*` entry whose name or
    `model_name` contains the MAC. Falls back to BlueZ's "Battery Percentage".
- **`Panel.qml`** runs the helper through a Quickshell `Process`:
  - when the panel opens
  - every 10 s while it's open
  - when connections change

  It covers connected devices plus the expanded one, and the results are
  stored in `extras`.
- **`Model.js`:**
  - `deviceLabel` prefers the alias (`device.name`), so renames show.
  - `batteryText` and `deviceType` format the row and card text.
- **Rename / trust / block** write `device.name`, `device.trusted` and
  `device.blocked` on Quickshell's BluetoothDevice, which maps straight onto
  BlueZ.

## Development notes

- **Hot reload doesn't pick up edits** to an already-loaded plugin. The shell
  logs "Local plugin changed" but keeps serving the cached file. After editing,
  run `omarchy restart shell`. That's how the "helper never runs" issue was
  found: the old code was still loaded.
- **`console.log` from the plugin doesn't reach `quickshell log`.** For
  debugging, add a temporary `IpcHandler` with a function that returns state as
  a string, and call it with `omarchy-shell <target> <fn>`.
- **The panel grabs the keyboard while it's open, and `x` forgets the selected
  device.** Always close it after testing. (The controller was unpaired once
  this way during development.)
- **The panel opens on the focused monitor.** When automating with `wtype`,
  screenshot that monitor.
- **The scanner loads user plugins through symlinked folders**
  (`"$dir"/*/`), so the symlink setup works.

## Bugs fixed along the way

- **Details and forget buttons never appeared.** The button row's `visible`
  was bound to its children's `visible`, but a child reads as hidden while its
  parent is hidden, so it could never turn on. It's now bound to the
  underlying conditions.
- **The `i` and `r` keys did nothing on first open.** They used
  `focusedDeviceAddress`, which isn't set until the cursor moves. They now look
  up `deviceAt(focusSection, selectedIndex)`.
- **`Super+Ctrl+B` opened nothing.** It pointed at `omarchy.bluetooth`.
  Overridden in `bindings.lua`.

## Next steps

1. Click-test the Trusted and Blocked switches. Unblock straight after testing
   Blocked, since it disconnects the device.
2. Nice-to-haves:
   - battery level on the bar icon, or a tooltip
   - a low-battery notification for controllers
   - a wake-allowed switch
   - device-type icons in rows
3. Check the look in a light theme.
4. Before an Omarchy update, diff `plugin/Panel.qml` against the upstream
   `/usr/share/omarchy/shell/plugins/panels/bluetooth/Panel.qml` to pick up
   upstream fixes.

## Reverting

Put the stock widget back in the bar:

```bash
sed -i 's/"chee.bluetooth"/"omarchy.bluetooth"/' ~/.config/omarchy/shell.json
```

Then remove the symlink (`rm ~/.config/omarchy/plugins/chee.bluetooth`) and
the `SUPER + CTRL + B` override in `~/.config/hypr/bindings.lua`. Run
`omarchy restart shell` afterwards.

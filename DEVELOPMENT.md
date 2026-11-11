# Developing Bluechip

Technical notes for working on Bluechip. For installing and using it, see
[README.md](README.md). For philosophy, performance findings and future ideas,
see [PROJECT.md](PROJECT.md).

## Slot replacement

Bluechip started from `omarchy plugin clone omarchy.bluetooth` and keeps
`"omarchy": { "clonedFrom": "omarchy.bluetooth" }` in `manifest.json` alongside
the stock `moduleName` / `ipcTarget` (`omarchy.bluetooth`) in `Panel.qml`. With
both in place:

- `omarchy plugin add … --enable` puts Bluechip in the stock widget's spot in
  the bar without disturbing the rest of the bar layout.
- Shell calls targeting `omarchy.bluetooth`—including the default
  `Super+Ctrl+B` (`omarchy-shell shell toggle omarchy.bluetooth`)—route to
  Bluechip through `PluginRegistry.resolveEnabledId`, and direct IPC calls hit
  its `ShellIpc` handler over Omarchy's in-process socket.

Upstream original, for comparison:
`/usr/share/omarchy/shell/plugins/panels/bluetooth/`.

## Files

| File | Role |
|------|------|
| `manifest.json` | Plugin manifest (ID `io.github.chizzler.bluechip`) |
| `Panel.qml` | Bar button, lazy popup, in-place list models, details card, rename, switches and gauge |
| `Model.js` | Pure helpers: labels, uniform row schema, battery gauge model, device type names and glyphs |
| `bt-details` | Bash + jq helper. Prints extra per-device details as JSON |

## Architecture

- **`bt-details <mac>…`** prints JSON keyed by lowercase MAC in three processes
  total (`bash`, one `busctl`, one `jq`), regardless of device count.
  - `profiles` and `hardwareId`: read from BlueZ `Device1` (`UUIDs`,
    `Modalias`) via a single `ObjectManager.GetManagedObjects` call. Common SIG
    UUIDs map to names; others show as `0x…`.
  - `battery`: `{source, percent, level, status}` from the
    `/sys/class/power_supply` entry whose HID parent's `uevent` has
    `HID_UNIQ=<mac>`, falling back to a MAC in the supply's directory name
    (hid-sony, hid-playstation, hid-nintendo) when `HID_UNIQ` is missing or a
    USB serial. `-`/`_` separators normalise to `:`. Batteries reported by
    BlueZ itself already arrive via Quickshell's `device.battery`, so the
    helper doesn't duplicate them.
- **Detail refreshes (`Panel.qml`):** runs `bt-details` on open, every 10 s
  while open, and when `connectedKey` changes—covering connected devices plus
  `expandedAddress`. Same-turn requests coalesce via `Qt.callLater`, overlapping
  runs queue one follow-up via `detailsDirty`, and identical JSON (`extrasText`)
  is ignored so bindings don't re-evaluate unnecessarily.
- **Lazy popup & idle state:** `KeyboardPanel` builds its `content` component
  on first open rather than on every monitor at startup. `DeviceDetails` and
  `ConfirmDialog` each sit behind a `Loader` so neither exists while closed.
  While closed with no action in flight (`!opened && !hasPendingActions`),
  `deviceGroups` sleeps and `icon` uses `Model.hasConnectedDevice`.
- **In-place list models:** `connectedModel` (`Repeater`) and `scrollModel`
  (`ListView`) are `ListModel`s synced in place (`syncRowModel`) over a fixed
  primitive schema (`Model.rowKeys`). Scan updates only insert, move, remove or
  update changed rows, preserving open cards and active edits in `renameField`.
  Models stay frozen on close so the fade-out doesn't flash empty.
- **Device properties & labels:** rename, Trusted and Blocked write `name`,
  `trusted` and `blocked` directly on Quickshell's `BluetoothDevice` (BlueZ
  `Device1`). An empty name clears the alias. `Model.deviceLabel` prefers the
  alias unless it looks like a MAC or UUID, falling back to `deviceName`.
- **Battery gauge:** `Model.batteryLevel` resolves BlueZ percentage or driver
  percentage/coarse `capacity_level` into 0–5 segments (`Commons.Color.accent`,
  or `Commons.Color.urgent` at ≤20% / Low / Critical) and pairs it with the
  driver's `status` (`Charging`, `Full` → `Charged`, `Not charging`).
- **Connect feedback:** `omarchy-bluetooth-device` ends every `bluetoothctl`
  call with `|| true`, so its exit code carries no status. Connect and pair run
  it via a per-attempt `Process` (`sh -c 'setsid "$@" & wait $!'`) so `setsid`
  protects in-flight pairings across shell restarts while `wait` reports exit.
  - If the row is still `"connecting"` on exit, a `settle` timer waits 1.5 s
    for BlueZ to report `Connected`; otherwise it records `"Couldn't pair"` or
    `"Couldn't connect"` for 6 s and destroys the `Process`.
  - Known gap: a device that connects and drops again inside that 1.5 s window
    shows `"Couldn't connect"`.
  - Duplicate clicks while an attempt is running are ignored, and
    `pendingTimeout` (20 s) spares entries whose helper is still running (since
    pairing can take over 40 s).
- **Forget confirmation:** `requestForget` sets `forgetTarget`, activating the
  `ConfirmDialog` loader, growing the panel to at least `Style.space(170)`,
  blocking `PanelKeyCatcher`, and handing focus to `forgetKeys`.

## Workflow and gotchas

- **Restart after edits.** Hot reload logs "Local plugin changed" but keeps
  serving the cached component; run `omarchy restart shell`.
- **Symlinked checkouts work.** The plugin scanner globs `"$dir"/*/`, so
  `~/.config/omarchy/plugins/io.github.chizzler.bluechip` can symlink here.
- **`console.log` doesn't reach `quickshell log`.** To inspect live state, add
  a temporary function on `ShellIpc` returning a string and call
  `omarchy-shell omarchy.bluetooth <function>`.
- **Keyboard grab during `wtype` tests.** `x` then `Enter` forgets the selected
  device; always close the panel in the same `wtype` command.
- **Screenshots:** the panel opens on the focused monitor—capture that output.
- **QML `visible` trap:** a child's `visible` reads `false` while its parent is
  hidden. Never bind a container's `visible` to its children's `visible`.

## Keeping up with upstream

After Omarchy updates, diff `/usr/share/omarchy/shell/plugins/panels/bluetooth/`
(`Panel.qml` and `Model.js`) against Bluechip and port relevant changes. Synced
with Omarchy 4.0.6 (`Commons.Color`, `ShellIpc`, and lazy `KeyboardPanel`
content).

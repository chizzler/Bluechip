# Bluechip

## Philosophy

Bluechip is built around three ideas:

1. **Belong to the shell, don't imitate it.** Replacing a built-in bar widget
   shouldn't feel like bolting on a separate app. Bluechip steps into
   `omarchy.bluetooth`'s slot, uses Omarchy's own surfaces, typography, theme
   tokens, IPC and keyboard navigation, and stays visually indistinguishable
   from the rest of the bar.
2. **Surface what Linux already knows.** Desktop Bluetooth menus usually stop
   at BlueZ's `Device1` and `Battery1`—hiding controller batteries published
   under `/sys/class/power_supply`, Bluetooth aliases, profile UUIDs and silent
   connection failures. Bluechip bridges BlueZ and kernel input drivers cleanly
   without a background daemon or extra configuration files.
3. **Cost nothing while closed.** A bar widget lives inside the shell on every
   monitor for the whole session. When closed and idle, it should hold minimal
   memory and do near-zero work, waking up only while open or while an action
   settles.

For installation and usage, see [README.md](README.md). For architecture and
development workflow, see [DEVELOPMENT.md](DEVELOPMENT.md).

---

## Performance Findings

### Baseline strengths

- **Single-shot helper (`bt-details`):** runs three processes (`bash`, one
  `busctl GetManagedObjects`, one `jq`, ~6 ms total) however many devices are
  queried.
- **Scoped polling:** runs only while the panel is open, triggers on
  `connectedKey` rather than scan churn, coalesces overlapping runs, and skips
  `JSON.parse` when the JSON string hasn't changed.
- **Primitive row projection:** `Model.deviceRow` keeps live `BluetoothDevice`
  QObjects out of delegates, avoiding wrapper overhead and mid-incubation
  crashes when BlueZ removes devices.

### Implemented (high impact)

1. **Lazy popup tree, lazy `ConfirmDialog`, and `ShellIpc` (`Panel.qml`)**
   - Moved the popup body into `KeyboardPanel`'s lazy `content` component and
     wrapped `ConfirmDialog` in an on-demand `Loader`, so no popup items or
     delegates are built on any monitor at shell startup until first open.
   - Switched `IpcHandler` to `ShellIpc` so direct `omarchy-shell
     omarchy.bluetooth …` calls use Omarchy's ~5 ms socket (`IpcRegistry`)
     instead of spawning a ~45 ms `qs ipc` client.
   - Added `Text.PlainText` to the hero title to skip rich-text auto-detection.

2. **In-place `ListModel` syncing during scans (`Panel.qml`, `Model.js`)**
   - Replaced array-swapped `Repeater` and `ListView` models—which tore down
     and rebuilt every row delegate on each BLE discovery tick and wiped active
     edits in `renameField`—with persistent `ListModel`s (`connectedModel`,
     `scrollModel`) synced in place over a fixed primitive schema
     (`Model.rowKeys`).
   - Replaced the linear `scrollRowIndex` lookup with direct index calculation,
     and kept models frozen on close so the fade-out animation doesn't flash
     empty.

3. **Closed-panel quiescence (`Panel.qml`, `Model.js`)**
   - Gated `deviceGroups` on `opened || hasPendingActions`, preserving
     post-close connection tracking and PipeWire sink switching while sleeping
     when idle.
   - Added `Model.hasConnectedDevice` (checking `d.connected` before
     `hasHumanName`) so the bar icon updates cheaply while closed.
   - Consolidated the three per-section change handlers into one
     `onDeviceGroupsChanged`, guarded `syncPendingActions()` when empty,
     coalesced same-turn `refreshDetails()` calls, and moved `Pipewire.nodes`
     reads into `audioSinks()` on demand.

### Remaining opportunities (medium & low impact)

4. **Lighter `DeviceRow` delegates (`Panel.qml`) — *Medium***
   - `BatteryGauge` (9 `QQuickItem`s including a 5-segment `Repeater`) is built
     for every row even though `row.battery` is always `null` outside the
     connected list. A `Loader { active: !!row.battery }` drops it from
     `scrollModel` rows completely.
   - In `"discovered"` rows, `forgetAvailable` is always `false`, yet each row
     still builds two `PanelActionButton`s (and their `PanelToolTip`s). Loading
     `actions` only when `forgetAvailable` (or hovered/selected/expanded) would
     lighten scan-time delegates further.

5. **Regex, label, and sort cleanups (`Model.js`) — *Medium***
   - In `isUuidLike`, `/^0000[0-9a-f]{4}-0000-1000-8000-00805f9b34fb$/i` is a
     subset of the standard UUID regex above it and never matches on its own.
     Dropping it and hoisting the remaining regexes to module scope avoids
     redundant work on every device name.
   - `hasHumanName` re-runs `isUuidLike` / `isAddressLike` on aliases already
     checked by `deviceLabel`, and `sortedByLabel` recomputes `deviceLabel` and
     `localeCompare` on every sort comparison. Computing `label` and a
     lowercase sort key once per device cuts string and collation work during
     discovery.
   - `bluetoothSinkMatchesDevice` can check `props["api.bluez5.address"]` /
     `props["bluez5.address"]` directly before concatenating 15 PipeWire node
     fields into `nodeText(node)`.

6. **`bt-details` streaming and timer polish (`bt-details`, `Panel.qml`) — *Low***
   - Piping `busctl … 2>/dev/null | jq -n '(try input.data[0] catch {}) …'`
     streams directly over a kernel pipe instead of buffering `$objects` in bash
     and spilling `<<<"$objects"` to `/tmp` when BlueZ's GATT cache is large.
   - Adding `shopt -s nullglob` avoids a dummy loop pass when
     `/sys/class/power_supply` is empty; `break`ing once `HID_UNIQ` matches
     skips the rest of `uevent`.
   - `detailsTimer.running` can require `connectedDevices.length > 0 ||
     expandedAddress !== ""`, and 10 s battery refreshes could skip `busctl`
     when target MACs already have static `profiles` and `hardwareId` cached.

7. **Per-row vs whole-map state updates (`Panel.qml`) — *Low***
   - Updating `extras`, `pendingActions` or `failures` via `Model.withEntry`
     re-evaluates bindings on every visible `DeviceRow`. Negligible at normal
     device counts, though folding those states into `ListModel` roles would
     scope updates to a single row.

---

## Ideas

- Battery indicator on the bar icon, or a hover tooltip
- Low-battery notification
- Wake-allowed switch (`WakeAllowed` on `Device1`)
- Audio profile switch (A2DP / HFP)
- Background reconnect for devices that don't reconnect on their own

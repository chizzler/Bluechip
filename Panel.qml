import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.bluetooth"
  ipcTarget: "omarchy.bluetooth"
  // manageIpc: false so this panel can own the single ShellIpc the target
  // permits — needed for the toggleBluetooth method below.
  manageIpc: false

  // Address -> "connecting" | "disconnecting" | "forgetting".
  // The actual Bluetooth sequencing lives in bin/omarchy-bluetooth-device;
  // this map only keeps the panel responsive while BlueZ catches up.
  property var pendingActions: ({})

  readonly property var adapter: Bluetooth.defaultAdapter

  // True while this instance owes BlueZ a StopDiscovery: set when it starts
  // discovery (or opens onto a session already running) and cleared once
  // discovery is confirmed down after close. Ownership, not state — BlueZ's
  // Discovering property also reflects sessions other clients hold, which are
  // never this panel's to stop.
  property bool owesDiscoveryStop: false
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  property var pendingAudioOutputDevice: null
  property int pendingAudioOutputAttempts: 0

  // Address whose details card is open, the one being renamed, and extra
  // details (driver battery, profiles, hardware ID) from the bt-details helper.
  property string expandedAddress: ""
  property string renamingAddress: ""
  property var extras: ({})
  property bool detailsDirty: false
  property bool detailsRefreshQueued: false
  property string extrasText: ""
  readonly property string detailsHelper: String(Qt.resolvedUrl("bt-details")).replace(/^file:\/\//, "")

  // Connect/pair feedback. omarchy-bluetooth-device swallows bluetoothctl's
  // errors, so a failure is read from the device state once the helper exits.
  //   runningConnects: address -> true while a helper this instance started runs
  //   failures:        address -> { message } shown on the row
  property var runningConnects: ({})
  property var failures: ({})
  readonly property int connectGraceMs: 1500
  readonly property int failureShowMs: 6000

  // Device the forget dialog is asking about: { address, label }, or null.
  property var forgetTarget: null

  function deviceLabel(device) {
    return Model.deviceLabel(device)
  }

  function isUuidLike(value) {
    return Model.isUuidLike(value)
  }

  function isAddressLike(value) {
    return Model.isAddressLike(value)
  }

  function hasHumanName(device) {
    return Model.hasHumanName(device)
  }

  // While the panel is closed and no action is in flight, avoid sorting and
  // projecting the full BlueZ device list on every monitor; the bar button
  // only needs to know whether any human-named device is connected.
  readonly property bool hasPendingActions: Model.hasEntries(pendingActions)
  readonly property var emptyDeviceGroups: ({ connected: [], known: [], discovered: [] })
  readonly property var deviceGroups: opened || hasPendingActions
    ? Model.deviceLists(devices)
    : emptyDeviceGroups
  readonly property var connectedDevices: deviceGroups.connected || []
  readonly property var knownDevices: deviceGroups.known || []
  readonly property var discoveredDevices: deviceGroups.discovered || []
  readonly property bool anyConnected: opened || hasPendingActions
    ? connectedDevices.length > 0
    : Model.hasConnectedDevice(devices)

  readonly property string icon: {
    if (!adapter) return ""
    if (!adapter.enabled) return "󰂲"
    if (anyConnected) return "󰂱"
    return "󰂯"
  }

  property int phraseIndex: 0
  readonly property var activePhrases: [
    "Untangling wires",
    "Streaming vikings",
    "Pairing mysteries",
    "Herding headsets",
    "Taming radios",
    "Summoning speakers",
    "Wrangling codecs",
    "Polishing packets"
  ]
  readonly property bool rotatingPhrases: adapter && adapter.enabled
  readonly property string heroStatusText: {
    if (!adapter) return "No adapter"
    if (!adapter.enabled) return "Turned Off"
    return activePhrases[phraseIndex % activePhrases.length]
  }

  // Single cursor model shared by keyboard and mouse. Sections:
  //   "connected"  — currently connected devices; Enter disconnects.
  //   "known"      — remembered devices; Enter connects.
  //   "discovered" — unremembered devices visible while scanning; Enter connects.
  // Visuals always come from CursorSurface (hasCursor / current),
  // never from containsMouse. Mouse hover updates root cursor state too,
  // guaranteeing one highlight on screen.
  property string focusSection: "connected"
  property int selectedIndex: 0
  property bool actionFocused: false
  property bool cursorActive: false

  // Stable identity for the focused device. Devices move between sections as
  // they connect, disconnect, pair, or get forgotten, so follow the BlueZ
  // address across section changes instead of preserving a stale row index.
  property string focusedDeviceAddress: ""

  // "header" is a virtual section for the hero Bluetooth on/off toggle; it
  // sits above the device sections so the adapter can be toggled by keyboard
  // even when it is off and no device rows exist.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property string toggleHint: root.adapter && root.adapter.enabled ? "Turn Bluetooth off" : "Turn Bluetooth on"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"

  function sectionCount(section) {
    if (section === "connected") return connectedDevices.length
    if (section === "known") return knownDevices.length
    if (section === "discovered") return discoveredDevices.length
    return 0
  }

  function sectionVisible(section) {
    if (section === "connected") return connectedDevices.length > 0
    if (section === "known") return knownDevices.length > 0
    if (section === "discovered") return adapter && adapter.discovering && discoveredDevices.length > 0
    return false
  }

  readonly property var visibleSections: {
    return Model.visibleSections(deviceGroups, adapter && adapter.discovering)
  }

  function devicesForSection(section) {
    return Model.sectionDevices(deviceGroups, section)
  }

  // In-place ListModels so discovery updates add, move, or remove only the
  // rows that changed instead of resetting the Repeater and ListView (which
  // previously rebuilt every delegate and wiped an active rename mid-typing).
  // Models stay frozen on close so the fade-out animation doesn't flash empty.
  ListModel { id: connectedModel }
  ListModel { id: scrollModel }

  function updateRowInPlace(listModel, index, next) {
    var cur = listModel.get(index)
    var keys = Model.rowKeys
    for (var k = 0; k < keys.length; k++) {
      var field = keys[k]
      if (cur[field] !== next[field]) listModel.setProperty(index, field, next[field])
    }
  }

  function syncRowModel(listModel, rows) {
    var keep = Object.create(null)
    for (var n = 0; n < rows.length; n++) keep[rows[n].key] = true

    for (var r = listModel.count - 1; r >= 0; r--) {
      if (!keep[listModel.get(r).key]) listModel.remove(r, 1)
    }

    for (var i = 0; i < rows.length; i++) {
      var next = rows[i]
      if (i < listModel.count && listModel.get(i).key === next.key) {
        updateRowInPlace(listModel, i, next)
        continue
      }
      var found = -1
      for (var j = i + 1; j < listModel.count; j++) {
        if (listModel.get(j).key === next.key) { found = j; break }
      }
      if (found >= 0) {
        listModel.move(found, i, 1)
        updateRowInPlace(listModel, i, next)
      } else {
        listModel.insert(i, next)
      }
    }
  }

  function syncDeviceModels() {
    if (!opened) return

    var connectedRows = []
    for (var i = 0; i < connectedDevices.length; i++)
      connectedRows.push(Model.deviceRow(connectedDevices[i], "connected", i, "", false))
    syncRowModel(connectedModel, connectedRows)

    var scrollRows = []
    for (var k = 0; k < knownDevices.length; k++)
      scrollRows.push(Model.deviceRow(knownDevices[k], "known", k, k === 0 ? "PAIRED" : "", false))
    if (sectionVisible("discovered")) {
      for (var d = 0; d < discoveredDevices.length; d++) {
        var title = d === 0 ? "AVAILABLE" : ""
        scrollRows.push(Model.deviceRow(discoveredDevices[d], "discovered", d, title, scrollRows.length > 0 && title !== ""))
      }
    }
    syncRowModel(scrollModel, scrollRows)
  }

  // Live BlueZ device behind a row. Rows carry primitives only, so actions
  // resolve the backend object here rather than holding a wrapper that can
  // dangle mid-incubation. `devices` is already the raw device array (see the
  // property declaration), so it is iterated directly.
  function deviceFor(row) {
    return row && row.dev ? deviceForAddress(row.dev.address || "") : null
  }

  // Flat position of the keyboard cursor, or -1 while it sits on the hero or
  // in the connected list (both of which live outside the scroll area).
  readonly property int scrollRowIndex: {
    if (selectedIndex < 0) return -1
    if (focusSection === "known")
      return selectedIndex < knownDevices.length ? selectedIndex : -1
    if (focusSection === "discovered" && sectionVisible("discovered"))
      return selectedIndex < discoveredDevices.length ? knownDevices.length + selectedIndex : -1
    return -1
  }

  function audioSinks() {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    var sinks = []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (node && node.isSink && !node.isStream) sinks.push(node)
    }
    return sinks
  }

  function bluetoothAudioSink(device) {
    var sinks = audioSinks()
    for (var i = 0; i < sinks.length; i++) {
      if (Model.bluetoothSinkMatchesDevice(sinks[i], device)) return sinks[i]
    }
    return null
  }

  function setDefaultAudioSink(sink) {
    if (!sink) return
    Pipewire.preferredDefaultAudioSink = sink
    if (sink.id !== undefined && sink.name) {
      Quickshell.execDetached([
        "omarchy-audio-output-set-default",
        String(sink.id),
        String(sink.name)
      ])
    }
  }

  function scheduleAudioOutputSwitch(device) {
    pendingAudioOutputDevice = {
      address: device && device.address ? device.address : "",
      name: device && device.name ? device.name : "",
      deviceName: device && device.deviceName ? device.deviceName : ""
    }
    pendingAudioOutputAttempts = 0
    audioSwitchTimer.restart()
  }

  function switchPendingAudioOutput() {
    if (!pendingAudioOutputDevice) return

    var sink = bluetoothAudioSink(pendingAudioOutputDevice)
    if (sink) {
      setDefaultAudioSink(sink)
      pendingAudioOutputDevice = null
      audioSwitchTimer.stop()
      return
    }

    pendingAudioOutputAttempts += 1
    if (pendingAudioOutputAttempts >= 8) {
      pendingAudioOutputDevice = null
      return
    }
    audioSwitchTimer.restart()
  }

  function deviceAt(section, index) {
    var list = devicesForSection(section)
    return index >= 0 && index < list.length ? list[index] : null
  }

  function cloneMap(map) {
    return Model.cloneMap(map)
  }

  function pendingAction(address) {
    return Model.pendingAction(pendingActions, address)
  }

  function setPendingAction(address, action) {
    if (!address) return
    pendingActions = Model.withPendingAction(pendingActions, address, action)
    if (action) pendingTimeout.restart()
  }

  function deviceCommand(action, address) {
    return ["omarchy-bluetooth-device", action, address]
  }

  function runDeviceAction(device, action, pending) {
    if (!device || !device.address) return
    setPendingAction(device.address, pending)
    Quickshell.execDetached(deviceCommand(action, device.address))
  }

  function connectDevice(device) {
    if (!device || !device.address || device.connected) return
    // A second click while one attempt runs would start a second helper.
    if (runningConnects[device.address]) return
    var action = device.paired || device.bonded || device.trusted ? "connect" : "pair"
    var address = device.address
    clearFailure(address)
    setPendingAction(address, "connecting")
    runningConnects = Model.withEntry(runningConnects, address, true)
    var proc = connectProcess.createObject(root, { address: address, helperAction: action })
    // setsid puts the helper in its own session, so a shell restart (which
    // kills this Process) cannot cut a pairing off halfway. `wait` keeps the
    // Process alive until the helper exits, which is what onExited reports.
    proc.command = ["sh", "-c", "setsid \"$@\" & wait $!", "sh"].concat(deviceCommand(action, address))
    proc.running = true
  }

  // Called once the grace period after a helper exit is over. A device that
  // still has not connected failed, unless something else has taken over its
  // row: success clears the "connecting" mark (syncPendingActions), and so
  // does any later action such as a forget. Returns the failure entry it
  // recorded, or null.
  function failConnect(address, action) {
    var dev = deviceForAddress(address)
    if (!dev || dev.connected || runningConnects[address]) return null
    if (pendingAction(address) !== "connecting") return null
    setPendingAction(address, "")
    var entry = { message: action === "pair" && !(dev.paired || dev.bonded) ? "Couldn't pair" : "Couldn't connect" }
    failures = Model.withEntry(failures, address, entry)
    return entry
  }

  function failureFor(address) {
    var f = address ? failures[address] : null
    return f ? f.message : ""
  }

  // With entry, clears only that failure, so an older attempt's expiry never
  // removes the message of a newer one on the same device.
  function clearFailure(address, entry) {
    var current = failures[address]
    if (current && (!entry || current === entry)) failures = Model.withEntry(failures, address, null)
  }

  // Every way to forget (button, x, right-click) asks first: a forgotten
  // device has to be paired again from scratch.
  function requestForget(device) {
    if (!device || !device.address) return
    if (renamingAddress !== "") cancelRename()
    forgetTarget = { address: device.address, label: deviceLabel(device) || "this device" }
  }

  function confirmForget() {
    var target = forgetTarget
    forgetTarget = null
    if (target) forgetDevice(deviceForAddress(target.address))
  }

  function cancelForget() {
    forgetTarget = null
  }

  function disconnectDevice(device) {
    if (!device || !device.address) return
    if (!device.connected) return
    setPendingAction(device.address, "disconnecting")
    if (device.disconnect) device.disconnect()
    Quickshell.execDetached(deviceCommand("disconnect", device.address))
  }

  function forgetDevice(device) {
    if (!device || !device.address) return
    runDeviceAction(device, "forget", "forgetting")
  }

  function deviceForAddress(address) {
    var devs = devices || []
    for (var i = 0; i < devs.length; i++)
      if ((devs[i].address || "") === address) return devs[i]
    return null
  }

  function extraFor(address) {
    return Model.extraFor(extras, address)
  }

  function toggleDetails(address) {
    if (!address) return
    if (renamingAddress !== "" && renamingAddress !== address) cancelRename()
    expandedAddress = expandedAddress === address ? "" : address
    refreshDetails()
  }

  function startRename(address) {
    var dev = deviceForAddress(address)
    if (!dev) return
    expandedAddress = address
    renamingAddress = address
  }

  // Writes the BlueZ alias. An empty name clears it, so BlueZ falls back to
  // the name the device advertises.
  function commitRename(text) {
    var dev = deviceForAddress(renamingAddress)
    if (dev) dev.name = String(text || "").trim()
    renamingAddress = ""
  }

  function cancelRename() {
    renamingAddress = ""
  }

  // key is a writable BluetoothDevice flag: "trusted" or "blocked".
  function setDeviceFlag(address, key, on) {
    var dev = deviceForAddress(address)
    if (dev) dev[key] = on
  }

  // Connected devices (for battery) plus whichever card is open. Coalesced per
  // event-loop turn so simultaneous open + connectedKey signals run once.
  function refreshDetails() {
    if (!opened || detailsRefreshQueued) return
    detailsRefreshQueued = true
    Qt.callLater(runRefreshDetails)
  }

  function runRefreshDetails() {
    detailsRefreshQueued = false
    if (!opened) return
    if (detailsProc.running) { detailsDirty = true; return }
    var addrs = []
    for (var i = 0; i < connectedDevices.length; i++)
      if (connectedDevices[i].address) addrs.push(connectedDevices[i].address)
    if (expandedAddress !== "" && addrs.indexOf(expandedAddress) < 0) addrs.push(expandedAddress)
    if (addrs.length === 0) return
    detailsProc.command = [detailsHelper].concat(addrs)
    detailsProc.running = true
  }

  // Hand keys back to the panel cursor once the rename field closes.
  onRenamingAddressChanged: {
    if (renamingAddress === "" && opened)
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  function syncPendingActions() {
    if (!hasPendingActions) return
    var next = cloneMap(pendingActions)
    var changed = false

    for (var address in next) {
      var action = next[address]
      var found = null

      for (var i = 0; i < devices.length; i++) {
        var d = devices[i]
        if (d && d.address === address) {
          found = d
          break
        }
      }

      var finishedConnecting = action === "connecting" && found && found.connected
      if (finishedConnecting
          || (action === "disconnecting" && found && !found.connected)
          || (action === "forgetting" && (!found || (!found.paired && !found.bonded && !found.trusted)))) {
        if (finishedConnecting) scheduleAudioOutputSwitch(found)
        delete next[address]
        changed = true
      }
    }

    if (changed) pendingActions = next
  }

  // j/k navigates the hero toggle ("header") and the device sections
  // row-by-row.
  function moveCursor(delta) {
    var sections = visibleSections
    if (focusSection === "header") {
      if (delta > 0 && sections && sections.length > 0) {
        focusSection = sections[0]; selectedIndex = 0; actionFocused = false
      }
      return
    }
    if (!sections || sections.length === 0) { focusSection = "header"; actionFocused = false; return }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = 0; actionFocused = false; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1

    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; actionFocused = false; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = 0
        actionFocused = false
      }
    } else {
      if (idx > 0) { selectedIndex = idx - 1; actionFocused = false; return }
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        selectedIndex = sectionCount(focusSection) - 1
        actionFocused = false
      } else {
        focusSection = "header"; actionFocused = false
      }
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    actionFocused = false
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev || !dev.address) return
    if (delta > 0) actionFocused = true
    else if (delta < 0) actionFocused = false
  }

  function activateCursor() {
    if (focusSection === "header") {
      toggleBluetooth()
      return
    }
    if (actionFocused) {
      deleteSelected()
      return
    }

    if (focusSection === "connected" || focusSection === "known") {
      var dev = deviceAt(focusSection, selectedIndex)
      if (!dev) return
      if (dev.connected) disconnectDevice(dev)
      else connectDevice(dev)
      return
    }
    if (focusSection === "discovered") {
      var d = discoveredDevices[selectedIndex]
      if (!d) return
      connectDevice(d)
    }
  }

  // 'x' forgets remembered devices, after confirmation. For connected devices
  // this first disconnects, then removes the BlueZ pairing record via
  // omarchy-bluetooth-device.
  function deleteSelected() {
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev) return
    requestForget(dev)
  }

  property bool pendingOpenFocus: false

  function pickInitialSection() {
    if (connectedDevices.length > 0) { focusSection = "connected"; selectedIndex = 0 }
    else if (knownDevices.length > 0) { focusSection = "known"; selectedIndex = 0 }
    else if (sectionVisible("discovered")) { focusSection = "discovered"; selectedIndex = 0 }
    else { focusSection = "header"; selectedIndex = 0 }
  }

  onOpenedChanged: {
    if (opened) {
      // Adopt a discovery session that is already running — a popout handoff
      // from another monitor, or one leaked by an instance that could not
      // finish its own stop — so this close settles it either way.
      if (adapter !== null && adapter.discovering) owesDiscoveryStop = true
      actionFocused = false
      cursorActive = false
      focusedDeviceAddress = ""
      if (deviceGroups !== emptyDeviceGroups) {
        pendingOpenFocus = false
        pickInitialSection()
        syncDeviceModels()
      } else {
        pendingOpenFocus = true
      }
      refreshDetails()
    } else {
      pendingOpenFocus = false
      renamingAddress = ""
      expandedAddress = ""
      forgetTarget = null
    }
  }

  // Hand keys back to the panel cursor once the forget dialog closes.
  onForgetTargetChanged: {
    if (forgetTarget === null && opened)
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  // Another per-monitor instance of this widget whose panel is open, if any.
  // All instances share the default adapter, and switching the popout to a
  // different monitor closes one instance as it opens the next, so the
  // closing side has to leave the scan alone for the side still on screen.
  function openSibling() {
    if (!bar || typeof bar.moduleWidgets !== "function") return null
    var items = bar.moduleWidgets(moduleName)
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && items[i].opened === true) return items[i]
    }
    return null
  }

  function updateFocusedAddress() {
    var d = deviceAt(focusSection, selectedIndex)
    focusedDeviceAddress = d ? (d.address || "") : ""
  }

  function reselectFocusedDevice() {
    if (focusedDeviceAddress === "") {
      clampCursor()
      return
    }

    var sections = ["connected", "known", "discovered"]
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s]
      if (!sectionVisible(section)) continue
      var list = devicesForSection(section)
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].address === focusedDeviceAddress) {
          focusSection = section
          selectedIndex = i
          clampCursor()
          return
        }
      }
    }

    clampCursor()
  }

  onSelectedIndexChanged: updateFocusedAddress()
  onFocusSectionChanged: updateFocusedAddress()
  onDeviceGroupsChanged: {
    if (hasPendingActions) syncPendingActions()
    if (!opened) return
    if (pendingOpenFocus) {
      pendingOpenFocus = false
      pickInitialSection()
    } else {
      reselectFocusedDevice()
    }
    syncDeviceModels()
  }
  // connectedDevices is rebuilt on every list change during a scan; the
  // string only changes when the set of connected devices does.
  readonly property string connectedKey: opened
    ? connectedDevices.map(function(d) { return d.address }).join(",")
    : ""
  onConnectedKeyChanged: if (opened) refreshDetails()
  onVisibleSectionsChanged: if (opened) clampCursor()

  function clampCursor() {
    var sections = visibleSections
    // "header" is virtual and never appears in visibleSections, so it has to
    // be let through: toggling the adapter empties and refills the device
    // lists, and clamping would knock the cursor off the hero switch every
    // time it is used.
    if (focusSection === "header") return
    if (!sections || !sections.length) {
      selectedIndex = 0
      return
    }
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = 0
      return
    }
    var count = sectionCount(focusSection)
    if (count === 0) {
      // Section emptied out — bounce to the previous visible one.
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = Math.max(0, sectionCount(focusSection) - 1)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  visible: adapter !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // BlueZ rejects StartDiscovery while the adapter is still powering up, and
  // discovery can also time out on its own. While the panel is open, keep
  // nudging it back on so an enabled adapter is always scanning.
  Timer {
    id: discoveryRetry
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.adapter !== null && root.adapter.enabled && !root.adapter.discovering
    onTriggered: {
      root.owesDiscoveryStop = true
      root.adapter.discovering = true
    }
  }

  // The way back down. The BlueZ discovery session behind adapter.discovering
  // is held by quickshell's D-Bus connection, so nothing ends it at close:
  // without this timer, one visit to the panel left the radio in inquiry
  // until the next shell restart, starving A2DP audio on the same controller
  // into stutters.
  //
  // A timer bound to the confirmed state rather than a write at close time:
  // quickshell only forwards a discovering write that differs from the last
  // state BlueZ reported, so a stop issued while a just-fired StartDiscovery
  // is still awaiting confirmation would be swallowed and leak the session.
  // Binding to adapter.discovering means a confirmation landing at any point
  // after close re-arms the stop, and a reopen inside the first interval
  // keeps the scan running uninterrupted. Attempts are bounded so a session
  // some other BlueZ client keeps up cannot draw StopDiscovery fire forever.
  Timer {
    id: discoveryStop
    interval: 1000
    repeat: true
    property int attempts: 0
    running: !root.opened && root.owesDiscoveryStop && root.adapter !== null && root.adapter.discovering === true
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      // The scan now serves the open panel, so the debt moves with it — B may
      // have opened before BlueZ confirmed A's start, in which case B's own
      // open-time adoption saw nothing to adopt.
      var sibling = root.openSibling()
      if (sibling) {
        sibling.owesDiscoveryStop = true
        root.owesDiscoveryStop = false
        return
      }
      attempts += 1
      if (attempts > 3) { root.owesDiscoveryStop = false; return }
      root.adapter.discovering = false
    }
  }

  // The debt is settled the moment BlueZ reports discovery down — whether
  // because the stop above landed or the session ended some other way — so a
  // stale claim never touches a scan another client starts later. While the
  // panel is open, discoveryRetry re-incurs it as it restarts the scan.
  Connections {
    target: root.adapter
    function onDiscoveringChanged() {
      if (!root.adapter.discovering) root.owesDiscoveryStop = false
      if (root.opened) root.syncDeviceModels()
    }
  }

  // A destroyed instance cannot wait for BlueZ confirmations, so it hands any
  // debt to a surviving sibling — whose declarative stop catches even a start
  // confirmed after this object is gone — and only writes the stop directly
  // when it is the last one standing.
  Component.onDestruction: {
    if (!owesDiscoveryStop) return
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root) { items[i].owesDiscoveryStop = true; return }
    }
    if (adapter !== null && adapter.discovering) adapter.discovering = false
  }

  // Safety net for actions BlueZ never confirms. Connects whose helper is
  // still running are kept: pairing can take over 40 s, and their outcome
  // arrives when their connectProcess exits instead.
  Timer {
    id: pendingTimeout
    interval: 20000
    repeat: false
    onTriggered: {
      var next = ({})
      for (var address in root.pendingActions)
        if (root.runningConnects[address]) next[address] = root.pendingActions[address]
      root.pendingActions = next
      if (Object.keys(next).length > 0) restart()
    }
  }

  // One helper run per connect or pair; see connectDevice. The object lives on
  // after the helper exits: settle waits out the grace period for BlueZ to
  // report Connected, then, if the attempt failed, how long the message shows.
  Component {
    id: connectProcess
    Process {
      id: attempt
      property string address: ""
      property string helperAction: ""
      property var failure: null

      property Timer settle: Timer {
        interval: root.connectGraceMs
        onTriggered: {
          if (!attempt.failure) {
            attempt.failure = root.failConnect(attempt.address, attempt.helperAction)
            if (attempt.failure) { interval = root.failureShowMs; start(); return }
          } else {
            root.clearFailure(attempt.address, attempt.failure)
          }
          attempt.destroy()
        }
      }

      onExited: {
        root.runningConnects = Model.withEntry(root.runningConnects, address, null)
        if (root.pendingAction(address) === "connecting") settle.start()
        else destroy()
      }
    }
  }

  Timer {
    id: detailsTimer
    interval: 10000
    repeat: true
    running: root.opened
    onTriggered: root.refreshDetails()
  }

  Process {
    id: detailsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var json = String(text || "").trim()
        if (json === root.extrasText) return
        try { root.extras = JSON.parse(json || "{}"); root.extrasText = json } catch (e) {}
      }
    }
    onExited: {
      if (!root.detailsDirty) return
      root.detailsDirty = false
      Qt.callLater(root.refreshDetails)
    }
  }

  Timer {
    id: audioSwitchTimer
    interval: 500
    repeat: false
    onTriggered: root.switchPendingAudioOutput()
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: panel.loadedContent ? panel.loadedContent.heroStatus : null; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: panel.loadedContent ? panel.loadedContent.heroStatus : null; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        if (panel.loadedContent) panel.loadedContent.heroStatus.opacity = 1.0
      }
    }
  }

  // Not adapter.enabled: that writes BlueZ's Powered, which nothing persists, so
  // the adapter came back on at the next boot. omarchy-bluetooth-power moves the
  // rfkill soft block instead, which systemd-rfkill restores across reboots.
  // Powered still follows the block, so the switch and icon read it as before.
  //
  // Asking for a direction rather than a toggle: the helper runs detached and the
  // switch only moves once BlueZ catches up, so a second click inside that window
  // would re-read the old state and undo the first.
  function toggleBluetooth() {
    if (!adapter) return
    Quickshell.execDetached(["omarchy-bluetooth-power", adapter.enabled ? "off" : "on"])
  }

  ShellIpc {
    target: "omarchy.bluetooth"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleBluetooth() { root.toggleBluetooth() }
  }


  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleBluetooth()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Room for the forget dialog even when the device list is short.
    contentHeight: panel.fittedContentHeight(root.forgetTarget !== null
      ? Math.max(panel.loadedContentHeight, Style.space(170))
      : panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias heroStatus: heroStatus
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      // The rename field and the forget dialog own input while open.
      blocked: root.renamingAddress !== "" || root.forgetTarget !== null
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.cursorActive) root.deleteSelected()
      onTextKey: function(t) {
        if (t === "b" || t === "B") root.toggleBluetooth()
        var onDevice = root.cursorActive && (root.focusSection === "connected" || root.focusSection === "known")
        var selected = onDevice ? root.deviceAt(root.focusSection, root.selectedIndex) : null
        if (selected && (t === "i" || t === "I")) root.toggleDetails(selected.address)
        if (selected && (t === "r" || t === "R")) root.startRename(selected.address)
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: Bluetooth icon · status ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          // Status only — the switch owns toggling, mouse and keyboard alike.
          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.adapter && root.adapter.enabled ? 1.0 : 0.5
          }

          // Compact on/off switch on the trailing edge of the hero, and the
          // header's only cursor target.
          ToggleSwitch {
            id: powerSwitch
            visible: !!root.adapter
            checked: !!root.adapter && root.adapter.enabled
            hasCursor: root.headerHasCursor
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onHovered: function(on) { if (on) root.setHeaderCursor() }
            onToggled: root.toggleBluetooth()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.toggleHint
              fontFamily: root.bar.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Bluetooth"
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // Scrollable device list — capped so a noisy neighborhood doesn't
        // grow the popup past the screen.
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          id: connectedList
          visible: connectedModel.count > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CONNECTED"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: connectedModel
            DeviceEntry {
              required property var model
              width: connectedList.width
              dev: model
              rowIndex: model.indexInSection
              sectionName: "connected"
              isDiscovered: false
            }
          }
        }

        PanelSeparator {
          visible: connectedModel.count > 0 && scrollModel.count > 0
          foreground: root.bar.foreground
        }

        // ListView, not a Flickable: it owns the scroll position, so it keeps
        // the current row visible on j/k, re-clamps itself when discovery
        // shortens the list, and — because Contain only moves when a row is
        // actually clipped — never lurches under a hovering mouse.
        ListView {
          id: deviceListView
          width: parent.width
          height: Math.min(contentHeight, Style.space(400))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: scrollModel
          currentIndex: root.scrollRowIndex
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: Item {
            required property var model

            width: ListView.view.width
            height: delegateColumn.implicitHeight

            Column {
              id: delegateColumn
              width: parent.width
              spacing: Style.space(10)

              PanelSeparator {
                visible: model.showSeparator
                height: visible ? implicitHeight : 0
                foreground: root.bar.foreground
              }

              PanelSectionHeader {
                visible: model.sectionTitle !== ""
                height: visible ? implicitHeight : 0
                text: model.sectionTitle
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              DeviceEntry {
                width: parent.width
                dev: model
                rowIndex: model.indexInSection
                sectionName: model.section
                isDiscovered: model.section === "discovered"
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: connectedModel.count === 0 && scrollModel.count === 0
          text: !root.adapter ? "No Bluetooth adapter"
              : !root.adapter.enabled ? "Turn Bluetooth on to scan"
              : "Scanning for devices…"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }

      // Forget confirmation, built only while a confirmation is active.
      Loader {
        anchors.fill: parent
        z: 10
        active: root.forgetTarget !== null
        visible: active

        sourceComponent: Item {
          // Stops rows underneath reacting to hover while the dialog is up.
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }

          ConfirmDialog {
            id: forgetConfirm
            anchors.fill: parent
            opened: root.forgetTarget !== null
            selectedIndex: 1
            message: root.forgetTarget
              ? "Forget " + root.forgetTarget.label + "? You'll need to pair it again to use it."
              : ""
            confirmText: "Forget"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onCanceled: root.cancelForget()
            onConfirmed: root.confirmForget()
          }

          // Takes focus while the dialog is open. Every key stops here, so
          // nothing reaches the device list behind it.
          Item {
            id: forgetKeys
            Keys.onPressed: function(event) {
              forgetConfirm.handleKey(event)
              event.accepted = true
            }
            Component.onCompleted: Qt.callLater(function() {
              if (root.forgetTarget) forgetKeys.forceActiveFocus()
            })
          }
        }
      }
    }
  }

  // Two-line device row showing name + live status. Pending state is owned
  // by the panel so it survives rows moving between sections.
  component DeviceRow: CursorSurface {
    id: row
    required property var dev
    required property int rowIndex
    required property string sectionName
    required property bool isDiscovered

    readonly property bool isConnected: dev && dev.connected
    // Battery gauge model; null hides the gauge and falls back to text status.
    readonly property var battery: isConnected && action === "" && devState !== 2
      ? Model.batteryLevel(dev, root.extraFor(dev.address)) : null
    readonly property int devState: dev && dev.state !== undefined ? dev.state : -1
    readonly property string action: root.pendingAction(dev ? dev.address : "")
    readonly property string actionTooltip: {
      if (!dev) return ""
      if (isConnected) return "Disconnect"
      if (isDiscovered) return "Pair"
      return "Connect"
    }

    readonly property bool rowSelected: root.cursorActive && root.focusSection === sectionName && root.selectedIndex === rowIndex
    readonly property bool forgetAvailable: (sectionName === "known" || sectionName === "connected") && !isDiscovered
    readonly property bool showForgetButton: forgetAvailable && (rowMouse.containsMouse || rowSelected)
    readonly property bool expanded: !!dev && root.expandedAddress === dev.address
    readonly property bool showInfoButton: forgetAvailable && (rowMouse.containsMouse || rowSelected || expanded)

    hasCursor: rowSelected && !root.actionFocused
    current: isConnected
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    readonly property string statusText: {
      if (!dev) return ""
      if (action === "forgetting") return "Forgetting…"
      if (action === "disconnecting" || devState === 2) return "Disconnecting…"
      if (isConnected) {
        if (battery) return ""
        return sectionName === "connected" ? "" : "Connected"
      }
      if (action === "connecting" || devState === 3 || dev.pairing === true) return "Connecting…"
      if (failure !== "") return failure
      return ""
    }

    // "Couldn't connect" / "Couldn't pair" after a failed attempt, for a few
    // seconds. Any newer state above takes the row back.
    readonly property string failure: root.failureFor(dev ? dev.address : "")
    readonly property bool showingFailure: failure !== "" && statusText === failure

    readonly property color statusColor: {
      if (isConnected) return root.bar.foreground
      if (action !== "" || devState === 3 || dev.pairing === true) return root.bar.foreground
      return Qt.darker(root.bar.foreground, 1.5)
    }

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: row.dev ? Qt.PointingHandCursor : Qt.ArrowCursor

      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = row.sectionName
        root.selectedIndex = row.rowIndex
        root.actionFocused = false
      }

      onClicked: function(mouse) {
        var dev = root.deviceFor(row)
        if (!dev) return
        if (mouse.button === Qt.RightButton) {
          if (row.isConnected) root.disconnectDevice(dev)
          else if (!row.isDiscovered) root.requestForget(dev)
          return
        }
        if (row.isConnected) root.disconnectDevice(dev)
        else root.connectDevice(dev)
      }
    }

    PanelToolTip {
      visible: row.actionTooltip !== "" && rowMouse.containsMouse && !root.actionFocused
      text: row.actionTooltip
      fontFamily: root.bar.fontFamily
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(deviceIcon.implicitHeight, info.implicitHeight, actions.implicitHeight)

      Text {
        id: deviceIcon
        textFormat: Text.PlainText
        text: Model.deviceGlyph(row.dev ? row.dev.icon : "") || (row.isConnected ? "󰂱" : "󰂯")
        color: row.statusColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: deviceIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: actions.visible ? actions.left : parent.right
        anchors.rightMargin: actions.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: root.deviceLabel(row.dev) || "Device"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        BatteryGauge {
          visible: !!row.battery
          level: row.battery
        }
        Text {
          textFormat: Text.PlainText
          visible: row.statusText !== ""
          text: row.statusText
          color: row.showingFailure ? Commons.Color.urgent : row.statusColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)
        // Not infoBtn.visible || forgetBtn.visible: a child reads as hidden
        // while its parent is, so that binding could never turn back on.
        visible: row.showInfoButton || row.showForgetButton

      PanelActionButton {
        id: infoBtn
        visible: row.showInfoButton
        iconText: row.expanded ? "󰅃" : "󰋼"
        tooltipText: row.expanded ? "Hide details (i)" : "Details (i)"
        foreground: root.bar.foreground
        hoverColor: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onHovered: function(isHovered) {
          if (!isHovered) return
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.actionFocused = false
        }
        onClicked: if (row.dev) root.toggleDetails(row.dev.address)
      }

      PanelActionButton {
        id: forgetBtn
        visible: row.showForgetButton
        iconText: "󰅙"
        tooltipText: "Forget"
        foreground: root.bar.foreground
        hoverColor: root.bar.foreground
        fontFamily: root.bar.fontFamily
        hasCursor: row.rowSelected && root.actionFocused
        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse) root.actionFocused = false
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.actionFocused = true
        }
        onClicked: {
          var dev = root.deviceFor(row)
          if (!dev) return
          root.requestForget(dev)
        }
      }
      }
    }
  }

  // A device row plus its details card when expanded.
  component DeviceEntry: Column {
    id: entry
    required property var dev
    required property int rowIndex
    required property string sectionName
    required property bool isDiscovered
    spacing: Style.space(6)

    DeviceRow {
      width: entry.width
      dev: entry.dev
      rowIndex: entry.rowIndex
      sectionName: entry.sectionName
      isDiscovered: entry.isDiscovered
    }

    // Built only while open, so at most one card exists.
    Loader {
      width: entry.width
      active: !!entry.dev && root.expandedAddress === entry.dev.address
      visible: active
      sourceComponent: Component {
        DeviceDetails { dev: entry.dev }
      }
    }
  }

  // Five segments in the theme accent (urgent when low), then the level word.
  component BatteryGauge: Row {
    id: gauge
    property var level: null
    readonly property color fillColor: level && level.low ? Commons.Color.urgent : Commons.Color.accent
    readonly property color emptyColor: Util.alpha(root.bar.foreground, 0.18)
    spacing: Style.space(6)

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Repeater {
        model: 5
        Rectangle {
          required property int index
          width: Style.space(9)
          height: Math.round(Style.font.caption * 0.75)
          radius: Math.min(2, Style.cornerRadius)
          color: gauge.level && index < gauge.level.segments ? gauge.fillColor : gauge.emptyColor
        }
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: (gauge.level && gauge.level.charging ? "󱐋 " : "") + Model.batteryLabel(gauge.level)
      color: gauge.level && gauge.level.low ? Commons.Color.urgent : Qt.darker(root.bar.foreground, 1.3)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component DetailLabel: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.bar.foreground, 1.5)
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
  }

  component DetailValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // Name, type, address, battery, profiles, plus rename / trust / block.
  component DeviceDetails: BorderSurface {
    id: card
    required property var dev
    readonly property var extra: dev ? root.extraFor(dev.address) : null
    readonly property bool renaming: !!dev && root.renamingAddress === dev.address
    readonly property int labelWidth: Style.space(84)

    readonly property var facts: {
      if (!dev) return []
      var battery = Model.batteryLabel(Model.batteryLevel(dev, extra))
      var status = dev.connected ? "Connected" : (dev.paired || dev.bonded ? "Paired" : "Not paired")
      var list = [
        ["Type", Model.deviceType(dev.icon)],
        ["Device name", dev.deviceName || "Unknown"],
        ["Address", dev.address],
        ["Status", status],
        ["Battery", battery !== "" ? battery : (dev.connected ? "Not reported" : "Unknown while disconnected")]
      ]
      if (extra && extra.profiles && extra.profiles.length > 0) list.push(["Profiles", extra.profiles.join(", ")])
      if (extra && extra.hardwareId) list.push(["Hardware ID", extra.hardwareId])
      return list
    }

    color: Style.normalFillFor(root.bar.foreground)
    borderSpec: Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent)
    radius: Style.cornerRadius
    implicitHeight: details.implicitHeight + Style.space(20)

    Column {
      id: details
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      // Display name, or the inline rename field.
      Item {
        width: parent.width
        visible: !card.renaming
        implicitHeight: Math.max(nameCol.implicitHeight, renameBtn.implicitHeight)

        Column {
          id: nameCol
          anchors.left: parent.left
          anchors.right: renameBtn.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)
          DetailLabel { text: "NAME" }
          DetailValue { width: parent.width; text: root.deviceLabel(card.dev) }
        }

        PanelActionButton {
          id: renameBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰏫"
          tooltipText: "Rename (r)"
          foreground: root.bar.foreground
          hoverColor: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: if (card.dev) root.startRename(card.dev.address)
        }
      }

      // Hidden editable TextFields still react to clipboard changes in Qt.
      // Keep the entire editor uninstantiated until Rename is requested, and
      // destroy it on save/cancel/close instead of only hiding it.
      Loader {
        id: renameLoader
        width: parent.width
        active: root.opened && card.renaming
        visible: active
        height: item ? item.implicitHeight : 0

        sourceComponent: Item {
          implicitHeight: Math.max(renameField.implicitHeight, saveBtn.implicitHeight)

          TextField {
            id: renameField
            anchors.left: parent.left
            anchors.right: saveBtn.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: (card.dev && card.dev.deviceName ? card.dev.deviceName : "Name") + " (leave empty to reset)"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            function focusForRename() {
              if (!root.opened || !card.renaming) return
              forceActiveFocus()
              selectAll()
            }

            onAccepted: root.commitRename(text)
            Keys.onEscapePressed: root.cancelRename()
            Component.onCompleted: {
              text = root.deviceLabel(card.dev)
              Qt.callLater(focusForRename)
            }
          }

          PanelActionButton {
            id: saveBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰄬"
            tooltipText: "Save"
            foreground: root.bar.foreground
            hoverColor: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.commitRename(renameField.text)
          }
        }
      }

      Repeater {
        model: card.facts
        Row {
          required property var modelData
          width: details.width
          spacing: Style.space(8)
          DetailLabel {
            width: card.labelWidth
            text: modelData[0].toUpperCase()
          }
          DetailValue {
            width: parent.width - card.labelWidth - parent.spacing
            text: modelData[1]
          }
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
      }

      DetailSwitch {
        width: details.width
        label: "Trusted"
        hint: "Reconnects automatically without asking"
        checked: !!card.dev && card.dev.trusted
        onToggled: root.setDeviceFlag(card.dev.address, "trusted", !card.dev.trusted)
      }

      DetailSwitch {
        width: details.width
        label: "Blocked"
        hint: "Refuses all connections from this device"
        checked: !!card.dev && card.dev.blocked
        onToggled: root.setDeviceFlag(card.dev.address, "blocked", !card.dev.blocked)
      }
    }
  }

  component DetailSwitch: Item {
    id: sw
    property string label: ""
    property string hint: ""
    property bool checked: false
    signal toggled()
    implicitHeight: Math.max(swLabels.implicitHeight, swToggle.implicitHeight)

    Column {
      id: swLabels
      anchors.left: parent.left
      anchors.right: swToggle.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      DetailValue { width: parent.width; text: sw.label }
      DetailLabel { width: parent.width; text: sw.hint; wrapMode: Text.WordWrap }
    }

    ToggleSwitch {
      id: swToggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: sw.checked
      foreground: root.bar.foreground
      onToggled: sw.toggled()
    }
  }
}

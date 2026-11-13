#!/usr/bin/env python3
"""Exercise the real rename-row QML with native Qt controls, offscreen.

Requires PySide6. Styling and the shell action button are isolated stand-ins;
the editable control uses Qt's real TextField and a counted QMimeData offer.
Pass an older Panel.qml path to check that the regression is detected.
"""

import os
from pathlib import Path
import sys
import tempfile

os.environ["QT_QPA_PLATFORM"] = "offscreen"
os.environ["QT_QUICK_BACKEND"] = "software"
os.environ["QT_QPA_PLATFORMTHEME"] = ""
os.environ["QT_QUICK_CONTROLS_STYLE"] = "Basic"

from PySide6.QtCore import QCoreApplication, QEvent, QMimeData, QObject, Qt, QUrl
from PySide6.QtGui import QGuiApplication, QKeyEvent
from PySide6.QtQuick import QQuickView
from PySide6.QtTest import QTest


class ClipboardOffer(QMimeData):
    def __init__(self):
        super().__init__()
        self.reads = 0

    def formats(self):
        return ["text/plain"]

    def hasFormat(self, mime):
        return mime == "text/plain"

    def retrieveData(self, mime, preferred_type):
        self.reads += 1
        return "harmless clipboard text"


app = QGuiApplication([])
panel_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "Panel.qml"
source = panel_path.read_text()
rows = source.split("      // Display name, or the inline rename field.\n", 1)[1].split("\n      Repeater {", 1)[0]

# Extract the production rows unchanged. Only surrounding shell presentation
# types are substituted; input events and clipboard signals use native Qt.
fixture = '''
import QtQuick
import QtQuick.Controls as Controls
import "."
Item {
  id: root
  width: 380; height: 100
  property bool opened: true
  property string renamingAddress: ""
  property string deviceName: "Headphones"
  property string savedName: "unset"
  property var bar: ({foreground: "white", fontFamily: "Sans Serif"})
  function deviceLabel(dev) { return deviceName }
  function startRename(address) { renamingAddress = address }
  function cancelRename() { renamingAddress = "" }
  function commitRename(text) { savedName = text; deviceName = text; cancelRename() }
  component DetailLabel: Text {}
  component DetailValue: Text {}
  component PanelActionButton: Controls.Button {
    property string iconText
    property string tooltipText
    property color foreground
    property color hoverColor
    property string fontFamily
  }
  component TextField: Controls.TextField {
    property color foreground
    property real horizontalPadding
    property real verticalPadding
  }
  Item {
    id: card
    width: parent.width; height: parent.height
    property var dev: ({address: "AA", deviceName: "Headphones"})
    readonly property bool renaming: root.renamingAddress === dev.address
    Column {
      width: parent.width
ROWS
    }
  }
}
'''.replace("ROWS", rows)


def settle():
    app.processEvents()
    QCoreApplication.sendPostedEvents(None, QEvent.DeferredDelete)
    app.processEvents()


def editors():
    return [obj for obj in root.findChildren(QObject) if obj.inherits("QQuickTextInput")]


def expect_no_clipboard_read(label):
    settle()
    fields = editors()
    offer = ClipboardOffer()
    app.clipboard().setMimeData(offer)
    settle()
    reads = offer.reads
    app.clipboard().clear()
    assert reads == 0, f"{label}: clipboard body requested {reads} times ({len(fields)} editors)"
    assert not fields, f"{label}: editable field still exists"


def begin():
    root.setProperty("renamingAddress", "AA")
    settle()
    fields = editors()
    assert len(fields) == 1, "Rename must create exactly one editor"
    field = fields[0]
    assert field.property("text") == root.property("deviceName")
    assert field.property("activeFocus"), "Rename must focus the editor"
    assert field.property("selectedText") == field.property("text")
    return field


with tempfile.TemporaryDirectory(prefix="bluechip-rename-") as tmp:
    directory = Path(tmp)
    (directory / "qmldir").write_text("singleton Style 1.0 Style.qml\n")
    (directory / "Style.qml").write_text('''
pragma Singleton
import QtQml
QtObject {
  property var font: ({family: "Sans Serif", body: 14})
  property var spacing: ({controlGap: 6, controlPaddingY: 4})
  function space(value) { return value }
}
''')
    path = directory / "Harness.qml"
    path.write_text(fixture)
    view = QQuickView()
    view.setSource(QUrl.fromLocalFile(str(path)))
    assert view.status() == QQuickView.Ready, view.errors()
    view.show()
    root = view.rootObject()
    settle()

    expect_no_clipboard_read("Details without Rename")
    field = begin()
    # Positive control: on affected Qt this harmless offer really is read by
    # canPaste, proving the zero-read checks exercise the reported Qt path.
    offer = ClipboardOffer()
    app.clipboard().setMimeData(offer)
    settle()
    print(f"Clipboard body reads during explicit Rename: {offer.reads}")

    QTest.keyClick(view, Qt.Key_Escape)
    assert root.property("renamingAddress") == ""
    expect_no_clipboard_read("Escape")

    field = begin()
    QCoreApplication.sendEvent(view, QKeyEvent(QEvent.KeyPress, 0, Qt.NoModifier, "New name"))
    QTest.keyClick(view, Qt.Key_Return)
    assert root.property("savedName") == "New name"
    expect_no_clipboard_read("Enter to save")

    field = begin()
    field.setProperty("text", "Saved with button")
    buttons = [obj for obj in root.findChildren(QObject) if obj.property("tooltipText") == "Save"]
    assert len(buttons) == 1
    buttons[0].clicked.emit()
    assert root.property("savedName") == "Saved with button"
    expect_no_clipboard_read("Save button")

    field = begin()
    field.setProperty("text", "")
    QTest.keyClick(view, Qt.Key_Return)
    assert root.property("savedName") == ""
    expect_no_clipboard_read("Empty alias reset")

    begin()
    root.setProperty("opened", False)
    expect_no_clipboard_read("Panel closed during Rename")
    root.setProperty("renamingAddress", "")
    root.setProperty("opened", True)
    expect_no_clipboard_read("Panel reopened")

    # Destroying the editor before its deferred focus callback must be safe.
    root.setProperty("renamingAddress", "AA")
    root.setProperty("renamingAddress", "")
    expect_no_clipboard_read("Immediate cancellation")
    view.close()
    app.clipboard().clear()

print("PASS: rename lifecycle, focus, save/cancel, and clipboard isolation")

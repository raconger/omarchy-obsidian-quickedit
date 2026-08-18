import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Obsidian quick note popup: vault scan + note picker on the left, a plain
// text editor on the right. The bar button's click goes straight to the last
// edited note when one is configured; the picker is one click away via the
// back button in the editor header.
//
// Notes are plain .md files read and written in place with FileView
// (atomicWrites), so external editors — Obsidian itself — stay consistent.
Panel {
  id: root
  moduleName: "mykcib.obsidian-quickedit"
  ipcTarget: "mykcib.obsidian-quickedit"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string vaultPath: Model.expandPath(setting("vaultPath", ""), Quickshell.env("HOME"))
  readonly property string configuredNote: Model.expandPath(setting("notePath", ""), Quickshell.env("HOME"))

  // When no vault is configured, look for one on disk (directories carrying
  // a .obsidian marker) so a fresh install works without touching settings.
  property var detectedVaults: []
  property bool detectingVaults: false
  property bool detectionStarted: false
  readonly property string detectedVault: detectedVaults.length > 0 ? String(detectedVaults[0]) : ""
  readonly property string effectiveVault: root.vaultPath !== "" ? root.vaultPath : root.detectedVault
  readonly property bool vaultConfigured: effectiveVault !== ""

  // In-panel vault editor: type a path when none is pinned, or edit the
  // pinned one via the footer's Change button. Persisted on commit.
  property bool editingVaultPath: false
  property string vaultPendingError: ""

  // Once detection finds a vault, prefill the input so one "Use" click pins
  // it. Never clobber something the user already typed.
  onDetectedVaultsChanged: {
    if (root.vaultPath !== "" || !vaultField || vaultField.text !== "") return
    Qt.callLater(function() {
      if (vaultField && vaultField.text === "" && root.detectedVault !== "")
        vaultField.text = root.detectedVault
    })
  }

  // ---- picker state
  property var notes: []
  property bool scanning: false
  property bool rescanQueued: false
  property string filterText: ""
  property int pickIndex: 0

  // Empty search box = browsing: show only root-level notes, with subfolders
  // collapsed into single rows at the bottom. Any typed text searches every
  // note regardless of folder.
  readonly property bool browsing: String(root.filterText).trim() === ""
  readonly property var pickRows: root.browsing
    ? Model.rootNotes(root.notes) : Model.filterNotes(root.notes, root.filterText)
  readonly property var folderRows: root.browsing ? Model.folderRows(root.notes) : []

  // Notational-velocity-style create-on-search: when the typed text doesn't
  // match an existing note, a virtual "Create note" row is appended to the
  // picker list. Selecting it (Enter or click) opens a blank editor at that
  // path; the file itself is only written on first save.
  readonly property var createRow: (!root.scanning && root.vaultConfigured)
    ? Model.makeCreateRow(root.filterText, root.notes) : null
  readonly property var displayRows: root.pickRows.concat(root.folderRows, root.createRow ? [root.createRow] : [])

  // ---- editor state
  property bool editing: false
  property bool loadingNote: false
  property bool noteMissing: false
  property string editRel: ""
  property bool dirty: false
  property bool saveFailedState: false
  property bool justSaved: false
  property bool syncingText: false
  // True while the current editRel refers to a note that doesn't exist on
  // disk yet — its first FileView load is expected to fail, and that
  // failure should open a blank editor rather than the "note missing" state.
  property bool creatingNote: false

  readonly property string editPath: editRel === "" ? "" : Model.joinPath(effectiveVault, editRel)

  // ---------------------------------------------------------------- lifecycle

  function open() {
    root.controller.show()
    Qt.callLater(root.enterView)
  }

  // Shared by close() and goPicker() so leaving the editor never silently
  // drops an in-progress edit, whichever way you leave it.
  function saveIfDirty() {
    if (root.dirty && root.editPath !== "") root.saveNote()
  }

  function close() {
    root.saveIfDirty()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onOpenedChanged: function() {
    if (!root.opened) {
      root.filterText = ""
      root.pickIndex = 0
      root.justSaved = false
      root.saveFailedState = false
    }
  }

  // On open: skip straight to the configured note when it exists; otherwise
  // land on the picker (which rescans the vault if the cache is empty).
  function enterView() {
    if (!root.opened) return
    if (root.editRel !== "") {
      root.beginEdit()
      return
    }
    var next = Model.toRel(root.effectiveVault, root.configuredNote)
    if (next !== "") {
      root.editRel = next
      root.creatingNote = false
      root.pinDetectedVaultIfUsed()
      root.beginEdit()
      return
    }
    if (root.notes.length === 0 && root.vaultConfigured) root.loadNotes()
    root.focusPicker()
  }

  function focusPicker() {
    Qt.callLater(function() {
      if (!root.opened) return
      if (pickerField) pickerField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  // ---------------------------------------------------------------- notes

  function loadNotes() {
    if (!root.vaultConfigured) return
    if (notesProc.running) {
      root.rescanQueued = true
      return
    }
    root.scanning = true
    notesProc.command = ["bash", "-c", "cd " + Util.shellQuote(root.effectiveVault)
      + " && find . -type f -name '*.md' 2>/dev/null | LC_ALL=C sort -r"]
    notesProc.running = true
  }

  // Best-effort vault discovery for fresh installs: common home locations,
  // plus a shallow sweep of $HOME itself. Only runs when no vault is pinned.
  function maybeRunVaultDetection() {
    if (root.vaultPath !== "" || root.detectionStarted) return
    root.detectionStarted = true
    root.detectingVaults = true
    detectProc.command = ["bash", "-c",
      "for d in \"$HOME/Documents\" \"$HOME/Notes\" \"$HOME/Obsidian\"; do "
      + "find \"$d\" -maxdepth 4 -name .obsidian -type d 2>/dev/null; done; "
      + "find \"$HOME\" -maxdepth 3 -name .obsidian -type d 2>/dev/null | sort -u"]
    detectProc.running = true
  }

  function activatePick() {
    var rows = root.displayRows
    if (root.pickIndex < 0 || root.pickIndex >= rows.length) return
    var row = rows[root.pickIndex]
    if (row.isFolder) {
      // "Expand" a collapsed folder by searching into it — reuses the
      // ordinary recursive filter instead of a separate navigation stack.
      if (pickerField) {
        pickerField.text = String(row.folderQuery || "")
        pickerField.forceActiveFocus()
      }
      return
    }
    if (row.isCreate) {
      root.createNote(String(row.rel || ""))
      return
    }
    var rel = String(row.rel || "")
    if (rel === "") return
    root.persistNote(rel)
    root.creatingNote = false
    root.editRel = rel
    root.beginEdit()
  }

  function movePick(delta) {
    var count = root.displayRows.length
    if (count === 0) return
    root.pickIndex = Math.max(0, Math.min(count - 1, root.pickIndex + delta))
  }

  function goPicker() {
    root.saveIfDirty()
    root.editing = false
    root.editRel = ""
    root.creatingNote = false
    root.loadingNote = false
    root.noteMissing = false
    root.dirty = false
    root.saveFailedState = false
    root.justSaved = false
    if (root.notes.length === 0 && root.vaultConfigured) root.loadNotes()
    root.focusPicker()
  }

  // Write an update to the bar's inline shell.json entry, merged with the
  // current settings, and echo it locally so bindings react immediately.
  function persistEntry(patch) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    for (var p in patch) entry[p] = patch[p]
    root.settings = entry
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // A note picked from a detected vault pins that vault too, so the choice
  // survives without the extra "Use" click.
  function pinDetectedVaultIfUsed() {
    if (String(root.settings.vaultPath || "") !== "") return
    if (root.detectedVault === "") return
    root.persistEntry({ vaultPath: root.detectedVault })
  }

  function persistNote(rel) {
    if (rel === "") return
    root.persistEntry({
      vaultPath: String(root.settings.vaultPath || "") !== "" ? root.settings.vaultPath : root.detectedVault,
      notePath: rel
    })
  }

  // The raw string is stored so ~ and $HOME expand on every read, like the
  // settings form does.
  function persistVault(raw) {
    root.persistEntry({ vaultPath: raw })
  }

  function startVaultEdit() {
    // The vault field lives in the picker view; from the editor, switch
    // there first (saving any pending edits) so the field is visible.
    if (root.editing) {
      if (root.dirty && root.editPath !== "") root.saveNote()
      root.goPicker()
    }
    root.editingVaultPath = true
    Qt.callLater(root.focusVaultField)
  }

  function focusVaultField() {
    if (!vaultField || !vaultField.visible) return
    vaultField.text = root.vaultPath
    vaultField.forceActiveFocus()
    vaultField.selectAll()
  }

  function cancelVaultEdit() {
    root.editingVaultPath = false
    root.vaultPendingError = ""
  }

  // Commit whatever is in the vault field, rescan the folder, and persist.
  function commitVault() {
    var raw = String(vaultField.text || "").trim()
    if (raw === "") return
    var expanded = Model.expandPath(raw, Quickshell.env("HOME"))
    if (expanded !== root.effectiveVault) {
      // A different vault invalidates the note picked from the old one.
      root.editRel = ""
      root.editing = false
      root.creatingNote = false
    }
    root.vaultPendingError = ""
    root.filterText = ""
    root.pickIndex = 0
    root.notes = []
    root.persistVault(raw)
    root.editingVaultPath = false
    root.loadNotes()
    root.focusPicker()
  }

  // ---------------------------------------------------------------- editor

  function beginEdit() {
    if (root.editRel === "") return
    root.editing = true
    root.loadingNote = true
    root.noteMissing = false
    root.justSaved = false
    root.saveFailedState = false
    root.dirty = false
    noteFile.reload()
  }

  // Notational-velocity-style creation: jump straight into a blank editor at
  // `rel`. Nothing is written to disk until the first save — FileView's
  // writer creates missing parent directories on its own, so no separate
  // "touch the file" step is needed.
  function createNote(rel) {
    if (rel === "") return
    root.filterText = ""
    root.pickIndex = 0
    root.creatingNote = true
    root.editRel = rel
    root.beginEdit()
  }

  // Common "editor is ready to type in" transition, reached either from a
  // successful load or (when creatingNote) from a load failure treated as
  // "blank slate" rather than an error.
  function enterEditorReady(text) {
    root.syncingText = true
    editor.text = text
    root.syncingText = false
    root.loadingNote = false
    root.noteMissing = false
    root.dirty = false
    root.justSaved = false
    Qt.callLater(function() {
      if (root.opened && root.editing && editor.visible) editor.forceActiveFocus()
    })
  }

  function saveNote() {
    if (!root.dirty || root.editPath === "" || root.loadingNote) return
    noteFile.setText(editor.text)
    root.dirty = false
    root.saveFailedState = false
    root.justSaved = true
    savedFlashTimer.restart()
  }

  function markDirty() {
    if (root.syncingText) return
    if (!root.dirty) root.dirty = true
    root.saveFailedState = false
    if (root.justSaved) { root.justSaved = false; savedFlashTimer.stop() }
  }

  Component.onCompleted: Qt.callLater(root.maybeRunVaultDetection)

  Process {
    id: detectProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detectedVaults = Model.parseVaultCandidates(text)
        root.detectingVaults = false
        if (root.vaultConfigured && root.opened && root.notes.length === 0) root.loadNotes()
      }
    }
  }

  Process {
    id: notesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.notes = Model.parseNotes(text, root.effectiveVault)
        root.scanning = false
        if (root.pickIndex >= root.displayRows.length) root.pickIndex = Math.max(0, root.displayRows.length - 1)
        if (root.rescanQueued) {
          root.rescanQueued = false
          Qt.callLater(root.loadNotes)
        }
      }
    }
    onExited: function(exitCode) {
      root.scanning = false
      if (exitCode !== 0 && root.notes.length === 0 && root.vaultConfigured)
        root.vaultPendingError = "Could not read this folder as a vault: " + root.effectiveVault
    }
  }

  FileView {
    id: noteFile
    path: root.editPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (root.editRel === "") return
      // A real load means the note now genuinely exists on disk (either it
      // always did, or a prior create-flow save just wrote it) — any future
      // load failure for this editRel is a real "went missing", not a
      // not-yet-created note.
      root.creatingNote = false
      root.enterEditorReady(String(noteFile.text() || ""))
    }
    onLoadFailed: {
      if (root.editRel === "") return
      if (root.creatingNote) {
        root.enterEditorReady("")
        return
      }
      root.loadingNote = false
      root.noteMissing = true
      root.dirty = false
    }
    onSaveFailed: {
      if (root.editing && root.editPath !== "") {
        root.dirty = true
        root.saveFailedState = true
        root.justSaved = false
        savedFlashTimer.stop()
      }
    }
  }

  Timer {
    id: savedFlashTimer
    interval: 1500
    onTriggered: root.justSaved = false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (!root.editing && (pickerField.activeFocus || vaultField.activeFocus))
        || (root.editing && editor.activeFocus)
      onMoveRequested: function(dx, dy) {
        if (!root.editing && dy !== 0 && root.displayRows.length > 0) root.movePick(dy)
      }
      onActivateRequested: if (!root.editing) root.activatePick()
      onCloseRequested: root.editing ? root.goPicker() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Header ----------
          Item {
            width: parent.width
            implicitHeight: headerBlock.implicitHeight

            Column {
              id: headerBlock
              anchors.left: parent.left
              anchors.right: backButton.visible ? backButton.left : parent.right
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "QUICK NOTE"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                font.letterSpacing: 1
                elide: Text.ElideRight
              }

              Text {
                visible: root.editing && root.editRel !== ""
                width: parent.width
                text: root.editRel
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
            }

            PanelActionButton {
              id: backButton
              visible: root.editing
              anchors.top: parent.top
              anchors.right: parent.right
              iconText: "󰅁"
              tooltipText: "All notes"
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.goPicker()
            }
          }

          // ---------- Picker ----------
          Column {
            visible: !root.editing
            width: parent.width
            spacing: Style.space(8)

            // Vault input: always present until a vault is pinned; also
            // reachable via the footer's Change button once pinned.
            Column {
              visible: root.vaultPath === "" || root.editingVaultPath
              width: parent.width
              spacing: Style.space(6)

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                TextField {
                  id: vaultField
                  Layout.fillWidth: true
                  placeholderText: "Vault path… e.g. ~/Documents/Vault"
                  foreground: root.fg
                  font.family: root.fontFamily
                  onAccepted: root.commitVault()
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      if (root.editingVaultPath && root.vaultPath !== "") root.cancelVaultEdit()
                      else keyCatcher.forceActiveFocus()
                      event.accepted = true
                    }
                  }
                }

                Button {
                  id: scanButton
                  text: root.vaultPath !== "" ? "Save"
                    : (root.detectedVault !== "" ? "Use" : "Scan")
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.commitVault()
                }

                Button {
                  id: cancelButton
                  visible: root.editingVaultPath && root.vaultPath !== ""
                  text: "Cancel"
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.cancelVaultEdit()
                }
              }

              Text {
                visible: root.vaultPendingError !== ""
                width: parent.width
                text: root.vaultPendingError
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }

            TextField {
              id: pickerField
              width: parent.width
              enabled: root.vaultConfigured
              placeholderText: "Search or create a note…"
              text: root.filterText
              foreground: root.fg
              font.family: root.fontFamily
              onTextChanged: {
                root.filterText = text
                root.pickIndex = 0
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.activatePick()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  root.movePick(1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.movePick(-1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.close()
                  event.accepted = true
                }
              }
            }

            Column {
              visible: root.vaultConfigured
              width: parent.width
              spacing: Style.space(4)

              ListView {
                id: pickList
                visible: root.scanning || root.displayRows.length > 0
                width: parent.width
                height: Math.min(contentHeight, Style.space(380))
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                spacing: Style.space(3)
                model: root.displayRows
                currentIndex: root.pickIndex
                onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                  required property var modelData
                  required property int index

                  width: ListView.view.width
                  height: row.implicitHeight

                  CursorSurface {
                    id: row
                    width: parent.width
                    hasCursor: root.pickIndex === index
                    foreground: root.fg
                    fill: root.hoverFill
                    currentFill: root.selectedFill

                    implicitHeight: rowText.implicitHeight + Style.spacing.rowPaddingX

                    Text {
                      id: rowText
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      text: modelData.label
                      color: modelData.isCreate ? Color.accent
                        : modelData.isFolder ? root.dim
                        : (root.pickIndex === index ? Style.selectedStateColor(root.fg, Color.accent) : root.fg)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.italic: !!modelData.isCreate
                      elide: Text.ElideMiddle
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.pickIndex = index
                    onClicked: {
                      root.pickIndex = index
                      root.activatePick()
                    }
                  }
                }
              }

              Column {
                visible: pickList.visible === false
                width: parent.width
                spacing: Style.space(4)

                Text {
                  visible: root.scanning
                  width: parent.width
                  text: "Scanning vault…"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: !root.scanning && root.notes.length === 0
                  width: parent.width
                  text: "No .md notes found in this vault"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: !root.scanning && root.notes.length > 0 && root.pickRows.length === 0
                  width: parent.width
                  text: "No notes match \"" + root.filterText + "\""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }
            }

            Text {
              visible: !root.vaultConfigured
              width: parent.width
              text: root.detectingVaults ? "Looking for an Obsidian vault… or type a path above."
                : root.detectedVault !== "" ? "No notes yet — searching " + root.detectedVault + "…\nType a path above to pin a different vault."
                : "No Obsidian vault found — type the path above, e.g. ~/Documents/Vault"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Editor ----------
          Column {
            visible: root.editing
            width: parent.width
            spacing: Style.space(8)

            Item {
              visible: root.loadingNote || root.noteMissing
              width: parent.width
              implicitHeight: noteStateText.implicitHeight + Style.spacing.lg

              Text {
                id: noteStateText
                width: parent.width - (pickAnotherButton.visible ? pickAnotherButton.width + Style.space(8) : 0)
                text: root.noteMissing ? "Note not found — it may have been moved or deleted." : "Loading…"
                color: root.noteMissing ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Button {
                id: pickAnotherButton
                visible: root.noteMissing
                anchors.right: parent.right
                anchors.top: parent.top
                text: "Pick another note"
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.goPicker()
              }
            }

            TextArea {
              id: editor
              visible: !root.loadingNote && !root.noteMissing
              width: parent.width
              height: Style.space(400)
              wrapMode: Text.Wrap
              selectByMouse: true
              persistentSelection: true
              selectByKeyboard: true
              color: root.fg
              selectionColor: Style.selectionFillFor(root.fg, Color.accent)
              selectedTextColor: root.fg
              placeholderText: "Empty note — start typing…"
              placeholderTextColor: Qt.darker(root.fg, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              topPadding: Style.spacing.controlGap
              bottomPadding: Style.spacing.controlGap
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              background: BorderSurface {
                color: Style.controlFill(editor.activeFocus, false, root.fg, Color.accent)
                borderSpec: Border.controlSpec(editor.activeFocus ? "focus" : "normal", root.fg, Color.accent)
                radius: Style.cornerRadius
              }

              onTextChanged: root.markDirty()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  // Esc backs out to the note list (saving any pending edit
                  // first); the picker's own Esc is what closes the panel.
                  root.goPicker()
                  event.accepted = true
                  return
                }
                if ((event.key === Qt.Key_S || event.key === Qt.Key_Enter)
                    && (event.modifiers & Qt.ControlModifier)) {
                  root.saveNote()
                  event.accepted = true
                }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: root.saveFailedState ? "Save failed"
                  : root.dirty ? "Unsaved changes"
                  : root.justSaved ? "Saved"
                  : "Ctrl+S to save"
                color: root.saveFailedState ? root.urgent : (root.dirty ? root.fg : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Button {
                id: saveButton
                text: "Save"
                enabled: root.dirty && !root.loadingNote && !root.noteMissing
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.saveNote()
              }
            }
          }

          // ---------- Footer ----------
          PanelSeparator {
            foreground: root.fg
          }

          RowLayout {
            visible: root.vaultConfigured
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              text: root.vaultPath !== "" ? root.vaultPath : "Detected · " + root.detectedVault
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Button {
              id: changeButton
              visible: root.vaultPath !== "" && !root.editingVaultPath
              text: "Change"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.startVaultEdit()
            }
          }
        }
      }
    }
  }
}

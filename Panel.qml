import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Fox pet desktop overlay.
//
// One PanelWindow per screen, anchored to the screen's full area. The
// surface is fully click-transparent: clicks pass through to apps below
// (exclusionMode: Ignore) and the only place that captures input is the
// MouseArea wrapped around the fox sprite. Earlier versions set
// `mask: Region {}` thinking it would make the panel passive — it does,
// but it also blocks the MouseArea inside the QML scene. Without the
// mask the scene's interactive elements receive input normally; with
// exclusionMode: Ignore, clicks anywhere outside the fox still fall
// through to whatever's underneath.
//
// Multi-monitor: each panel renders the fox only when it actually lives
// on that screen. When the fox is dragged (or wanders) onto another
// monitor, the panel there takes over rendering and the old one goes
// idle.
//
// The service owns the fox's state machine. This file is mostly a
// renderer: bind to service.positionX / petState / frameIndex /
// direction and project those onto a sprite cell.
Item {
  id: root

  property var shell: null
  property var manifest: null
  // The shell loader injects the matching service instance under this
  // property name. If the service failed to load (or hasn't started yet),
  // we render nothing rather than crash.
  property var service: shell && shell.serviceFor ? shell.serviceFor("fox-pet") : null

  // The fox shows only when the user has enabled it AND the panel has
  // been summoned. Hidden when the panel is dismissed so the overlay
  // doesn't waste a render layer between summons.
  property bool opened: false

  function open(payloadJson) {
    opened = true
    if (service && !service.enabled) {
      service.enable()
    }
  }

  function close() {
    opened = false
  }

  function dismiss() {
    opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "fox-pet")
  }

  // ---------------------------------------------------------- sprite math
  //
  // The spritesheet is laid out as `columns` cells per row, each
  // `cellWidth × cellHeight`. The service tells us which row (state)
  // and which frame within the row. We turn those into a clipping
  // rectangle inside the source image.
  //
  // sourceSize is set to the full sheet so sourceClipRect (which lives
  // in source pixel coordinates) maps cell-for-cell to the cell grid.
  readonly property real scale: service ? service.scale : 1.0
  readonly property int columns: service ? service.columns : 8
  readonly property int cellWidth: service ? service.cellWidth : 192
  readonly property int cellHeight: service ? service.cellHeight : 208
  readonly property int rowCount: service ? service.rowCount : 11

  readonly property int scaledCellWidth: Math.round(cellWidth * scale)
  readonly property int scaledCellHeight: Math.round(cellHeight * scale)

  readonly property real altitude: service ? Math.max(0, service.groundY - serviceY) : 0
  readonly property real shadowFade: Math.max(0.3, 1.0 - altitude / 450.0)

  readonly property var rowSpec: service && service.rows
    ? service.rows[service.petState] || service.rows[service.stateIdle]
    : { row: 0, frames: 8, fps: 5 }
  readonly property int frameRow: rowSpec.row
  readonly property int frameCount: rowSpec.frames
  readonly property int frameCol: service ? service.frameIndex % frameCount : 0
  readonly property int frameX: frameCol * cellWidth
  readonly property int frameY: frameRow * cellHeight

  // Qt.resolvedUrl walks up to the panel QML's directory, so the panel
  // doesn't depend on whatever cwd the shell happened to launch in.
  readonly property string spriteUrl: service ? service.spriteUrl : Qt.resolvedUrl("assets/spritesheet.webp")

  // Direction mirrors the sprite horizontally. The flipper's transform
  // list does ONLY a horizontal mirror — never a vertical one — so
  // `scale: -1` doesn't accidentally flip the fox upside-down.
  readonly property real facingScale: service && service.direction === -1 ? -1 : 1

  // The spritesheet has no dedicated sleep pose; row 5 reads as a
  // drowsy/scared look. We apply a tilt + slight shrink when the fox
  // is sleeping to make it read as "curled up" rather than "startled".
  readonly property bool isSleeping: service && service.petState === service.stateSleep
  readonly property real sleepTilt: isSleeping ? 12 : 0
  readonly property real sleepScale: isSleeping ? 0.85 : 1.0

  // Per-panel: does the fox actually live on this screen? The service
  // tracks its own currentScreenIndex and exposes a helper that compares
  // its current screen by reference. The other panels stay mounted (so
  // their click-through behavior stays valid) but render nothing.
  function isFoxScreen(screen) {
    return !service || !screen || service.matchesCurrentScreen(screen)
  }

  // Service-derived reads the per-panel Properties need. Pulling them up
  // here keeps the PanelWindow expressions short and lets the shadow /
  // hit area bind to a single source of truth.
  readonly property real serviceX: service ? service.positionX : 0
  readonly property real serviceY: service ? service.positionY : 0

  Variants {
    id: screens
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      property int screenIndex: panel.modelData
        ? Quickshell.screens.indexOf(panel.modelData)
        : 0

      screen: modelData
      // The whole window is invisible unless the panel is opened AND the
      // service is alive AND enabled AND this panel is the one whose
      // screen the fox is on. The "service.enabled" guard is the key
      // bit: when the bar widget toggles the pet off, the service
      // disables but the panel's Loader is still mounted (keepLoaded);
      // without this guard the fox sprite would stay painted on
      // screen after the toggle. The other panels stay mounted so they
      // still pass clicks through correctly, but they render nothing.
      visible: root.opened && root.service !== null
            && root.service.enabled && root.isFoxScreen(modelData)
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "fox-pet"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // The surface is passive: it doesn't reserve an exclusive zone, so
      // clicks anywhere outside the fox's MouseArea fall through to
      // whatever app is underneath. Crucially we do NOT set a `mask`
      // here — an empty Region would also block the MouseArea inside
      // this very scene, which is why clicks silently failed before.
      exclusionMode: ExclusionMode.Ignore
      mask: Region {
        item: foxHit
      }

      // Hint banner the first time the user summons the fox. Hides
      // itself after a few seconds or as soon as the user interacts.
      Rectangle {
        id: hint
        visible: opacity > 0.0
        opacity: hintTimer.running && !hint.dismissed ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        width: hintText.implicitWidth + 24
        height: hintText.implicitHeight + 16
        radius: 8
        color: Qt.rgba(0.12, 0.12, 0.12, 0.85)
        border.color: Qt.rgba(1, 1, 1, 0.18)
        border.width: 1
        x: Math.max(20, Math.min(panel.width - width - 20, Math.round(root.serviceX + root.scaledCellWidth / 2 - width / 2)))
        y: Math.max(20, Math.round(root.serviceY - height - 12))

        Text {
          id: hintText
          anchors.centerIn: parent
          color: "#f0f0f0"
          font.pixelSize: 12
          font.family: Style.font.family
          text: "🦊  click = greet · double-click = rest · drag = move"
        }

        Timer {
          id: hintTimer
          interval: 5000
          running: root.opened && !hint.dismissed
          onTriggered: hint.dismissed = true
        }
        property bool dismissed: false
      }

      // Drop shadow. Pinned to the ground plane, softly scaling and fading
      // with the fox's altitude so it stays realistically on the floor.
      Item {
        id: shadow
        visible: root.service && root.service.showShadow
        opacity: root.isSleeping ? 0.8 : root.shadowFade
        x: Math.round(root.serviceX + (root.scaledCellWidth - width) / 2)
        y: root.service
          ? Math.round(root.service.groundY + root.scaledCellHeight - 12 * root.scale)
          : Math.round(root.serviceY + root.scaledCellHeight - 12 * root.scale)
        width: Math.round(root.scaledCellWidth * (0.65 + Math.min(0.2, root.altitude / 600.0)))
        height: Math.round(18 * root.scale * (1.0 + Math.min(0.3, root.altitude / 500.0)))

        Item {
          anchors.fill: parent

          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.40
            height: parent.height * 0.55
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.45)
          }
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.60
            height: parent.height * 0.80
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.20)
          }
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.80
            height: parent.height * 0.95
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.08)
          }
        }
      }

      // Fox sprite. Pixel-rounded integer coordinates prevent bilinear
      // texture blur and shimmering while walking.
      Item {
        id: fox
        x: Math.round(root.serviceX)
        y: Math.round(root.serviceY)
        width: root.scaledCellWidth
        height: root.scaledCellHeight
        clip: true

        Item {
          id: flipper
          anchors.fill: parent
          // Sleep pose anchored to Item.Bottom keeps the resting fox
          // grounded on the floor without penetrating or hovering.
          transformOrigin: Item.Bottom
          rotation: root.isSleeping ? 12 : 0
          scale: root.isSleeping ? 0.85 : 1.0

          Image {
            id: sprite
            anchors.fill: parent
            source: root.spriteUrl
            fillMode: Image.Stretch
            smooth: true
            mipmap: true
            asynchronous: false
            cache: true
            mirror: root.facingScale === -1
            sourceClipRect: Qt.rect(root.frameX, root.frameY, root.cellWidth, root.cellHeight)
            sourceSize: Qt.size(root.cellWidth * root.columns,
                                root.cellHeight * root.rowCount)
          }
        }
      }

      // Proximity hover area: detects cursor direction to glance naturally
      // without capturing or blocking any mouse clicks.
      MouseArea {
        id: proximityArea
        x: Math.round(fox.x - (width - fox.width) / 2)
        y: Math.round(fox.y - (height - fox.height) / 2)
        width: Math.round(root.scaledCellWidth * 1.8)
        height: Math.round(root.scaledCellHeight * 1.4)
        hoverEnabled: true
        acceptedButtons: Qt.NoButton

        onPositionChanged: function(mouse) {
          if (!root.service || !root.service.followCursor) return
          if (root.service.isDragging || root.service.isJumping) return
          var centerDist = mouse.x - width / 2
          if (Math.abs(centerDist) > 8) {
            root.service.pointerGlanceDirection = centerDist > 0 ? 1 : -1
            root.service.pointerNear = true
          }
        }
        onExited: {
          if (root.service) root.service.pointerNear = false
        }
      }

      // Snug click + drag surface. Calibrated to the visible fox body,
      // eliminating cursor jitter via parent-mapped coordinates, supporting
      // cross-monitor drag, and cleanly discriminating single vs double clicks.
      MouseArea {
        id: foxHit
        x: Math.round(fox.x + fox.width * 0.1)
        y: Math.round(fox.y + fox.height * 0.15)
        width: Math.round(fox.width * 0.8)
        height: Math.round(fox.height * 0.82)
        cursorShape: root.service && root.service.isDragging
          ? Qt.ClosedHandCursor
          : Qt.PointingHandCursor
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        property real grabOffsetX: 0
        property real grabOffsetY: 0
        property real pressMouseX: 0
        property real pressMouseY: 0
        property bool dragMoved: false
        property bool pressed: false

        onPressed: function(mouse) {
          pressed = true
          dragMoved = false
          pressMouseX = mouse.x
          pressMouseY = mouse.y
          var pt = foxHit.mapToItem(panel, mouse.x, mouse.y)
          grabOffsetX = pt.x - root.serviceX
          grabOffsetY = pt.y - root.serviceY
          if (root.service) {
            root.service.isDragging = true
            root.service.cancelSleep()
          }
        }

        onPositionChanged: function(mouse) {
          if (!pressed || !root.service) return
          if (!dragMoved) {
            if (Math.abs(mouse.x - pressMouseX) > 4 || Math.abs(mouse.y - pressMouseY) > 4) {
              dragMoved = true
            }
          }
          var pt = foxHit.mapToItem(panel, mouse.x, mouse.y)
          var targetLocalX = pt.x - grabOffsetX
          var targetLocalY = pt.y - grabOffsetY

          // Seamless multi-monitor dragging
          var abs = root.service.toAbsolute(targetLocalX, targetLocalY)
          var at = root.service.screenAt(abs.x, abs.y)
          if (at && at.index !== root.service.currentScreenIndex) {
            root.service.currentScreenIndex = at.index
            var local = root.service.toLocal(abs.x, abs.y, at.index)
            root.service.positionX = local.x
            root.service.positionY = local.y
            root.service.recomputeGround()
          } else {
            root.service.positionX = targetLocalX
            root.service.positionY = targetLocalY
          }
        }

        onReleased: function(mouse) {
          pressed = false
          hint.dismissed = true
          if (!root.service) return
          var wasDrag = dragMoved
          dragMoved = false
          if (wasDrag) {
            var g = root.service.currentScreen()
              ? root.service.screenGeometry(root.service.currentScreen()).height
                - root.scaledCellHeight - root.service.groundMargin
              : 0
            root.service.settleDrop(g)
          }
        }

        onClicked: function(mouse) {
          hint.dismissed = true
          if (dragMoved || !root.service) return
          if (mouse.button === Qt.RightButton) {
            root.service.resetPosition()
            return
          }
          if (mouse.button === Qt.MiddleButton) {
            root.service.sleepToggle()
            return
          }
          if (mouse.button !== Qt.LeftButton) return

          // Double-click discrimination: cancels single-click timer so poke is never triggered
          if (singleClickTimer.running) {
            singleClickTimer.stop()
            root.service.sleepNow()
          } else {
            singleClickTimer.restart()
          }
        }

        Timer {
          id: singleClickTimer
          interval: 220
          repeat: false
          onTriggered: {
            if (root.service && !root.service.isDragging) {
              root.service.poke()
            }
          }
        }
      }
    }
  }

  // IPC for the panel itself lives on the Service (target: "fox-pet").
}

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
  // and which frame within the row. We translate the cached sheet under
  // a cell-sized viewport, keeping source and texture size unchanged.
  //
  // sourceSize keeps the full sheet at native resolution.
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
    ? service.spriteSpec
    : { row: 0, frames: 8, fps: 5 }
  readonly property int frameRow: rowSpec.row
  readonly property int frameCount: rowSpec.frames
  readonly property int frameCol: service ? service.spriteFrame : 0
  readonly property int frameX: frameCol * cellWidth
  readonly property int frameY: frameRow * cellHeight

  // Qt.resolvedUrl walks up to the panel QML's directory, so the panel
  // doesn't depend on whatever cwd the shell happened to launch in.
  readonly property string spriteUrl: service ? service.spriteUrl : Qt.resolvedUrl("assets/spritesheet.webp")

  // Direction mirrors the sprite horizontally. The flipper's transform
  // list does ONLY a horizontal mirror — never a vertical one — so
  // `scale: -1` doesn't accidentally flip the fox upside-down.
  readonly property real facingScale: service && service.spriteState === service.stateWalk && service.direction === -1 ? -1 : 1

  // Dedicated curled-up sleep sprite in row 5 requires no synthetic tilt or shrink.
  readonly property bool isSleeping: service && service.petState === service.stateSleep
  readonly property real sleepTilt: 0
  readonly property real sleepScale: 1.0

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
        // Expands to the full window item while dragging to guarantee uninterrupted Wayland
        // pointer grab at any velocity. In idle mode, tightly tracks dragProxy across the screen
        // so clicks anywhere outside the fox fall cleanly through to windows underneath.
        item: (foxHit.drag.active || (root.service && root.service.isDragging)) ? windowRoot : dragProxy
      }

      // Root item providing a valid QQuickItem covering the full panel frame for dynamic masking
      Item {
        id: windowRoot
        anchors.fill: parent
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
        x: Math.max(20, Math.min(panel.width - width - 20, Math.round(dragProxy.x + root.scaledCellWidth / 2 - width / 2)))
        y: Math.max(20, Math.round(dragProxy.y - height - 12))

        Text {
          id: hintText
          anchors.centerIn: parent
          color: "#f0f0f0"
          font.pixelSize: 12
          font.family: Style.font.family
          text: "🦊  click = greet · double-click / scroll-down = sleep · scroll-up = jump · drag = move"
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
        x: Math.round(dragProxy.x + (root.scaledCellWidth - width) / 2)
        y: root.service
          ? Math.round(root.service.groundY + root.scaledCellHeight - 12 * root.scale)
          : Math.round(dragProxy.y + root.scaledCellHeight - 12 * root.scale)
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

      // Drag proxy item: coordinates bound to service when idle,
      // driven directly by QtQuick drag handler during active drag.
      Item {
        id: dragProxy
        Binding on x {
          when: !foxHit.drag.active
          value: root.serviceX
        }
        Binding on y {
          when: !foxHit.drag.active
          value: root.serviceY
        }
        width: root.scaledCellWidth
        height: root.scaledCellHeight

        onXChanged: {
          if (foxHit.drag.active && root.service) {
            root.service.positionX = dragProxy.x
          }
        }
        onYChanged: {
          if (foxHit.drag.active && root.service) {
            root.service.positionY = dragProxy.y
          }
        }

        // Fractional positions preserve slow easing; the cached sheet is
        // translated under a fixed viewport instead of reloading source crops.
        SpriteView {
          id: fox
          anchors.fill: parent
          source: root.spriteUrl
          columns: root.columns
          rowCount: root.rowCount
          cellWidth: root.cellWidth
          cellHeight: root.cellHeight
          frameRow: root.frameRow
          frameCol: root.frameCol
          frameOffsetY: root.service ? root.service.spriteOffsetY : 0
          facing: root.facingScale
          squash: root.service ? root.service.landingSquash : 0
          suspended: root.service && (root.service.movementPhase === "falling" || root.service.movementPhase === "rising")
          sleeping: root.isSleeping
          softenFrames: root.service && root.service.spriteState === root.service.stateYawn
          breathing: root.service && root.service.movementPhase === "grounded"
            && (root.service.spriteState === root.service.stateIdle || root.service.spriteState === root.service.stateSleep)
          active: panel.visible
          dragging: root.service && root.service.isDragging
        }

        // Responsive click + drag surface. Fills dragProxy to make the entire fox body
        // responsive to mouse gestures (clicks, double-clicks, drags, scroll wheel, and petting).
        MouseArea {
          id: foxHit
          anchors.fill: parent
          cursorShape: root.service && root.service.isDragging
            ? Qt.ClosedHandCursor
            : Qt.PointingHandCursor
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

          drag.target: dragProxy
          drag.axis: Drag.XAndYAxis
          drag.minimumX: 0
          drag.maximumX: panel.width - root.scaledCellWidth
          drag.minimumY: 0
          // Keep the paws above the ground plane during the grab as well,
          // so release never snaps her upward out of the bottom inset.
          drag.maximumY: Math.max(0, root.service ? root.service.groundY : panel.height - root.scaledCellHeight)

          // Gesture state tracking
          property real lastStrokeX: 0
          property int strokeReversals: 0
          property real lastStrokeTime: 0

          drag.onActiveChanged: {
            if (!root.service) return
            if (!drag.active) {
              // Check if dropped onto another monitor at release time
              var abs = root.service.toAbsolute(dragProxy.x, dragProxy.y)
              var at = root.service.screenAt(abs.x, abs.y)
              if (at && at.index !== root.service.currentScreenIndex) {
                root.service.currentScreenIndex = at.index
                var local = root.service.toLocal(abs.x, abs.y, at.index)
                root.service.positionX = local.x
                root.service.positionY = local.y
                root.service.recomputeGround()
              }
              var g = root.service.currentScreen()
                ? root.service.screenGeometry(root.service.currentScreen()).height
                  - root.scaledCellHeight - root.service.groundMargin
                : 0
              root.service.settleDrop(g)
            } else {
              root.service.beginDrag()
            }
          }

          onCanceled: {
            if (root.service && root.service.isDragging) root.service.settleDrop()
          }

          onPositionChanged: function(mouse) {
            if (!root.service) return
            if (drag.active) return

            // Petting / stroking gesture detection (rubbing cursor horizontally across the fox)
            var now = Date.now()
            if (now - lastStrokeTime > 800) {
              strokeReversals = 0
              lastStrokeTime = now
            }
            if (lastStrokeX !== 0) {
              var deltaX = mouse.x - lastStrokeX
              if (Math.abs(deltaX) > 12) {
                strokeReversals++
                lastStrokeTime = now
                if (strokeReversals >= 4) {
                  strokeReversals = 0
                  if (root.service.petState === root.service.stateSleep) {
                    root.service.poke()
                  } else {
                    root.service.startAction(root.service.statePlay, 1400)
                  }
                }
              }
            }
            lastStrokeX = mouse.x

            // Precise cursor glance: eliminate redundant property assignments at high polling rates
            if (!root.service.followCursor || root.service.isJumping) return
            var centerDist = mouse.x - width / 2
            if (Math.abs(centerDist) > 8) {
              var newDir = centerDist > 0 ? 1 : -1
              if (root.service.pointerGlanceDirection !== newDir) {
                root.service.pointerGlanceDirection = newDir
              }
              if (!root.service.pointerNear) {
                root.service.pointerNear = true
              }
            }
          }

          onExited: {
            if (root.service) root.service.pointerNear = false
            strokeReversals = 0
            lastStrokeX = 0
          }

          // Wheel gestures: scroll UP to jump, scroll DOWN to sleep/wake
          onWheel: function(wheel) {
            if (!root.service || root.service.isDragging) return
            if (wheel.angleDelta.y > 0) {
              root.service.jump()
            } else if (wheel.angleDelta.y < 0) {
              root.service.sleepToggle()
            }
          }

          onClicked: function(mouse) {
            hint.dismissed = true
            if (!root.service || foxHit.drag.active) return
            if (mouse.button === Qt.RightButton) {
              root.service.resetPosition()
              return
            }
            if (mouse.button === Qt.MiddleButton) {
              root.service.sleepToggle()
              return
            }
            if (mouse.button !== Qt.LeftButton) return

            // Calibrated double-click discrimination: cancels single-click timer and toggles sleep
            if (singleClickTimer.running) {
              singleClickTimer.stop()
              root.service.sleepToggle()
            } else {
              singleClickTimer.restart()
            }
          }

          Timer {
            id: singleClickTimer
            interval: 320
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
  }

  // IPC for the panel itself lives on the Service (target: "fox-pet").
}

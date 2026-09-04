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
    if (service) {
      service.resetPosition()
      if (!service.enabled) service.enable()
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

  readonly property int scaledCellWidth: Math.round(cellWidth * scale)
  readonly property int scaledCellHeight: Math.round(cellHeight * scale)

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

      // Hint banner the first time the user summons the fox. Hides
      // itself after a few seconds or as soon as the user interacts.
      Rectangle {
        id: hint
        visible: hintTimer.running && !hint.dismissed
        opacity: visible ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        width: hintText.implicitWidth + 24
        height: hintText.implicitHeight + 16
        radius: 8
        color: Qt.rgba(0.12, 0.12, 0.12, 0.85)
        border.color: Qt.rgba(1, 1, 1, 0.18)
        border.width: 1
        x: Math.max(20, Math.min(panel.width - width - 20, root.serviceX + root.scaledCellWidth / 2 - width / 2))
        y: Math.max(20, root.serviceY - height - 12)

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
          onTriggered: hint.visible = false
        }
        property bool dismissed: false
      }

      // Drop shadow. A stepped opacity stack makes a believable radial
      // falloff without paying for a RadialGradient's per-frame setup.
      // Four concentric ellipses, each fainter than the one inside it.
      Item {
        id: shadow
        visible: root.service && root.service.showShadow
        x: root.serviceX + Math.round(root.scaledCellWidth / 2 - width / 2)
        y: root.serviceY + root.scaledCellHeight - Math.round(10 * root.scale)
        width: Math.round(root.scaledCellWidth * 0.7)
        height: Math.round(18 * root.scale)

        Item {
          anchors.fill: parent
          clip: true

          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.40
            height: parent.height * 0.55
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.45)
          }
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.60
            height: parent.height * 0.80
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.20)
          }
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.80
            height: parent.height * 0.95
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.08)
          }
        }
      }

      // Fox sprite. Outer Item is the position / hit box. The flipper
      // is a thin wrapper inside that handles the horizontal mirror
      // AND the sleep-pose tilt + shrink. Using a transform list (not
      // the `scale` property) lets us flip only the X axis — using
      // `scale: -1` here was the bug that flipped the fox upside-down,
      // because Qt's `scale` property is a vector3d that defaults Y to
      // -1 when X is -1.
      Item {
        id: fox
        x: root.serviceX
        y: root.serviceY
        width: root.scaledCellWidth
        height: root.scaledCellHeight
        clip: true

        Item {
          id: flipper
          anchors.fill: parent
          // Sleep pose: tilt + shrink applied as Item properties with
          // transformOrigin at the center. Both compose without the
          // per-element origin drama of a transform list.
          transformOrigin: Item.Center
          rotation: root.isSleeping ? 12 : 0
          scale: root.isSleeping ? 0.85 : 1.0

          Image {
            id: sprite
            anchors.fill: parent
            source: root.spriteUrl
            fillMode: Image.Stretch
            smooth: true
            mipmap: true
            asynchronous: true
            cache: true
            // Qt's Image.mirror flips the rendered pixels horizontally
            // without touching the bounding box, the hit area, or the
            // transform pipeline. Using it instead of a Matrix4x4 +
            // Scale combo keeps the renderer on a single fast path and
            // removes the brief-blank frames we saw when the
            // transform list re-evaluated mid-layout.
            mirror: root.facingScale === -1
            sourceClipRect: Qt.rect(root.frameX, root.frameY, root.cellWidth, root.cellHeight)
            sourceSize: Qt.size(root.cellWidth * root.columns,
                                root.cellHeight * root.rowCount)
          }
        }
      }

      // Click + drag surface. Anchored to the fox bounding box so the
      // hit area follows the sprite's position. The MouseArea captures
      // all events within its rect; clicks outside it fall through to
      // whatever's underneath because exclusionMode is Ignore and we
      // do NOT mask the whole surface.
      //
      // The MouseArea is INSIDE the flipper. When the flipper's
      // transform mirrors the sprite horizontally, the MouseArea's
      // bounding box is NOT mirrored — only the rendered sprite is.
      // That keeps `mouse.x` and the drag math in screen-local
      // coordinates regardless of which way the fox faces, which is
      // what the user expects (drag right → fox follows right).
      MouseArea {
        id: foxHit
        x: fox.x
        y: fox.y
        width: fox.width
        height: fox.height
        cursorShape: root.service && root.service.isDragging
          ? Qt.ClosedHandCursor
          : Qt.PointingHandCursor
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        property real lastX: 0
        property real lastY: 0
        property bool pressed: false

        onEntered: {
          if (root.service && root.service.followCursor) root.service.pointerNear = true
        }
        onExited: {
          if (root.service) root.service.pointerNear = false
        }

        onPressed: function(mouse) {
          pressed = true
          lastX = mouse.x
          lastY = mouse.y
          if (root.service) {
            root.service.isDragging = true
            // Treat the press itself as the first tick of the click
            // handler so a press-then-release with no movement still
            // counts as a click on the same screen pixel.
            root.service.cancelSleep()
          }
        }

        onPositionChanged: function(mouse) {
          if (!pressed || !root.service) return
          // Raw screen-local deltas. The MouseArea is un-flipped even
          // when the visual sprite is, so multiplying by facingScale
          // here would invert the drag direction — which is what the
          // previous code did, hence the "fox runs away from the
          // cursor when facing left" bug.
          var dx = mouse.x - lastX
          var dy = mouse.y - lastY
          lastX = mouse.x
          lastY = mouse.y
          root.service.positionX += dx
          root.service.positionY += dy
          // Clamp inside this screen's local bounds. The service's
          // physics timer clamps again on the next tick; this is the
          // immediate-response clamp so a fast drag doesn't fling the
          // fox off-screen.
          var scaledW = root.scaledCellWidth
          var scaledH = root.scaledCellHeight
          if (root.service.positionX < 0) root.service.positionX = 0
          if (root.service.positionX > panel.width - scaledW)
            root.service.positionX = Math.max(0, panel.width - scaledW)
          if (root.service.positionY < 0) root.service.positionY = 0
          if (root.service.positionY > panel.height - scaledH)
            root.service.positionY = Math.max(0, panel.height - scaledH)
        }

        onReleased: {
          pressed = false
          hint.dismissed = true
          if (!root.service) return
          // The "bouncing ball" behavior came from clearing isDragging
          // and leaving physics to take over mid-air. The user wants
          // the fox to land where they dropped it. If the release
          // point is above the ground, we ask the service to land it
          // softly (settling on the ground line instead of falling
          // and rebounding); if it's already on the ground line, the
          // settle is a no-op.
          var g = root.service.currentScreen
            ? root.service.screenGeometry(root.service.currentScreen()).height
              - root.scaledCellHeight - root.service.groundMargin
            : 0
          root.service.settleDrop(g)
        }

        onClicked: function(mouse) {
          hint.dismissed = true
          if (!root.service) return
          // Right click resets position; middle click toggles sleep.
          // Left click is the greet/double-click-sleep chain.
          if (mouse.button === Qt.RightButton) {
            root.service.resetPosition()
            return
          }
          if (mouse.button === Qt.MiddleButton) {
            root.service.sleepToggle()
            return
          }
          if (mouse.button !== Qt.LeftButton) return
          if (doubleClickTimer.running) {
            doubleClickTimer.stop()
            root.service.sleepNow()
          } else {
            doubleClickTimer.interval = 250
            doubleClickTimer.restart()
            root.service.poke()
          }
        }

        Timer {
          id: doubleClickTimer
          interval: 250
          repeat: false
        }
      }
    }
  }

  // IPC for the panel itself lives on the Service (target: "fox-pet"),
  // because the service is always loaded when the plugin is enabled and
  // it can decide whether to show the panel itself. Duplicating the
  // target here would make Quickshell drop one of the registrations.
}

// reload

// reload 2

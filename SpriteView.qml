pragma ComponentBehavior: Bound
import QtQuick

// A shared atlas texture with two cell views only while a pose dissolves.
// All deformation pivots around the paws, leaving placement and input alone.
//
// Procedural in-betweens fill the gaps:
// - Turnaround is handled cleanly via Row 9 rotational frames in Service.qml.
// - Facing is strictly discrete (+1 or -1), completely eliminating coin-flip distortions.
// - Stride bob rides on render item only; dragProxy and hitbox remain unaffected.
// - Subtle body tilt leans into movement.
// - Subtle breathing cycles continuously while idle or sleeping.
Item {
  id: root

  property url source
  property int columns: 8
  property int rowCount: 11
  property int cellWidth: 192
  property int cellHeight: 208
  property int frameRow: 0
  property int frameCol: 0
  property real frameOffsetY: 0
  property real facing: 1
  property bool isTurning: false
  property real tiltDeg: 0
  property real walkPhase: 0
  property real speedMix: 0
  property real squash: 0
  property bool suspended: false
  property bool sleeping: false
  property bool softenFrames: false
  property bool spriteFast: false
  property bool breathing: false
  property bool emoteSway: false
  property bool active: true
  property bool dragging: false

  property int currentRow: -1
  property int currentFrame: 0
  property real currentOffset: 0
  property int previousRow: 0
  property int previousFrame: 0
  property real previousOffset: 0
  property bool previousSleeping: false
  property real poseMix: 1
  property real breath: 0
  property real stretch: suspended && !sleeping ? 0.025 : 0
  property real sway: 0
  property bool ready: false

  // Stride bob: two steps per phase cycle, amplitude scaled by speedMix so
  // the body settles instead of snapping when locomotion eases out.
  // Grounded only — suspension uses stretch, turning keeps feet planted.
  readonly property real strideBob: (dragging || suspended || isTurning) ? 0 : Math.cos(walkPhase * 2) * 3.2 * speedMix

  function updatePose() {
    if (!ready) return
    // When turning, cut frames crisply without crossfading to preserve 2D perspective sharpness.
    if (isTurning) {
      dissolve.stop()
      poseMix = 1
      currentRow = frameRow
      currentFrame = frameCol
      currentOffset = frameOffsetY
      return
    }
    if (currentRow >= 0 && (frameRow !== currentRow || (softenFrames && frameCol !== currentFrame))) {
      dissolve.stop()
      previousRow = currentRow
      previousFrame = currentFrame
      previousOffset = currentOffset
      // Keep fast locomotion and emote dissolves under one frame cadence so
      // micro movements never visibly lag the physics step.
      dissolve.duration = softenFrames ? 150 : spriteFast ? 90 : sleeping || previousSleeping ? 420 : 130
      poseMix = active && !dragging ? 0 : 1
      if (poseMix === 0) dissolve.start()
    }
    currentRow = frameRow
    currentFrame = frameCol
    currentOffset = frameOffsetY
    previousSleeping = sleeping
  }

  onFrameRowChanged: updatePose()
  onFrameColChanged: updatePose()
  onFrameOffsetYChanged: updatePose()
  onIsTurningChanged: if (isTurning) { dissolve.stop(); poseMix = 1 }
  onDraggingChanged: if (dragging) { dissolve.stop(); poseMix = 1 }
  Component.onCompleted: { ready = true; updatePose() }

  NumberAnimation { id: dissolve; target: root; property: "poseMix"; to: 1; easing.type: Easing.InOutSine }
  Behavior on stretch { NumberAnimation { duration: 280; easing.type: Easing.InOutSine } }
  SequentialAnimation on breath {
    running: root.active && root.breathing && !root.dragging
    loops: Animation.Infinite
    NumberAnimation { to: 1; duration: 1700; easing.type: Easing.InOutSine }
    NumberAnimation { to: 0; duration: 1700; easing.type: Easing.InOutSine }
  }
  // Tail-wag sway during emotes: slow lateral rock around the paws.
  SequentialAnimation on sway {
    running: root.active && root.emoteSway && !root.dragging
    loops: Animation.Infinite
    NumberAnimation { to: 1; duration: 520; easing.type: Easing.InOutSine }
    NumberAnimation { to: -1; duration: 1040; easing.type: Easing.InOutSine }
    NumberAnimation { to: 0; duration: 520; easing.type: Easing.InOutSine }
  }
  onEmoteSwayChanged: if (!emoteSway) sway = 0

  component AtlasCell: Item {
    property int row: 0
    property int frame: 0
    clip: true
    Image {
      x: -parent.frame * root.width
      y: -parent.row * root.height
      width: root.columns * root.width
      height: root.rowCount * root.height
      source: root.source
      sourceSize: Qt.size(root.columns * root.cellWidth, root.rowCount * root.cellHeight)
      smooth: true
      cache: true
    }
  }

  Item {
    anchors.fill: parent
    transform: [
      Translate {
        // Stride bob rides the render item only; dragProxy and hitbox stay put.
        y: root.strideBob * root.height / root.cellHeight
      },
      Rotation {
        origin.x: root.width / 2
        origin.y: root.height * (root.cellHeight - 5) / root.cellHeight
        angle: root.tiltDeg + (root.emoteSway ? root.sway * 2.5 : 0)
      },
      Scale {
        origin.x: root.width / 2
        origin.y: root.height * (root.cellHeight - 5) / root.cellHeight
        xScale: (root.facing >= 0 ? 1 : -1) * (1 + root.squash - root.stretch / 2)
        yScale: 1 - root.squash + root.stretch + (root.breathing ? root.breath * 0.008 : 0)
      }
    ]
    AtlasCell {
      width: root.width
      height: root.height
      y: root.previousOffset * root.height / root.cellHeight
      row: root.previousRow
      frame: root.previousFrame
      opacity: 1 - root.poseMix
      visible: opacity > 0
    }
    AtlasCell {
      width: root.width
      height: root.height
      y: root.currentOffset * root.height / root.cellHeight
      row: Math.max(0, root.currentRow)
      frame: root.currentFrame
      opacity: root.poseMix
    }
  }
}

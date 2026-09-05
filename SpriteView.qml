pragma ComponentBehavior: Bound
import QtQuick

// A shared atlas texture with two cell views only while a pose dissolves.
// All deformation pivots around the paws, leaving placement and input alone.
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
  property real squash: 0
  property bool suspended: false
  property bool sleeping: false
  property bool softenFrames: false
  property bool breathing: false
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
  property bool ready: false

  function updatePose() {
    if (!ready) return
    if (currentRow >= 0 && (frameRow !== currentRow || (softenFrames && frameCol !== currentFrame))) {
      dissolve.stop()
      previousRow = currentRow
      previousFrame = currentFrame
      previousOffset = currentOffset
      // Finish a crouch dissolve before its next 240ms pose arrives.
      dissolve.duration = softenFrames ? 180 : sleeping || previousSleeping ? 420 : 160
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
    transform: Scale {
      origin.x: root.width / 2
      origin.y: root.height * (root.cellHeight - 5) / root.cellHeight
      xScale: root.facing * (1 + root.squash - root.stretch / 2)
      yScale: 1 - root.squash + root.stretch + (root.breathing ? root.breath * 0.008 : 0)
    }
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

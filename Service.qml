import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons

// Fox pet service — owns the fox's persistent state, the AI that picks its
// next move, the physics step that drives gravity + screen edges, and the
// frame counter that the panel reads to draw the right sprite cell.
//
// Why this lives in a service and not in the panel: the panel only renders
// what the fox is doing, and the user can summon/hide the panel without
// losing the fox's mood or position. The service keeps ticking while the
// panel is hidden, so when you bring the fox back up it has been living
// its life the whole time.
Item {
  id: service

  // Injected by omarchy-shell (see shell.qml _syncServices and the panel
  // loader). The service exposes its own state through these properties;
  // the panel binds to them and re-renders when any of them change.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/fox-pet"
  readonly property string stateDir: home + "/.local/state/omarchy/fox-pet"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string petMetaPath: pluginDir + "/assets/pet.json"

  // ---------------------------------------------------------- sprite grid
  //
  // Defaults match a stock 8×11 sheet of 192×208 cells. These get overwritten
  // by petMetaLoader as soon as assets/pet.json reads; until then the
  // service still answers requests with sane numbers so the panel can mount
  // before the meta lands.
  readonly property int defaultColumns: 8
  readonly property int defaultCellWidth: 192
  readonly property int defaultCellHeight: 208
  readonly property int defaultRowCount: 11

  property int columns: defaultColumns
  property int cellWidth: defaultCellWidth
  property int cellHeight: defaultCellHeight
  property int rowCount: defaultRowCount

  // What the fox is up to. Drives which row of the sprite grid the panel
  // pulls frames from and whether the panel flips the cell horizontally.
  // Keep the strings stable — Panel.qml branches on them.
  readonly property string stateIdle:      "idle"
  readonly property string stateWalk:      "walk"
  readonly property string stateSitRight:  "sitRight"
  readonly property string stateSitLeft:   "sitLeft"
  readonly property string stateGreet:     "greet"
  readonly property string stateSleep:     "sleep"
  readonly property string statePlay:      "play"
  readonly property string stateAlert:     "alert"
  readonly property string stateYawn:      "yawn"
  readonly property string stateThink:      "think"
  readonly property string stateSpin:       "spin"
  // Row 10 of the spritesheet is a headstand / somersault pose. It's a
  // rare delight, not a default AI target — it can only be triggered
  // explicitly via the somersault() API.
  readonly property string stateSomersault: "somersault"

  // Row index in the sprite grid for each state. The default table is for
  // the stock spritesheet; petMetaLoader replaces it once pet.json is read.
  // Frames within a row cycle at `fps` Hz — frames per state is encoded
  // below. Some states (greet, yawn) only have a few useful frames before
  // the motion repeats; the others have 8 and loop continuously.
  readonly property var defaultRows: ({
    "idle":       { row: 0, frames: 8, fps: 5 },
    "walk":       { row: 1, frames: 8, fps: 8 },
    "sitRight":   { row: 1, frames: 8, fps: 4 },
    "sitLeft":    { row: 2, frames: 8, fps: 4 },
    "greet":      { row: 3, frames: 4, fps: 8 },
    "yawn":       { row: 4, frames: 4, fps: 4 },
    "sleep":      { row: 5, frames: 8, fps: 3 },
    "play":       { row: 6, frames: 8, fps: 8 },
    "think":      { row: 7, frames: 8, fps: 5 },
    "alert":      { row: 8, frames: 8, fps: 6 },
    "spin":       { row: 9, frames: 8, fps: 10 },
    "somersault": { row: 10, frames: 8, fps: 5 }
  })

  property var rows: defaultRows

  // Pet metadata (display name + description) pulled from assets/pet.json.
  // The bar widget reads these for its tooltip.
  property string petDisplayName: "Fox"
  property string petDescription: ""
  property int spriteVersionNumber: 1
  property string spriteUrl: Qt.resolvedUrl("assets/spritesheet.webp")

  // ---------------------------------------------------------- world model
  //
  // Position is the top-left of the sprite cell in screen-local coordinates
  // for the screen the fox is currently on. The panel renders at
  // (positionX, positionY) and uses (cellWidth, cellHeight) as the bounding
  // rect for clicks and masks. `velocityX` is in px/step (60 steps/sec).
  // Gravity is also per-step.
  property bool enabled: false
  property string petState: stateIdle
  property int direction: 1                     // 1 = facing right, -1 = left
  property int frameIndex: 0                     // index within the current row
  property real positionX: 200                  // sprite top-left, px
  property real positionY: 200                  // sprite top-left, px
  property real velocityX: 0
  property real velocityY: 0
  // Index into Quickshell.screens of the screen the fox is currently on.
  // Persisted so the fox comes back on the same monitor after a restart.
  property int currentScreenIndex: 0

  // The bar widget's settings, mirrored locally so the panel sees them
  // without having to chase the bar's reactivity.
  property bool physicsEnabled: true
  property bool showShadow: true
  property bool followCursor: true
  property real scale: 1.0

  // Tunable knobs. Reasonable defaults — the AI isn't aggressive and the
  // physics is gentle so it reads as a calm companion, not a pinball.
  readonly property real gravity: 0.45
  readonly property real bounce: 0.30
  readonly property real walkSpeed: 1.6
  readonly property real jumpImpulse: -10.5
  // A small grace period at the edge of a screen so the fox doesn't reverse
  // direction with a single px of overhang.
  readonly property int edgeMargin: 4
  property bool isJumping: false

  // True while the user is dragging the fox around. The AI pauses so it
  // doesn't fight the user for control.
  property bool isDragging: false

  // The cursor is hovering the fox's hit area. With followCursor enabled
  // the fox glances toward the cursor briefly instead of freezing.
  property bool pointerNear: false
  property int pointerGlanceAt: 0
  property int pointerGlanceDirection: 1
  property bool manualSleep: false

  // The AI lives on a rolling timer that decides the fox's next mood a few
  // seconds into the future. The chosen action then runs on its own timers
  // (animation cadence, walking duration) until it finishes or the AI picks
  // something else.
  property string pendingAction: ""
  property int pendingDurationMs: 0

  // Greet-chaining guard. The previous version re-rolled greet with an
  // 80% probability which produced back-to-back greets in a row; this
  // counter caps it at one greet per cycle and falls back to idle.
  property int greetChainLeft: 0

  // ---------------------------------------------------- AI behavior picker
  //
  // The fox has two home-base states (idle and walk) and a small set of
  // emote states that interrupt briefly before the AI returns to idle.
  // Weights are tuned so the fox spends ~85% of its time in the home
  // states and ~15% emoting — not metronome-emoting every few seconds.
  readonly property var actionWeights: [
    { action: stateIdle,     weight: 42 },
    { action: stateWalk,     weight: 28 },
    { action: stateSitRight, weight: 6 },
    { action: stateSitLeft,  weight: 6 },
    { action: stateSleep,    weight: 4 },
    { action: statePlay,     weight: 5 },
    { action: stateAlert,    weight: 5 },
    { action: stateYawn,     weight: 4 }
  ]

  function pickAction() {
    var total = 0
    for (var i = 0; i < actionWeights.length; i++) total += actionWeights[i].weight
    var roll = Math.random() * total
    for (var j = 0; j < actionWeights.length; j++) {
      roll -= actionWeights[j].weight
      if (roll <= 0) return actionWeights[j].action
    }
    return actionWeights[0].action
  }

  // Random duration in ms for a given action. The home-base states
  // (idle, walk, sits, sleep) hold for several seconds so the fox
  // settles between emotes. The emote states (greet, play, alert,
  // yawn) are short bursts — under three seconds — so they read as
  // reactions, not as the fox's primary activity.
  function durationFor(action) {
    if (action === stateIdle)     return 4000 + Math.floor(Math.random() * 4500)
    if (action === stateWalk)     return 3200 + Math.floor(Math.random() * 3500)
    if (action === stateSleep)    return 8000 + Math.floor(Math.random() * 8000)
    if (action === statePlay)     return 1800 + Math.floor(Math.random() * 1500)
    if (action === stateAlert)    return 1200 + Math.floor(Math.random() * 1500)
    if (action === stateGreet)    return 1000 + Math.floor(Math.random() * 1200)
    if (action === stateYawn)     return 1400 + Math.floor(Math.random() * 1000)
    if (action === stateSitRight) return 4000 + Math.floor(Math.random() * 4000)
    if (action === stateSitLeft)  return 4000 + Math.floor(Math.random() * 4000)
    if (action === stateSomersault) return 1600
    if (action === stateSpin) return 1200
    if (action === stateThink) return 2200
    return 2000
  }

  // ---------------------------------------------------- screen geometry
  //
  // Multi-monitor support: every read of a screen dimension goes through
  // these helpers. Quickshell.screens is an array of Screen objects, each
  // carrying width/height/x/y in the virtual desktop coordinate space.
  //
  // currentScreen() returns the screen the fox thinks it's on, clamped to a
  // valid index when the saved index is no longer present (a monitor was
  // unplugged). screenGeometry() returns the full bounds for whichever
  // screen is current at the moment of the call.
  function screenCount() {
    return Quickshell.screens.length
  }

  function currentScreen() {
    if (Quickshell.screens.length === 0) return null
    var idx = currentScreenIndex
    if (idx < 0 || idx >= Quickshell.screens.length) idx = 0
    return Quickshell.screens[idx]
  }

  function screenGeometry(screen) {
    if (!screen) return { x: 0, y: 0, width: 1440, height: 900 }
    return {
      x: Number(screen.x || 0),
      y: Number(screen.y || 0),
      width: Number(screen.width || 1440),
      height: Number(screen.height || 900)
    }
  }

  // Pick the screen that contains the given absolute point. Falls back to
  // the closest screen when the point is in the gap between two monitors.
  function screenAt(absoluteX, absoluteY) {
    if (Quickshell.screens.length === 0) return null
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var g = screenGeometry(Quickshell.screens[i])
      if (absoluteX >= g.x && absoluteX < g.x + g.width
          && absoluteY >= g.y && absoluteY < g.y + g.height)
        return { index: i, screen: Quickshell.screens[i], geometry: g }
    }
    // Closest by Manhattan distance.
    var best = 0
    var bestDist = Number.MAX_VALUE
    for (var j = 0; j < Quickshell.screens.length; j++) {
      var sg = screenGeometry(Quickshell.screens[j])
      var cx = Math.max(sg.x, Math.min(absoluteX, sg.x + sg.width - 1))
      var cy = Math.max(sg.y, Math.min(absoluteY, sg.y + sg.height - 1))
      var d = Math.abs(absoluteX - cx) + Math.abs(absoluteY - cy)
      if (d < bestDist) { bestDist = d; best = j }
    }
    return { index: best, screen: Quickshell.screens[best], geometry: screenGeometry(Quickshell.screens[best]) }
  }

  // Convert between screen-local coords (the storage model) and absolute
  // coords (used to look up which screen the cursor is on, etc).
  function toAbsolute(localX, localY) {
    var g = screenGeometry(currentScreen())
    return { x: g.x + localX, y: g.y + localY }
  }

  function toLocal(absoluteX, absoluteY, screenIdx) {
    var idx = screenIdx !== undefined ? screenIdx : currentScreenIndex
    if (idx < 0 || idx >= Quickshell.screens.length) idx = 0
    var g = screenGeometry(Quickshell.screens[idx])
    return { x: absoluteX - g.x, y: absoluteY - g.y }
  }

  // Reference-identity match against the screen the service thinks the
  // fox is on. The panel uses this from each per-screen PanelWindow to
  // decide whether to render the fox on its surface or stay dark.
  function matchesCurrentScreen(s) {
    if (!s) return false
    if (Quickshell.screens.length === 0) return false
    var idx = currentScreenIndex
    if (idx < 0 || idx >= Quickshell.screens.length) idx = 0
    return Quickshell.screens[idx] === s
  }

  // Recalculate the ground line for the current screen — the fox sits on
  // the bottom inset by cellHeight + a small margin so its feet don't
  // graze the screen edge.
  readonly property int groundMargin: 80
  property real groundY: 600

  function recomputeGround() {
    var g = screenGeometry(currentScreen())
    if (g.height > 0) groundY = Math.round(g.height - cellHeight * scale - groundMargin)
  }

  // After moving the fox (drag, walk, jump), check whether it has crossed
  // onto another screen and update currentScreenIndex / positionX / positionY
  // so the storage stays in screen-local coords on the right screen.
  property int _resyncSuppress: 0
  function resyncScreen() {
    if (_resyncSuppress > 0) return
    if (Quickshell.screens.length === 0) return
    var absolute = toAbsolute(positionX, positionY)
    var at = screenAt(absolute.x, absolute.y)
    if (!at || at.index === currentScreenIndex) return
    currentScreenIndex = at.index
    var local = toLocal(absolute.x, absolute.y, at.index)
    positionX = local.x
    positionY = local.y
    recomputeGround()
  }

  // ---------------------------------------------------- transitions
  //
  // State changes go through these helpers so the AI can wire up its
  // follow-up (set velocity for walking, clear velocity for sitting, etc)
  // in one place. The panel just reads `petState` and the velocity.
  function setState(next) {
    // Always reset frameIndex — clicking the fox while it's already
    // greeting should restart the greet animation, not no-op. The
    // motion profile (velocity, direction) is only set when the state
    // actually changes so a re-entry doesn't reset a walk in progress.
    var changed = petState !== next
    petState = next
    frameIndex = 0
    if (!changed) return
    // Each state resets its own motion profile. Walking is the only state
    // that sets a non-zero velocityX; everything else sits still.
    if (next === stateWalk) {
      // Pick a direction unless the fox was already heading somewhere.
      if (velocityX === 0) {
        direction = (direction === 1 || direction === -1) ? direction : (Math.random() > 0.5 ? 1 : -1)
        velocityX = walkSpeed * direction
      } else {
        direction = velocityX >= 0 ? 1 : -1
      }
    } else {
      velocityX = 0
    }
    // Greet/play/yawn/sleep/somersault pose always faces forward (their
    // frames are drawn right-facing). For other poses, facing tracks
    // the last direction the fox was moving so it doesn't snap.
    if (next === stateGreet || next === statePlay || next === stateSleep
        || next === stateYawn || next === stateSomersault || next === stateSpin || next === stateThink) direction = 1
  }

  function startAction(action, ms) {
    pendingAction = action
    pendingDurationMs = ms
    setState(action)
    if (ms > 0) {
      actionTimer.interval = ms
      actionTimer.restart()
    } else {
      actionTimer.stop()
    }
    // Restart the frame anim timer at the cadence for this pose so the
    // first frame shows for the full duration.
    animTimer.interval = animTimer.cadenceFor()
    animTimer.restart()
  }

  function pickNextAction() {
    if (isDragging) return
    // If manual sleep is active, stay asleep until user interacts.
    if (petState === stateSleep && manualSleep) return

    // Greet chains used to re-roll themselves indefinitely; the counter
    // caps each cycle at one greet, then the fox settles into idle until
    // the next roll.
    if (petState === stateGreet) {
      if (greetChainLeft > 0) {
        greetChainLeft--
        startAction(stateGreet, durationFor(stateGreet))
        return
      }
      startAction(stateIdle, durationFor(stateIdle))
      saveDebounce.restart()
      return
    }
    if (petState === stateSleep) {
      // A sleeping fox wakes into idle, not into a high-energy state.
      startAction(stateIdle, durationFor(stateIdle))
      saveDebounce.restart()
      return
    }
    // After any other emote (sit, play, alert, yawn) or after a long
    // greet chain, return to idle first. From idle we then roll the
    // next action; this stops the fox from chaining emotes back to back.
    var isHome = petState === stateIdle || petState === stateWalk
    if (!isHome) {
      startAction(stateIdle, durationFor(stateIdle))
      saveDebounce.restart()
      return
    }
    // From a home state, bias toward walking so the fox actually
    // wanders around the screen rather than sitting still for a long
    // stretch between walks. Idle is the "between things" pose, not
    // the dominant one — the user wants to see movement.
    var roll = Math.random() * 100
    var action
    if (roll < 55) {
      action = stateWalk
    } else if (roll < 80) {
      action = stateIdle
    } else {
      // Pick from the non-walk non-idle actions.
      action = pickAction()
      while (action === stateWalk || action === stateIdle) {
        action = pickAction()
      }
    }
    var ms = durationFor(action)
    if (action === stateWalk) {
      var g = screenGeometry(currentScreen())
      var leftMargin = edgeMargin
      var rightMargin = g.width - cellWidth * scale - edgeMargin
      if (positionX <= leftMargin) direction = 1
      else if (positionX >= rightMargin) direction = -1
      else direction = Math.random() > 0.5 ? 1 : -1
      velocityX = walkSpeed * direction
      // Re-arm the greet chain so the next time the user clicks the fox
      // gets a clean shot at two greets in a row.
      greetChainLeft = 1
    }
    startAction(action, ms)
  }

  // Manually triggered somersault — the row-10 headstand pose. Played
  // as a timed animation (1.6s) and then the AI returns to idle. Not
  // part of the random action set so the fox doesn't spontaneously
  // flip upside down.
  function somersault() {
    if (isJumping) return
    startAction(stateSomersault, durationFor(stateSomersault))
  }

  // Manually triggered spin — the row-9 360-degree turntable rotation.
  function spin() {
    if (isJumping) return
    startAction(stateSpin, durationFor(stateSpin))
  }

  function jump() {
    if (isJumping) return
    isJumping = true
    velocityY = jumpImpulse
    setState(statePlay)
    // Let the play animation finish, then return to idle so the fox
    // doesn't strand itself in the play pose.
    actionTimer.interval = 700
    actionTimer.restart()
    pendingAction = stateIdle
  }

  // Called by the panel when the user releases a drag. If dropped mid-air,
  // the fox falls gently to the floor with a cushioned landing.
  function settleDrop(groundYHint) {
    if (!enabled) return
    isDragging = false
    isJumping = false
    velocityX = 0
    var ground = groundYHint
    if (typeof ground !== "number" || !isFinite(ground)) {
      var g = screenGeometry(currentScreen())
      ground = Math.round(g.height - cellHeight * scale - groundMargin)
    }
    if (positionY > ground) {
      positionY = ground
      velocityY = 0
    } else if (positionY < 0) {
      positionY = 0
      velocityY = 0
    } else {
      // Released in mid-air: initial fall velocity is zero for a gentle descent
      velocityY = 0
    }
    setState(stateIdle)
    actionTimer.interval = 2500
    actionTimer.restart()
    saveDebounce.restart()
  }

  function resetPosition() {
    // Pick the screen the cursor is on first — that's where the user is
    // looking. Falling back to the focused monitor, then the first one,
    // keeps multi-monitor users from having to chase the fox across the
    // desk after every restart.
    var idx = 0
    var cursor = cursorAbsolute()
    if (cursor) {
      var at = screenAt(cursor.x, cursor.y)
      if (at) idx = at.index
    }
    if (idx >= Quickshell.screens.length) idx = 0
    currentScreenIndex = idx
    var g = screenGeometry(currentScreen())
    positionX = Math.round(g.width / 2 - (cellWidth * scale) / 2)
    recomputeGround()
    positionY = groundY
    velocityX = 0
    velocityY = 0
    isJumping = false
  }

  function cursorAbsolute() {
    if (typeof Hyprland === "undefined" || !Hyprland.cursorPos) return null
    var p = Hyprland.cursorPos
    return { x: Number(p.x || 0), y: Number(p.y || 0) }
  }

  // ---------------------------------------------------- timers
  Timer {
    id: actionTimer
    interval: 2000
    repeat: false
    onTriggered: service.pickNextAction()
  }

  // Pointer-glance timer. When the user hovers the fox with followCursor
  // enabled, the fox faces the cursor for a short moment then returns to
  // whatever the AI is doing.
  Timer {
    id: pointerGlanceTimer
    interval: 1200
    repeat: false
    onTriggered: {
      service.pointerNear = false
      if (service.petState === service.stateWalk) {
        service.direction = service.velocityX >= 0 ? 1 : -1
      }
    }
  }

  // Frame advance. Recreated on each state change because the interval
  // differs per pose (sleep is slow, walk is fast).
  Timer {
    id: animTimer
    repeat: true
    onTriggered: {
      var spec = service.rows[service.petState] || service.rows[service.stateIdle]
      service.frameIndex = (service.frameIndex + 1) % spec.frames
    }
    function cadenceFor() {
      var spec = service.rows[service.petState] || service.rows[service.stateIdle]
      return Math.max(60, Math.round(1000 / spec.fps))
    }
  }

  // Physics + AI tick at ~60Hz. Movement is small enough per step that
  // the fox never tunnels through the floor even at the highest gravity
  // impulse. Disabled while the user is dragging the fox around.
  Timer {
    id: physicsTimer
    interval: 16
    repeat: true
    running: service.enabled && service.physicsEnabled && !service.isDragging
    onTriggered: {
      var g = service.screenGeometry(service.currentScreen())
      var scaledHeight = service.cellHeight * service.scale
      var ground = Math.round(g.height - scaledHeight - service.groundMargin)

      // Gravity applies when above the ground; landing softens the
      // vertical velocity. isJumping stays true until the fox has come
      // to rest on the ground, then the AI picks the next action.
      if (service.positionY < ground) {
        service.velocityY += service.gravity
      } else if (service.velocityY > 0) {
        if (service.velocityY > 2.5) {
          service.velocityY = -service.velocityY * service.bounce
          service.positionY = ground
        } else {
          service.velocityY = 0
          service.positionY = ground
          if (service.isJumping) {
            service.isJumping = false
            service.pickNextAction()
          }
        }
      }

      service.positionX += service.velocityX
      service.positionY += service.velocityY

      // Wall bounce reverses the fox's direction. We also re-orient the
      // facing so the sprite flips. Use a soft edge margin so the fox
      // doesn't bounce off the screen the instant it touches the wall.
      var scaledWidth = service.cellWidth * service.scale
      if (service.positionX <= service.edgeMargin) {
        service.positionX = service.edgeMargin
        service.direction = 1
        service.velocityX = service.walkSpeed
      } else if (service.positionX >= g.width - scaledWidth - service.edgeMargin) {
        service.positionX = Math.max(service.edgeMargin, g.width - scaledWidth - service.edgeMargin)
        service.direction = -1
        service.velocityX = -service.walkSpeed
      }

      // Keep velocityY sane; very tall screens shouldn't accumulate.
      if (service.velocityY > 18) service.velocityY = 18

      // Cross-screen detection. Runs after the position update so a drag
      // or walk that crosses a monitor edge updates currentScreenIndex
      // and rescales positionX / positionY into the new screen's frame.
      if (service._resyncSuppress === 0) service.resyncScreen()
    }
  }

  // React to the cursor being near the fox.
  // Glances toward the cursor briefly if followCursor is on.
  onPointerNearChanged: {
    if (!pointerNear || !followCursor || !enabled) return
    if (isJumping || isDragging) return
    // Only glance in stationary poses so the fox never turns opposite its walk velocity
    if (petState === stateIdle || petState === stateSitRight || petState === stateSitLeft) {
      if (pointerGlanceDirection === 1 || pointerGlanceDirection === -1) {
        direction = pointerGlanceDirection
      }
      pointerGlanceAt = Date.now()
      pointerGlanceTimer.restart()
    }
  }

  // Recompute ground on every change of scale or screen set. The same
  // signal handlers also kick the persistence debounce so a settings
  // change survives a restart.
  onScaleChanged: {
    recomputeGround()
    if (service.enabled) saveDebounce.restart()
  }
  onCellHeightChanged: recomputeGround()
  onCurrentScreenIndexChanged: {
    recomputeGround()
    saveDebounce.restart()
  }

  // Watch the screen set so a freshly plugged-in monitor updates the
  // geometry of an existing screen, and a removed one falls back to the
  // closest match. The first-party plugins use a polling Timer rather
  // than signal hooks (Quickshell.screens has no change signal), so we
  // do the same — a 2s heartbeat catches monitor hot-plugs without the
  // cost of a per-frame walk.
  property int _screenSetRevision: 0
  property int _lastScreenCount: -1
  Timer {
    id: screenWatcher
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      var n = Quickshell.screens.length
      if (n === service._lastScreenCount) return
      service._lastScreenCount = n
      service._screenSetRevision++
      if (service.currentScreenIndex >= n) service.currentScreenIndex = 0
      service.recomputeGround()
      service.resyncScreen()
    }
  }

  // ---------------------------------------------------- external API
  //
  // These are what the bar widget and IPC callers (other plugins, key
  // bindings) hit. They intentionally return strings — see IPC handlers
  // below — so `omarchy-shell fox-pet state` works from a terminal.

  function enable() {
    enabled = true
    animTimer.interval = animTimer.cadenceFor()
    animTimer.restart()
    // Kick off the first AI decision immediately if nothing is pending.
    if (!actionTimer.running) pickNextAction()
    saveState()
  }

  function disable() {
    enabled = false
    animTimer.stop()
    actionTimer.stop()
    pointerGlanceTimer.stop()
    velocityX = 0
    velocityY = 0
    isJumping = false
    pointerNear = false
    // Force a final flush so the next launch lands where the user left it.
    saveState()
  }

  function toggle() {
    if (enabled) disable()
    else enable()
    return enabled ? "on" : "off"
  }

  function poke() {
    manualSleep = false
    // User clicked the fox. The fox acknowledges with a greet pose —
    // unless it's airborne (where a small extra hop is friendlier than
    // interrupting the jump), or asleep (where a yawn fits better
    // than a forced greeting).
    if (isJumping) {
      velocityY = Math.min(velocityY, jumpImpulse * 0.7)
      return
    }
    if (petState === stateSleep) {
      startAction(stateYawn, durationFor(stateYawn))
      return
    }
    if (petState === stateSomersault) {
      // A click during a somersault just bumps the timer so the pose
      // holds a bit longer instead of jumping to greet.
      actionTimer.restart()
      return
    }
    greetChainLeft = 1
    startAction(stateGreet, 1200)
  }

  // Called by the panel's MouseArea on press.
  function cancelSleep() {
    if (manualSleep) manualSleep = false
  }

  function sleepNow() {
    // Explicit manual sleep: persists until the user pokes or wakes the fox.
    if (Math.abs(positionY - groundY) > 8) return
    manualSleep = true
    startAction(stateSleep, 0)
    saveDebounce.restart()
  }

  // Toggle between sleeping and waking. Used by the bar widget's
  // middle-click and the panel's middle-click handler.
  function sleepToggle() {
    if (!enabled) return
    if (petState === stateSleep) {
      manualSleep = false
      poke()
    } else {
      sleepNow()
    }
  }

  function snapshotState() {
    return {
      enabled: enabled,
      positionX: positionX,
      positionY: positionY,
      direction: direction,
      currentScreenIndex: currentScreenIndex,
      scale: scale,
      physicsEnabled: physicsEnabled,
      showShadow: showShadow,
      followCursor: followCursor
    }
  }

  function applySettings(values) {
    if (!values || typeof values !== "object") return
    if (typeof values.scale === "number" && isFinite(values.scale)
        && values.scale >= 0.5 && values.scale <= 2.0) scale = values.scale
    if (typeof values.physicsEnabled === "boolean") physicsEnabled = values.physicsEnabled
    if (typeof values.showShadow === "boolean") showShadow = values.showShadow
    if (typeof values.followCursor === "boolean") followCursor = values.followCursor
  }

  // ---------------------------------------------------- persistence
  //
  // The fox's last position survives shell restarts so it doesn't
  // teleport to the origin every login. Settings live under
  // ~/.local/state/omarchy/fox-pet/state.json (XDG_STATE_HOME).
  function loadState() {
    var raw = stateFile.text() || ""
    if (!raw.trim()) {
      // First launch: pick a reasonable default spot in the lower third
      // of the focused / primary screen.
      recomputeGround()
      positionY = groundY
      var g0 = screenGeometry(currentScreen())
      positionX = Math.round(g0.width / 3)
      return
    }
    try {
      var data = JSON.parse(raw)
      if (typeof data.positionX === "number") positionX = data.positionX
      if (typeof data.positionY === "number") positionY = data.positionY
      if (data.direction === 1 || data.direction === -1) direction = data.direction
      if (typeof data.currentScreenIndex === "number"
          && data.currentScreenIndex >= 0
          && data.currentScreenIndex < Quickshell.screens.length) {
        currentScreenIndex = data.currentScreenIndex
      }
      applySettings(data)
      recomputeGround()
      // If the persisted position is above the ground (e.g. mid-jump from
      // a kill), settle it onto the ground so the first frame isn't the
      // fox falling out of the sky.
      if (positionY > groundY) positionY = groundY
    } catch (e) {
      console.warn("fox-pet: state file unreadable, starting fresh:", e)
    }
  }

  function saveState() {
    if (!stateDirCreated) return
    // Don't start a second write while one is in flight — Quickshell's
    // Process doesn't queue commands, so re-running it would orphan the
    // first payload.
    if (saveStateProc.running) {
      saveDebounce.restart()
      return
    }
    var payload = JSON.stringify({
      positionX: Math.round(positionX),
      positionY: Math.round(positionY),
      direction: direction,
      currentScreenIndex: currentScreenIndex,
      scale: scale,
      physicsEnabled: physicsEnabled,
      showShadow: showShadow,
      followCursor: followCursor
    })
    // Write state payload directly into the state file.
    saveStateProc.command = ["bash", "-c",
      "printf '%s' \"$0\" > \"$1\"",
      payload, service.statePath]
    saveStateProc.running = true
  }

  Process {
    id: saveStateProc
    running: false
    onExited: function(code) {
      if (code !== 0) console.warn("fox-pet: failed to persist state (exit " + code + ")")
    }
  }

  // Debounced persistence timer. Fired on discrete transitions (stops, drops,
  // sleep, toggles, settings changes) rather than on every walking step.
  Timer {
    id: saveDebounce
    interval: 600
    repeat: false
    onTriggered: service.saveState()
  }
  onPhysicsEnabledChanged: if (service.enabled) saveDebounce.restart()
  onShowShadowChanged: if (service.enabled) saveDebounce.restart()
  onFollowCursorChanged: if (service.enabled) saveDebounce.restart()

  // Make sure ~/.local/state/omarchy/fox-pet/ exists before the FileView
  // tries to write into it. Created once.
  property bool stateDirCreated: false
  property bool petMetaLoaded: false
  Process {
    id: mkdirProc
    command: ["bash", "-c", "mkdir -p \"$0\"", service.stateDir]
    onExited: function(code) {
      service.stateDirCreated = code === 0
      if (service.stateDirCreated) {
        service.loadState()
      }
    }
  }

  // pet.json carries sprite metadata + pet identity. Read once at startup;
  // the panel binds to the parsed fields. A missing file leaves the stock
  // defaults in place — the plugin never fails on missing metadata.
  FileView {
    id: petMetaLoader
    path: service.petMetaPath
    printErrors: false
    onLoaded: service.applyPetMeta(text())
    onLoadFailed: { /* keep defaults */ }
  }

  function applyPetMeta(raw) {
    if (!raw) return
    try {
      var data = JSON.parse(raw)
      if (typeof data.displayName === "string" && data.displayName.length > 0)
        petDisplayName = data.displayName
      if (typeof data.description === "string")
        petDescription = data.description
      if (typeof data.spriteVersionNumber === "number")
        spriteVersionNumber = data.spriteVersionNumber
      if (typeof data.spritesheetPath === "string" && data.spritesheetPath.length > 0)
        spriteUrl = Qt.resolvedUrl("assets/" + data.spritesheetPath)
      var sprite = data.sprite
      if (sprite && typeof sprite === "object") {
        if (typeof sprite.columns === "number" && sprite.columns > 0) columns = sprite.columns
        if (typeof sprite.cellWidth === "number" && sprite.cellWidth > 0) cellWidth = sprite.cellWidth
        if (typeof sprite.cellHeight === "number" && sprite.cellHeight > 0) cellHeight = sprite.cellHeight
        if (typeof sprite.rowCount === "number" && sprite.rowCount > 0) rowCount = sprite.rowCount
        if (sprite.rows && typeof sprite.rows === "object") {
          // Merge: keep any state the json doesn't override so a partial
          // pet.json (one new sprite row) doesn't drop the rest.
          var merged = {}
          for (var k in defaultRows) merged[k] = defaultRows[k]
          for (var sk in sprite.rows) {
            if (sprite.rows[sk] && typeof sprite.rows[sk] === "object") merged[sk] = sprite.rows[sk]
          }
          rows = merged
        }
      }
      petMetaLoaded = true
      animTimer.interval = animTimer.cadenceFor()
    } catch (e) {
      console.warn("fox-pet: pet.json unreadable, using defaults:", e)
    }
  }

  FileView {
    id: stateFile
    path: service.statePath
    printErrors: false
    onLoaded: service.loadState()
    onLoadFailed: {
      // No prior state — compute defaults from loadState().
      service.loadState()
    }
  }

  // AnimTimer interval has to track the current state's fps, so the
  // service rebinds it on every state change.
  onPetStateChanged: animTimer.interval = animTimer.cadenceFor()

  // ---------------------------------------------------- IPC
  //
  // All IPC for the plugin lives here. The bar widget does not register
  // its own IpcHandler — having two on the same target would have
  // Quickshell's "first match wins" resolver shadow service-level methods
  // on the duplicate names and silently drop the rest. The service is
  // loaded for the lifetime of the plugin (keepLoaded: true), so its
  // handler is always available.
  IpcHandler {
    target: "fox-pet"

    function state(): string {
      return service.enabled
        ? ("on:" + service.petState + ":" + service.direction + ":" + service.frameIndex)
        : "off"
    }

    function info(): string {
      return JSON.stringify(service.snapshotState())
    }

    function enable(): string { service.enable(); return "on" }
    function disable(): string { service.disable(); return "off" }
    function toggle(): string { return service.toggle() }
    function poke(): string { service.poke(); return "ok" }
    function sleep(): string { service.sleepNow(); return "ok" }
    function sleepToggle(): string { service.sleepToggle(); return "ok" }
    function reset(): string { service.resetPosition(); return "ok" }
    function jump(): string { service.jump(); return "ok" }
    function somersault(): string { service.somersault(); return "ok" }
    function spin(): string { service.spin(); return "ok" }
    function position(): string {
      return Math.round(service.positionX) + "," + Math.round(service.positionY)
    }
    function name(): string {
      return service.petDisplayName
    }
  }

  Component.onCompleted: mkdirProc.running = true

  // Stop every timer and kill any in-flight process so a hot reload
  // (a plugin edit) or a teardown doesn't leak them across rebuilds.
  Component.onDestruction: {
    animTimer.stop()
    physicsTimer.stop()
    actionTimer.stop()
    pointerGlanceTimer.stop()
    saveDebounce.stop()
    if (saveStateProc.running) saveStateProc.running = false
    if (mkdirProc.running) mkdirProc.running = false
  }
}

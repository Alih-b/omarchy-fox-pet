import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Fox Pet toggle. A single button in the bar that flips the desktop fox
// on or off. The button stays visible even when the pet is hidden so
// the user always has a way to summon it back; right-click is reserved
// for "send the fox back to its starting spot" because that action
// matters when the fox wanders into a corner.
BarWidget {
  id: root
  moduleName: "fox-pet"

  // The service may not be mounted yet on first render (the shell
  // resolves plugins in declaration order). Fall back to the inline
  // setting so the widget stays interactive during the gap.
  readonly property var serviceRef: {
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    return shell && typeof shell.serviceFor === "function"
      ? shell.serviceFor("fox-pet")
      : null
  }
  readonly property bool petEnabled: serviceRef
    ? serviceRef.enabled
    : setting("enabled", false)

  // Pull the pet's display name out of the loaded pet.json so the tooltip
  // matches what's actually rendered. Falls back to a generic label while
  // the metadata file is still loading.
  readonly property string petDisplayName: serviceRef && serviceRef.petDisplayName
    ? serviceRef.petDisplayName
    : "Fox Pet"

  // ---------------------------------------------------------- settings sync
  //
  // Settings the user changes from the bar (toggling the fox, adjusting
  // size, etc.) have to be written back into shell.json so the next shell
  // restart starts with the same values. The pattern is the same one the
  // first-party clock widget uses (see panels/clock/BarWidget.qml): build
  // a fresh entry from the widget's current `settings`, optimistically
  // apply it to the local property, then ask the shell to persist the
  // merged record. The bar's onSettingsChanged rebinds us if the write
  // round-trips through, but the local-first apply means the click is
  // instantaneous regardless.
  function persistEntry(values) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var k in values) entry[k] = values[k]
    root.settings = entry
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(root.moduleName, entry)
    return entry
  }

  function handleClick() {
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    if (!shell) return

    // Persist the user's preference into shell.json so the next launch
    // starts with the same on/off state.
    var entry = persistEntry({ enabled: !petEnabled })

    if (serviceRef) {
      if (entry.enabled) serviceRef.enable()
      else serviceRef.disable()
    }

    // Reflect the on/off change in the visible panel.
    if (entry.enabled) {
      if (typeof shell.summon === "function") shell.summon(root.moduleName, "{}")
    } else {
      if (typeof shell.hide === "function") shell.hide(root.moduleName)
    }
  }

  function resetPosition() {
    if (serviceRef) serviceRef.resetPosition()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "🦊"
    fontSize: Style.font.iconLarge
    tooltipText: root.petEnabled
      ? root.petDisplayName + " — click to hide, right-click to reset position, middle-click to sleep"
      : root.petDisplayName + " — click to summon"
    active: root.petEnabled
    dimmed: !root.petEnabled

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.resetPosition()
        return
      }
      if (b === Qt.MiddleButton) {
        if (serviceRef) serviceRef.sleepToggle()
        return
      }
      if (b === Qt.LeftButton) root.handleClick()
    }
  }

  // Keep the button visible even when disabled so the user can re-enable
  // the pet without hunting through menus.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Mirror setting changes that come back through the bar host (e.g. when
  // the user toggles via IPC from elsewhere). The widget's local
  // `settings` is reactive — this is a no-op safety net for cold starts
  // and IPC round-trips.
  function syncSettings() {
    if (!serviceRef) return
    var wantEnabled = setting("enabled", false)
    if (serviceRef.enabled !== wantEnabled) {
      if (wantEnabled) serviceRef.enable()
      else serviceRef.disable()
    }
    var scaleValue = setting("scale", 1.0)
    if (typeof scaleValue === "number" && scaleValue !== serviceRef.scale)
      serviceRef.scale = scaleValue
    var physicsValue = setting("physicsEnabled", true)
    if (typeof physicsValue === "boolean" && physicsValue !== serviceRef.physicsEnabled)
      serviceRef.physicsEnabled = physicsValue
    var shadowValue = setting("showShadow", true)
    if (typeof shadowValue === "boolean" && shadowValue !== serviceRef.showShadow)
      serviceRef.showShadow = shadowValue
    var followValue = setting("followCursor", true)
    if (typeof followValue === "boolean" && followValue !== serviceRef.followCursor)
      serviceRef.followCursor = followValue
  }

  onSettingsChanged: syncSettings()
  onServiceRefChanged: {
    // A rescan replaces the service after this widget's settings have
    // already arrived. Apply them to the new instance and restore visibility.
    syncSettings()
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    if (serviceRef && setting("enabled", false) && shell && typeof shell.summon === "function")
      shell.summon(root.moduleName, "{}")
  }

  // ---------------------------------------------------------- IPC
  //
  // All IPC for the plugin lives on the Service (target: "fox-pet").
  // Quickshell resolves calls against the first registered IpcHandler
  // for a target — registering a second one here would shadow the
  // Service's methods on shared names and silently drop the rest. The
  // Service is loaded for the lifetime of the plugin (keepLoaded: true),
  // so its handler is always available.
}

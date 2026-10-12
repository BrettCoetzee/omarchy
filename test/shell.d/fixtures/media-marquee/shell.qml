import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: root

  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  property var failures: []
  property int checks: 0
  property var widget: null
  property var label: null
  property var steps: []
  property real lastX: 0

  Item {
    id: host
    width: 400
    height: 40

    // Hidden and shown again like a bar slot. A parentless item can't be
    // shown again, so the toggle lives one level down.
    Item {
      id: slot
      anchors.fill: parent
    }
  }

  QtObject {
    id: player
    property string trackTitle: ""
    property string trackArtist: ""
    property string trackArtUrl: ""
    property bool isPlaying: false
    property string trackAlbum: ""
    property bool canGoPrevious: true
    property bool canGoNext: true
    property bool canTogglePlaying: true
    property bool canPlay: true
    property bool canPause: true
  }

  QtObject {
    id: mediaService
    property var activePlayer: player
    property var sourcePlayers: [player]
    function runAction() {}
    function playerKey(p) { return p ? "fixture" : "" }
    function selectPlayer() {}
  }

  QtObject {
    id: fakeShell
    function firstPartyServiceFor(id) { return id === "omarchy.media" ? mediaService : null }
  }

  QtObject {
    id: fakeBar
    property var shell: fakeShell
    property bool vertical: false
    property bool barHidden: false
    property int barSize: 26
    property string position: "top"
    property color barForeground: "white"
    property color foreground: "white"
    property string fontFamily: "monospace"
    property bool foregroundAnimationEnabled: false
    property var activePopout: null
    function showTooltip() {}
    function hideTooltip() {}
    function requestPopout() {}
    function releasePopout() {}
  }

  function check(condition, message) {
    checks += 1
    if (!condition) failures.push(message)
  }

  function findLabel(item) {
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].text !== undefined && String(kids[i].text).indexOf(player.trackTitle) === 0) return kids[i]
      var found = findLabel(kids[i])
      if (found) return found
    }
    return null
  }

  // The marquee moves the title's x every frame while it runs.
  function moving() {
    var moved = label.x !== lastX
    lastX = label.x
    return moved
  }

  function finish() {
    if (widget) widget.destroy()
    var payload = JSON.stringify({ ok: failures.length === 0, checks: checks, failures: failures })
    var quoted = "'" + payload.replace(/'/g, "'\\''") + "'"
    Quickshell.execDetached(["bash", "-c", "printf '%s' " + quoted + " > \"$1\"", "_", resultPath])
  }

  function next() {
    if (steps.length === 0) {
      finish()
      return
    }
    var step = steps.shift()
    stepTimer.action = step[1]
    stepTimer.interval = step[0]
    stepTimer.restart()
  }

  Timer {
    id: stepTimer
    property var action: null
    repeat: false
    onTriggered: {
      try {
        action()
        root.next()
      } catch (error) {
        root.failures.push(String(error))
        root.finish()
      }
    }
  }

  function start() {
    var component = Qt.createComponent("file://" + rootPath + "/shell/plugins/services/media/BarWidget.qml", Component.PreferSynchronous)
    if (component.status !== Component.Ready) throw new Error(component.errorString())
    widget = component.createObject(slot, { bar: fakeBar, moduleName: "omarchy.media" })
    if (!widget) throw new Error(component.errorString())
    steps = [
      // A paused track's metadata arrives, as it does from MPRIS.
      [300, function() {
        player.trackTitle = "A track title long enough that it can never fit in the bar at once"
        player.trackArtist = "An artist with a name that also takes room"
      }],
      [1000, function() {
        check(!Style.reduceMotion, "the fixture runs with animations on")
      }],
      [1000, function() {
        label = findLabel(widget)
        if (!label) throw new Error("Missing media title label")
        moving()
      }],
      [300, function() {
        check(!moving() && label.x === 0, "a paused title reads still from its start")
        player.isPlaying = true
      }],
      [300, function() { moving() }],
      [300, function() {
        check(moving(), "a playing title that overflows scrolls")
        player.isPlaying = false
      }],
      [100, function() {
        check(label.x === 0, "a paused title reads from its start")
        moving()
      }],
      [400, function() {
        check(!moving(), "a paused title stays still")
        player.isPlaying = true
      }],
      [300, function() {
        check(moving(), "resuming playback scrolls again")
        fakeBar.barHidden = true
      }],
      [100, function() { moving() }],
      [400, function() {
        check(!moving() && label.x === 0, "a hidden bar stops the scroll")
        fakeBar.barHidden = false
      }],
      [300, function() {
        check(moving(), "showing the bar scrolls again")
        slot.visible = false
      }],
      [100, function() { moving() }],
      [400, function() {
        check(!moving(), "a widget that is not shown stops the scroll")
        slot.visible = true
      }],
      [300, function() { moving() }],
      [300, function() {
        check(moving(), "showing the widget scrolls again")
        Style.reduceMotion = true
      }],
      [100, function() { moving() }],
      [400, function() {
        check(!moving() && label.x === 0, "reduced motion stops the scroll at the title's start")
      }]
    ]
    next()
  }

  Timer {
    interval: 1
    running: true
    onTriggered: {
      try {
        root.start()
      } catch (error) {
        root.failures.push(String(error))
        root.finish()
      }
    }
  }
}

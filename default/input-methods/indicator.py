"""Live Fcitx state for the existing keyboard layout widget."""

from collections import Counter
import json
import os
import re
import subprocess
import sys

from gi.repository import Gio, GLib


BUS = "org.fcitx.Fcitx5"
INTERFACE = "org.fcitx.Fcitx.Controller1"


def call(bus, method, args=None):
  # Reading the bar must neither activate a stopped service nor wait indefinitely.
  return bus.call_sync(BUS, "/controller", INTERFACE, method, args, None,
                       Gio.DBusCallFlags.NO_AUTO_START, 1000, None).unpack()


def snapshot(bus):
  group = call(bus, "CurrentInputMethodGroup")[0]
  methods = list(dict.fromkeys(item[0] for item in
                              call(bus, "InputMethodGroupInfo", GLib.Variant("(s)", (group,)))[1]))
  info = call(bus, "CurrentInputMethodInfo")
  return {"methods": methods, "current": info[0], "name": info[1], "label": info[4], "language": info[5]}


def layout_keyboard(keyboards):
  typed = [keyboard for keyboard in keyboards if not re.match(
    r"^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)", keyboard.get("name", ""))]
  typed = [item for item in typed if len(item.get("layout", "").split(",")) > 1]
  if not typed:
    return None
  # Consumer controls also carry the seat layout. Its frequency keeps an
  # individually configured keyboard from taking over the desktop shortcut.
  counts = Counter(item.get("layout", "") for item in keyboards)
  layout = max((item["layout"] for item in typed), key=lambda layout: counts[layout])
  keyboard = max((item for item in typed if item["layout"] == layout),
                 key=lambda item: item.get("active_layout_index", 0))
  return keyboard


def layout_switches(keyboards, index=None, step=1):
  keyboard = layout_keyboard(keyboards)
  if keyboard is None:
    return []
  layout = keyboard["layout"]
  following = index if index is not None else (keyboard.get("active_layout_index", 0) + step) % len(layout.split(","))
  return [["hyprctl", "switchxkblayout", item["name"], str(following)]
          for item in keyboards if item.get("layout") == layout and item.get("name")]


def cycle_choice(state, keyboards, step=1):
  methods = state.get("methods", [])
  keyboard = layout_keyboard(keyboards)
  primary = next((method for method in methods if method.startswith("keyboard-")), None)
  if keyboard is None or primary is None:
    current = state.get("current")
    if len(methods) > 1 and current in methods:
      return methods[(methods.index(current) + step) % len(methods)], None
    return None, None
  # One direct-input method represents all compositor layouts. Composition
  # engines follow them in the user's configured order.
  choices = []
  for method in methods:
    if method == primary:
      choices.extend((method, index) for index in range(len(keyboard["layout"].split(","))))
    else:
      choices.append((method, None))
  current = state.get("current") or primary
  position = (current, keyboard.get("active_layout_index", 0) if current == primary else None)
  if position not in choices:
    return None, None
  return choices[(choices.index(position) + step) % len(choices)]


class Indicator:
  def __init__(self, bus):
    self.bus = bus
    self.pending = ""
    self.last = ""
    self.entries = {}

  def select_next(self, step=1):
    devices = subprocess.run(["hyprctl", "-j", "devices"], check=True, text=True, capture_output=True)
    keyboards = json.loads(devices.stdout).get("keyboards", [])
    try:
      state = snapshot(self.bus)
    except GLib.Error:
      # Without Fcitx, Super+I still cycles the compositor layouts.
      for command in layout_switches(keyboards, step=step):
        subprocess.run(command, check=True, capture_output=True)
      return
    methods = state["methods"]
    current = self.pending or state["current"] or self.last
    state["current"] = current if current in methods else next(iter(methods), "")
    following, index = cycle_choice(state, keyboards, step)
    if following is None:
      return
    self.pending = following
    for command in layout_switches(keyboards, index) if index is not None else []:
      subprocess.run(command, check=True, capture_output=True)
    self.refresh()

  def refresh(self):
    state = snapshot(self.bus)
    methods = state["methods"]
    if self.pending not in methods:
      self.pending = ""
    if self.pending and state["current"]:
      # Before the first application gains focus Fcitx has no input context.
      # Retain the click until it has one, without changing startup defaults.
      call(self.bus, "SetCurrentIM", GLib.Variant("(s)", (self.pending,)))
      state = snapshot(self.bus)
      if state["current"] == self.pending:
        self.pending = ""
    if state["current"]:
      self.last = state["current"]
    else:
      chosen = self.pending or (self.last if self.last in methods else "") or next(iter(methods), "")
      if chosen not in self.entries:
        self.entries = {entry[0]: entry for entry in call(self.bus, "AvailableInputMethods")[0]}
      entry = self.entries.get(chosen)
      if entry:
        state.update(current=entry[0], name=entry[1], label=entry[4], language=entry[5])
    return state

  def switchable(self, methods):
    # With one keyboard method in one group the reading cannot change until the
    # configuration does, and Fcitx saves that to the profile being watched. A
    # lone composition engine still toggles, and steps aside in password fields.
    if len(methods) > 1 or not all(method.startswith("keyboard-") for method in methods):
      return True
    return len(call(self.bus, "InputMethodGroups")[0]) > 1


def owner_environment(bus):
  """The environment and working directory of the process that owns Fcitx's bus name.

  The profile is wherever that process saves it, which a service drop-in can
  move without the shell's own environment knowing.
  """
  try:
    pid = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                        "GetConnectionUnixProcessID", GLib.Variant("(s)", (BUS,)), None,
                        Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
    with open(f"/proc/{pid}/environ", "rb") as file:
      items = file.read().decode(errors="replace").split("\0")
    environment = dict(item.split("=", 1) for item in items if "=" in item)
    return environment, os.readlink(f"/proc/{pid}/cwd")
  except (GLib.Error, OSError, ValueError):
    return None


def profile_path(owner=None):
  # Fcitx's own lookup: FCITX_CONFIG_HOME, else $XDG_CONFIG_HOME/fcitx5, cleaned
  # lexically the way Fcitx cleans it before any link is followed. A relative
  # path is relative to the working directory.
  environment, cwd = owner or (os.environ, os.getcwd())
  home = environment.get("HOME") or os.path.expanduser("~")
  if environment.get("FCITX_CONFIG_HOME"):
    directory = os.path.join(cwd, environment["FCITX_CONFIG_HOME"])
  else:
    # A relative XDG_CONFIG_HOME is relative to the home directory.
    directory = os.path.join(home, environment.get("XDG_CONFIG_HOME") or ".config", "fcitx5")
  return os.path.join(os.path.normpath(directory), "profile")


def watched_entries(owner=None, hops=40):
  # Saves rename a new profile into place, and a dotfile manager may link the
  # profile, its directory or the configuration home elsewhere, chain links, or
  # replace a linked directory. Resolve the path the way the kernel does, one
  # component at a time, and watch each directory it passes through for the one
  # entry it looks up there when that entry is a link, is missing, or is the
  # profile or its directory.
  home = os.path.realpath((owner[0] if owner else os.environ).get("HOME") or os.path.expanduser("~"))
  entries = []
  current, pending = "/", profile_path(owner).split("/")
  while pending:
    part = pending.pop(0)
    if part in ("", "."):
      continue
    if part == "..":
      current = os.path.dirname(current)
      continue
    candidate = os.path.join(current, part)
    try:
      target = os.readlink(candidate) if hops > 0 else None
    except OSError:
      target = None
    # The way down to the home directory changes with a new session, not a
    # save, and so does a real directory above the profile's own: watching the
    # busy home directory for those would wake on every file written there.
    toward_home = candidate == home or home.startswith(candidate + "/")
    remaining = [item for item in pending if item not in ("", ".")]
    settled = target is None and os.path.isdir(candidate) and len(remaining) > 1
    if not toward_home and not settled:
      entries.append((current, part))
    if target is not None:
      hops -= 1
      if target.startswith("/"):
        current = "/"
      pending = target.split("/") + pending
    elif os.path.lexists(candidate):
      current = candidate
    else:
      # Nothing further exists yet; the watch on this entry sees it arrive.
      break
  return list(dict.fromkeys(entries))


class ProfileWatch:
  """Calls changed() whenever the profile Fcitx saves its configuration to changes."""

  def __init__(self, changed):
    self.changed = changed
    self.monitors = []
    self.owner = None
    self.bind()

  def bind(self):
    # Resolve before dropping the old watches, so a failure keeps them, and
    # again once the new ones are armed, in case the path changed in between.
    entries = watched_entries(self.owner)
    for _ in range(10):
      for monitor in self.monitors:
        monitor.cancel()
      self.monitors = []
      for directory, name in entries:
        monitor = Gio.File.new_for_path(directory).monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
        monitor.connect("changed", self.entry_changed, directory, name)
        self.monitors.append(monitor)
      armed, entries = entries, watched_entries(self.owner)
      if entries == armed:
        return
    # Still moving: whoever is changing it will send another event.

  def entry_changed(self, monitor, file, other, event, directory, name):
    # The watched directory itself moving away (a real ~/.config moved aside
    # for a link, say) arrives as an event on the directory, not the entry.
    moved = file.get_path() == directory
    if not moved and name not in (file.get_basename(), other.get_basename() if other else None):
      return
    # A relinked or replaced entry may resolve somewhere new.
    self.bind()
    self.changed()


def follow(bus, changed, presence):
  # Fcitx sends no signal when its configuration or current method changes
  # (Controller1's InputMethodGroupsChanged stays silent for group edits and
  # switches alike), so follow the service's bus name for restarts and the
  # profile it saves every configuration change to.
  profile = ProfileWatch(changed)

  def owner(present):
    presence(present)
    if present:
      profile.owner = owner_environment(bus)
      profile.bind()
    changed()
  name = Gio.bus_watch_name_on_connection(bus, BUS, Gio.BusNameWatcherFlags.NONE,
                                          lambda *_: owner(True), lambda *_: owner(False))
  return [name, profile]


def watch(bus):
  previous = None
  indicator = Indicator(bus)
  loop = GLib.MainLoop()
  buffer = ""
  timer = 0
  settle = 0
  polling = False
  failed = False
  present = True

  def refresh():
    nonlocal previous, polling, failed
    try:
      state = indicator.refresh()
      polling = indicator.switchable(state["methods"])
      failed = False
    except GLib.Error:
      failed = True
      indicator.pending = ""
      indicator.last = ""
      # Keep the configured cadence: a timed-out call is not a configuration
      # change, and a vanished service is followed by its bus name.
      state = {"methods": [], "current": "", "name": "", "language": ""}
    line = json.dumps(state, ensure_ascii=False)
    if line != previous:
      print(line, flush=True)
      previous = line

  # Only a pending click or a group with methods to switch between needs
  # reading again on a timer; everything else waits for an event. A failed
  # read of a running service is retried, since nothing else would correct it.
  def schedule():
    nonlocal timer
    if timer:
      GLib.source_remove(timer)
      timer = 0
    if indicator.pending:
      timer = GLib.timeout_add(50, poll)
    elif polling:
      timer = GLib.timeout_add(500, poll)
    elif failed and present:
      timer = GLib.timeout_add(2000, poll)

  def poll():
    nonlocal timer
    timer = 0
    refresh()
    schedule()
    return GLib.SOURCE_REMOVE

  # A save arrives as several file events, and a restarting service as a
  # vanish and an appear; read once they settle.
  def changed():
    nonlocal settle
    if settle:
      GLib.source_remove(settle)
    settle = GLib.timeout_add(200, settled)

  def settled():
    nonlocal settle
    settle = 0
    refresh()
    schedule()
    return GLib.SOURCE_REMOVE

  def presence(running):
    nonlocal present
    present = running

  def command(source, condition):
    nonlocal buffer
    data = os.read(sys.stdin.fileno(), 4096)
    if not data:
      loop.quit()
      return GLib.SOURCE_REMOVE
    buffer += data.decode()
    while "\n" in buffer:
      line, buffer = buffer.split("\n", 1)
      if line in ("cycle", "cycle back"):
        try:
          indicator.select_next(-1 if line == "cycle back" else 1)
        except (GLib.Error, OSError, ValueError, subprocess.CalledProcessError):
          indicator.pending = ""
        refresh()
    schedule()
    return GLib.SOURCE_CONTINUE

  # Fcitx's controller has no current-method-changed signal, so a group with
  # more than one method is still read every 500 ms, over one kept-open bus
  # connection. That follows per-application input contexts and trigger keys
  # pressed inside applications.
  GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, command)
  # Held for as long as the loop runs.
  watchers = follow(bus, changed, presence)  # noqa: F841
  poll()
  loop.run()


if __name__ == "__main__":
  try:
    watch(Gio.bus_get_sync(Gio.BusType.SESSION, None))
  except (GLib.Error, OSError, ValueError, subprocess.CalledProcessError) as error:
    raise SystemExit(str(error))

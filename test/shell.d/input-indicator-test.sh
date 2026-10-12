#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

OMARCHY_PATH="$ROOT" /usr/bin/python - <<'PY'
import importlib.util
import os
from unittest.mock import patch
import json
import subprocess

# Script-directory imports must not shadow Python's standard typing module.
subprocess.run(["/usr/bin/python", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import typing; from gi.repository import Gio; assert hasattr(typing, 'TYPE_CHECKING')", os.environ["OMARCHY_PATH"] + "/default/input-methods"], check=True)

spec = importlib.util.spec_from_file_location("indicator", os.environ["OMARCHY_PATH"] + "/default/input-methods/indicator.py")
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)

with patch.object(indicator, "call", side_effect=[
  ("Default",),
  ("us", [("keyboard-us", ""), ("mozc", ""), ("mozc", "")]),
  ("mozc", "Mozc", "", "fcitx_mozc", "あ", "ja", "mozc", True, "", {}),
]):
  state = indicator.snapshot(None)
  assert state == {"methods": ["keyboard-us", "mozc"], "current": "mozc", "name": "Mozc", "label": "あ", "language": "ja"}
print("ok - live state deduplicates modes and reads language independently of the engine label")

def check_cycle(current, methods, expected):
  assert indicator.cycle_choice({"current": current, "methods": methods}, [])[0] == expected

check_cycle("keyboard-us", ["keyboard-us", "mozc"], "mozc")
check_cycle("mozc", ["keyboard-us", "mozc"], "keyboard-us")
check_cycle("mozc", ["keyboard-us", "mozc", "hangul"], "hangul")
check_cycle("hangul", ["keyboard-us", "mozc", "hangul"], "keyboard-us")
check_cycle("keyboard-us", ["keyboard-us"], None)
check_cycle("removed", ["keyboard-us", "mozc"], None)
check_cycle("", [], None)
print("ok - input cycling covers Latin, multiple engines, single modes, and stale contexts")

entries = [("keyboard-us", "English", "", "input-keyboard", "en", "en", True),
           ("pinyin", "Pinyin", "", "fcitx-pinyin", "拼", "zh_CN", True)]
live = {"methods": ["keyboard-us", "pinyin"], "current": "", "name": "", "label": "", "language": ""}
selected = []
def fake_call(bus, method, args=None):
  if method == "AvailableInputMethods":
    return (entries,)
  if method == "SetCurrentIM":
    selected.append(args.unpack()[0])
    live["current"] = selected[-1]
    return ()
  raise AssertionError(method)

with patch.object(indicator, "snapshot", side_effect=lambda bus: dict(live)), patch.object(indicator, "call", side_effect=fake_call), patch.object(indicator.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout='{"keyboards": []}')):
  reader = indicator.Indicator(None)
  assert reader.refresh()["current"] == "keyboard-us"
  reader.select_next()
  assert reader.refresh()["current"] == "pinyin"
  assert reader.pending == "pinyin" and selected == []
  reader.select_next()
  assert reader.pending == "keyboard-us"
  reader.select_next()
  live["current"] = "keyboard-us"
  assert reader.refresh()["current"] == "pinyin"
  assert reader.pending == "" and selected == ["pinyin"]
  live["current"] = ""
  reader.select_next()
  live["methods"] = ["pinyin"]
  reader.refresh()
  assert reader.pending == ""
print("ok - desktop clicks update the label, cycle pending choices, and apply once a text context exists")

with patch.object(indicator, "snapshot", return_value={"methods": ["keyboard-us", "keyboard-fr"], "current": "keyboard-us"}), patch.object(indicator, "call") as call, patch.object(indicator.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout='{"keyboards": []}')) as process:
  indicator.Indicator(None).select_next()
  assert call.call_args_list[0].args[2].unpack() == ("keyboard-fr",)
  assert process.call_count == 1
print("ok - the shortcut cycles Fcitx keyboard methods without requiring a bar widget")

keyboards = [
  {"name": "power-button", "layout": "us,fr", "active_layout_index": 1},
  {"name": "physical keyboard", "layout": "us,fr", "active_layout_index": 0},
  {"name": "consumer-control", "layout": "us,fr", "active_layout_index": 0},
  {"name": "custom", "layout": "de", "active_layout_index": 0},
]
expected = [["hyprctl", "switchxkblayout", item["name"], "1"] for item in keyboards[:3]]
assert indicator.layout_switches(keyboards) == expected
assert indicator.layout_switches([keyboards[-1]] + keyboards[:-1]) == expected
assert indicator.layout_switches([{ "name": "custom-first", "layout": "us,de,fr", "active_layout_index": 2 }] + keyboards) == expected
keyboards[1]["active_layout_index"] = 1
assert all(command[-1] == "0" for command in indicator.layout_switches(keyboards))
assert indicator.layout_switches([{ "name": "physical", "layout": "fr" }]) == []
assert indicator.layout_switches([]) == []
print("ok - layout switching synchronizes matching devices, wraps, and preserves device-specific layouts")

import json
def reader_cycle(state, keyboards):
  with patch.object(indicator, "snapshot", return_value=dict(state)), patch.object(indicator, "call") as call, patch.object(indicator.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps({"keyboards": keyboards}))) as process:
    indicator.Indicator(None).select_next()
  return call, [command.args[0] for command in process.call_args_list[1:]]

call, commands = reader_cycle({"methods": ["keyboard-us"], "current": "keyboard-us"}, keyboards)
assert commands == indicator.layout_switches(keyboards)
print("ok - keyboard-only input falls back to compositor layouts")
state = {"methods": ["keyboard-us", "mozc", "hangul"], "current": "keyboard-us"}
keyboards[1]["active_layout_index"] = 0
assert indicator.cycle_choice(state, keyboards) == ("keyboard-us", 1)
call, commands = reader_cycle(state, keyboards)
assert commands and all(command[-1] == "1" for command in commands)
assert all(item.args[2].unpack() == ("keyboard-us",) for item in call.call_args_list if item.args[1] == "SetCurrentIM")
keyboards[1]["active_layout_index"] = 1
assert indicator.cycle_choice(state, keyboards) == ("mozc", None)
state["current"] = "mozc"
assert indicator.cycle_choice(state, keyboards) == ("hangul", None)
state["current"] = "hangul"
assert indicator.cycle_choice(state, keyboards) == ("keyboard-us", 0)
call, commands = reader_cycle(state, keyboards)
assert call.call_args_list[0].args[2].unpack() == ("keyboard-us",)
assert all(command[-1] == "0" for command in commands)
print("ok - layouts and composition engines share one cycle and returning to direct input resets the layout")

keyboards = [{"name": "physical", "layout": "us,dk", "active_layout_index": 0}]
live = {"methods": ["keyboard-us", "pinyin"], "current": "", "name": "", "label": "", "language": ""}
selected.clear()
def fake_process(command, **kwargs):
  if command[:3] == ["hyprctl", "-j", "devices"]:
    return subprocess.CompletedProcess(command, 0, stdout=json.dumps({"keyboards": keyboards}))
  keyboards[0]["active_layout_index"] = int(command[-1])
  return subprocess.CompletedProcess(command, 0, stdout="")
with patch.object(indicator, "snapshot", side_effect=lambda bus: dict(live)), patch.object(indicator, "call", side_effect=fake_call), patch.object(indicator.subprocess, "run", side_effect=fake_process):
  reader = indicator.Indicator(None)
  reader.last = "removed-engine"
  reader.select_next()
  assert keyboards[0]["active_layout_index"] == 1
  reader.select_next()
  assert reader.pending == "pinyin" and selected == []
  assert reader.refresh()["current"] == "pinyin"
  live["current"] = "keyboard-us"
  reader.refresh()
  assert selected == ["pinyin"] and reader.pending == ""
  reader.select_next()
  assert keyboards[0]["active_layout_index"] == 0
  assert selected[-1] == "keyboard-us"
print("ok - mixed-layout bar clicks queue an engine without focus and apply it when a text field gains focus")

from unittest.mock import Mock
callback = {}
def register(source, flags, fn):
  callback["read"] = fn
  return 1
def exercise():
  assert callback["read"](None, None) == indicator.GLib.SOURCE_CONTINUE
  assert callback["read"](None, None) == indicator.GLib.SOURCE_CONTINUE
state = {"methods": ["keyboard-us", "pinyin"], "current": "keyboard-us", "name": "English", "label": "en", "language": "en"}
loop = Mock()
loop.run.side_effect = exercise
with patch.object(indicator.GLib, "MainLoop", return_value=loop), patch.object(indicator.GLib, "io_add_watch", side_effect=register), patch.object(indicator.GLib, "timeout_add", return_value=1), patch.object(indicator.GLib, "source_remove"), patch.object(indicator.os, "read", return_value=b"cycle\n"), patch.object(indicator, "snapshot", return_value=state), patch.object(indicator.subprocess, "run", side_effect=[subprocess.CalledProcessError(1, "hyprctl"), subprocess.CompletedProcess([], 0, stdout='{"keyboards": []}')]), patch.object(indicator, "call") as call, patch.object(indicator, "follow"), patch("builtins.print"):
  indicator.watch(None)
  assert call.call_args.args[1] == "SetCurrentIM"
print("ok - a failed compositor query leaves the bar click reader alive for the next request")

keyboards = [{"name": "physical", "layout": "us,dk", "active_layout_index": 0}]
with patch.object(indicator, "snapshot", side_effect=indicator.GLib.Error("no fcitx")), patch.object(indicator.subprocess, "run", side_effect=fake_process):
  indicator.Indicator(None).select_next()
  assert keyboards[0]["active_layout_index"] == 1
print("ok - the shortcut reader cycles compositor layouts when Fcitx is unavailable")

keyboards = [{"name": "physical", "layout": "us,dk", "active_layout_index": 0}]
state = {"methods": ["keyboard-us", "mozc", "hangul"], "current": "keyboard-us"}
assert indicator.cycle_choice(state, keyboards) == ("keyboard-us", 1)
assert indicator.cycle_choice(state, keyboards, -1) == ("hangul", None)
state["current"] = "mozc"
assert indicator.cycle_choice(state, keyboards, -1) == ("keyboard-us", 1)
assert indicator.cycle_choice({"methods": ["keyboard-us", "mozc", "hangul"], "current": "keyboard-us"}, [], -1) == ("hangul", None)
assert indicator.layout_switches(keyboards, step=-1)[0][-1] == "1"
print("ok - cycling back walks the same choices in reverse")

# The reader in a real GLib loop, against a real profile file: Fcitx itself is
# replaced by `live`, which a configuration change edits before saving.
import sys
import tempfile
# The configuration home is itself a link, as a dotfile manager may make it.
config_root = tempfile.mkdtemp()
os.makedirs(config_root + "/home-a")
os.symlink("home-a", config_root + "/config")
config_home = config_root + "/config"
os.makedirs(config_home + "/first")
os.makedirs(config_home + "/second")
os.makedirs(config_home + "/third")
# A dotfile manager's layout: the Fcitx directory is a link into the dotfiles.
os.symlink("first", config_home + "/fcitx5")

# Saved the way Fcitx and configure.py save it: a new file renamed over the old.
def save(directory="first", name="profile"):
  path = f"{config_home}/{directory}/{name}"
  with open(path + ".tmp", "w") as file:
    file.write("[Groups/0]\nName=Default\n# " + ",".join(live["methods"]) + "\n")
  os.replace(path + ".tmp", path)

live = {"methods": ["keyboard-us"], "current": "keyboard-us", "name": "English", "label": "en", "language": "en"}
save()
groups = ["Default"]
timers, reader, reads, failures = [], {}, [0], [0]
real_timeout = indicator.GLib.timeout_add
real_io_add_watch = indicator.GLib.io_add_watch

def timeout(interval, fn):
  timers.append(interval)
  return real_timeout(interval, fn)

def register_reader(source, *args):
  # GLib's own loop.run() watches a signal pipe through the same call.
  if source is not sys.stdin:
    return real_io_add_watch(source, *args)
  reader["read"] = args[-1]
  return 1

# The shell closing stdin is what ends the reader.
def close_stdin():
  with patch.object(indicator.os, "read", return_value=b""):
    reader["read"](None, None)

def snapshot(bus):
  reads[0] += 1
  if failures[0]:
    failures[0] -= 1
    raise indicator.GLib.Error("timed out")
  return dict(live, methods=list(live["methods"]))

# GLib swallows exceptions raised in callbacks, so keep them for the end.
errors = []
def step(seconds, then):
  def run():
    try:
      then()
    except Exception as error:
      errors.append(error)
      close_stdin()
    return False
  real_timeout(int(seconds * 1000), run)

state_lines = []
def output(line, flush=False):
  state_lines.append(json.loads(line))

def methods():
  return state_lines[-1]["methods"]

def scenario():
  # One method in one group: the startup read is all, until the profile changes.
  def single_method_settled():
    assert [line["methods"] for line in state_lines] == [["keyboard-us"]], state_lines
    assert 500 not in timers and 50 not in timers, timers
    live["methods"] = ["keyboard-us", "mozc"]
    save()
    step(0.6, after_save)
  def after_save():
    assert methods() == ["keyboard-us", "mozc"], state_lines
    assert 500 in timers, timers
    live["current"] = "mozc"
    step(0.7, after_switch)
  def after_switch():
    # With two methods, a switch made inside an application is read on the next poll.
    assert state_lines[-1]["current"] == "mozc", state_lines
    # A save while polling replaces the poll rather than starting a second one.
    save()
    step(0.4, count_polls)
  def count_polls():
    reads[0] = 0
    step(2.0, polls_counted)
  def polls_counted():
    assert reads[0] <= 5, f"{reads[0]} reads in 2 s"
    live["methods"], live["current"] = ["keyboard-us"], "keyboard-us"
    save()
    step(0.6, back_to_one)
  def back_to_one():
    assert methods() == ["keyboard-us"], state_lines
    # A read that fails while the service runs is retried rather than left blank.
    failures[0] = 1
    save()
    step(0.6, after_failed_read)
  def after_failed_read():
    assert methods() == [], state_lines
    step(2.4, recovered)
  def recovered():
    assert methods() == ["keyboard-us"], state_lines
    # Relinking the Fcitx directory moves the watch to the new target.
    os.symlink("second", config_home + "/fcitx5.new")
    os.replace(config_home + "/fcitx5.new", config_home + "/fcitx5")
    step(0.6, relinked)
  def relinked():
    live["methods"] = ["keyboard-us", "hangul"]
    save("second")
    step(0.6, saved_in_new_target)
  def saved_in_new_target():
    assert methods() == ["keyboard-us", "hangul"], state_lines
    # A profile that is itself a link is watched at its target too.
    live["methods"] = ["keyboard-us"]
    save("third", "profile.real")
    os.symlink("../third/profile.real", config_home + "/second/profile.new")
    os.replace(config_home + "/second/profile.new", config_home + "/second/profile")
    step(0.6, linked_profile)
  def linked_profile():
    assert methods() == ["keyboard-us"], state_lines
    live["methods"] = ["keyboard-us", "pinyin"]
    save("third", "profile.real")
    step(0.6, saved_through_link)
  def saved_through_link():
    assert methods() == ["keyboard-us", "pinyin"], state_lines
    # The directory the link resolves to is replaced, the link left alone.
    live["methods"] = ["keyboard-us"]
    os.rename(config_home + "/third", config_home + "/third.old")
    os.makedirs(config_home + "/third")
    save("third", "profile.real")
    step(0.6, target_replaced)
  def target_replaced():
    assert methods() == ["keyboard-us"], state_lines
    live["methods"] = ["keyboard-us", "chewing"]
    save("third", "profile.real")
    step(0.6, saved_in_replaced_target)
  def saved_in_replaced_target():
    assert methods() == ["keyboard-us", "chewing"], state_lines
    # Relinking the configuration home moves the watch to the new one.
    live["methods"] = ["keyboard-us"]
    os.makedirs(config_root + "/home-b/fcitx5")
    save("../home-b/fcitx5")
    os.symlink("home-b", config_root + "/config.new")
    os.replace(config_root + "/config.new", config_root + "/config")
    step(0.6, home_relinked)
  def home_relinked():
    assert methods() == ["keyboard-us"], state_lines
    live["methods"] = ["keyboard-us", "anthy"]
    save("fcitx5")
    step(0.6, saved_in_new_home)
  def saved_in_new_home():
    assert methods() == ["keyboard-us", "anthy"], state_lines
    # A chain of links: profile -> store/current -> store/profile-a.
    live["methods"] = ["keyboard-us"]
    os.makedirs(config_home + "/store")
    save("store", "profile-a")
    os.symlink("profile-a", config_home + "/store/current")
    os.symlink("../store/current", config_home + "/fcitx5/profile.new")
    os.replace(config_home + "/fcitx5/profile.new", config_home + "/fcitx5/profile")
    step(0.6, chained)
  def chained():
    assert methods() == ["keyboard-us"], state_lines
    # Repointing the middle link is seen, though neither end changed.
    live["methods"] = ["keyboard-us", "rime"]
    save("store", "profile-b")
    os.symlink("profile-b", config_home + "/store/current.new")
    os.replace(config_home + "/store/current.new", config_home + "/store/current")
    step(0.6, middle_relinked)
  def middle_relinked():
    assert methods() == ["keyboard-us", "rime"], state_lines
    # A link whose target steps back out of another link:
    # fcitx5 -> store/redirect/../fcitx5, with store/redirect -> ../x/inner.
    live["methods"] = ["keyboard-us"]
    for side in ("x", "y"):
      os.makedirs(f"{config_home}/{side}/inner")
      os.makedirs(f"{config_home}/{side}/fcitx5")
    save("x/fcitx5")
    os.symlink("../x/inner", config_home + "/store/redirect")
    os.rename(config_home + "/fcitx5", config_home + "/fcitx5.old")
    os.symlink("store/redirect/../fcitx5", config_home + "/fcitx5")
    step(0.6, redirected)
  def redirected():
    assert methods() == ["keyboard-us"], state_lines
    live["methods"] = ["keyboard-us", "sayura"]
    save("y/fcitx5")
    os.symlink("../y/inner", config_home + "/store/redirect.new")
    os.replace(config_home + "/store/redirect.new", config_home + "/store/redirect")
    step(0.6, redirect_repointed)
  def redirect_repointed():
    assert methods() == ["keyboard-us", "sayura"], state_lines
    close_stdin()
  step(1.0, single_method_settled)

os.environ.pop("FCITX_CONFIG_HOME", None)
with patch.dict(os.environ, {"XDG_CONFIG_HOME": config_home}), \
     patch.object(indicator, "snapshot", side_effect=snapshot), \
     patch.object(indicator, "call", side_effect=lambda bus, method, args=None: (list(groups),) if method == "InputMethodGroups" else (_ for _ in ()).throw(AssertionError(method))), \
     patch.object(indicator.Gio, "bus_watch_name_on_connection", return_value=1), \
     patch.object(indicator.GLib, "io_add_watch", side_effect=register_reader), \
     patch.object(indicator.GLib, "timeout_add", side_effect=timeout), \
     patch("builtins.print", side_effect=output):
  step(0, scenario)
  step(20, lambda: errors.append(AssertionError("timed out")) or close_stdin())
  indicator.watch(None)
assert not errors, errors
print("ok - one input method is read once and again on a profile save, and several are polled for switches")
print("ok - an event during polling replaces the poll, and a failed read is retried")
print("ok - relinking the Fcitx directory or the profile moves the watch, and replaced saves are seen")

with patch.dict(os.environ, {"XDG_CONFIG_HOME": "/xdg", "FCITX_CONFIG_HOME": "/fcitx"}):
  assert indicator.profile_path() == "/fcitx/profile"
  del os.environ["FCITX_CONFIG_HOME"]
  assert indicator.profile_path() == "/xdg/fcitx5/profile"
  os.environ["FCITX_CONFIG_HOME"] = "/fcitx/link/../cleaned"
  assert indicator.profile_path() == "/fcitx/cleaned/profile"
  os.environ["FCITX_CONFIG_HOME"] = "relative/fcitx"
  assert indicator.profile_path() == os.path.join(os.getcwd(), "relative/fcitx/profile")
  # Without it, a relative XDG_CONFIG_HOME is relative to the home directory.
  del os.environ["FCITX_CONFIG_HOME"]
  os.environ.update(XDG_CONFIG_HOME="relative/config", HOME="/somewhere")
  assert indicator.profile_path() == "/somewhere/relative/config/fcitx5/profile", indicator.profile_path()
print("ok - the watched profile follows Fcitx's FCITX_CONFIG_HOME override, cleaned the way Fcitx cleans it")

# A link that vanishes mid-resolution, as a relink in progress makes it, is
# watched as an entry rather than failing the whole watch.
race_root = tempfile.mkdtemp()
os.symlink("elsewhere", race_root + "/fcitx5")
with patch.dict(os.environ, {"XDG_CONFIG_HOME": race_root}), \
     patch.object(indicator.os, "readlink", side_effect=FileNotFoundError("relinked")):
  assert (race_root, "fcitx5") in indicator.watched_entries()

# A configuration that does not exist yet is watched from its nearest existing
# directory, and its profile is seen once Fcitx first saves it.
fresh_root = tempfile.mkdtemp()
events = []
with patch.dict(os.environ, {"XDG_CONFIG_HOME": fresh_root + "/config"}):
  assert indicator.watched_entries()[-1] == (fresh_root, "config"), indicator.watched_entries()
  # A context of its own, clear of the sources the reader above left behind.
  import time
  context = indicator.GLib.MainContext.new()
  context.push_thread_default()
  profile_watch = indicator.ProfileWatch(lambda: events.append("changed"))
  def run_until(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
      context.iteration(False)
      time.sleep(0.01)
  os.makedirs(fresh_root + "/config")
  run_until(0.3)
  os.makedirs(fresh_root + "/config/fcitx5")
  run_until(0.3)
  events.clear()
  with open(fresh_root + "/config/fcitx5/profile", "w") as file:
    file.write("[Groups/0]\n")
  run_until(0.3)
  assert events, "the first save of a new profile is seen"
  context.pop_thread_default()

# A configuration beside the home directory, under a shared parent, is still
# watched from its nearest existing directory.
beside_root = tempfile.mkdtemp()
os.makedirs(beside_root + "/home")
with patch.dict(os.environ, {"HOME": beside_root + "/home", "FCITX_CONFIG_HOME": beside_root + "/fcitx5"}):
  assert indicator.watched_entries() == [(beside_root, "fcitx5")], indicator.watched_entries()

# A plain ~/.config is not watched from the busy home directory: only the
# profile and its directory can change with a save.
plain_root = tempfile.mkdtemp()
os.makedirs(plain_root + "/home/.config/fcitx5")
with patch.dict(os.environ, {"HOME": plain_root + "/home"}):
  os.environ.pop("XDG_CONFIG_HOME", None)
  os.environ.pop("FCITX_CONFIG_HOME", None)
  assert indicator.watched_entries() == [(plain_root + "/home/.config", "fcitx5"),
                                         (plain_root + "/home/.config/fcitx5", "profile")], indicator.watched_entries()

# Moving that plain ~/.config aside for a link to a new one is still seen,
# through the event on the watched directory itself.
moved = []
with patch.dict(os.environ, {"HOME": plain_root + "/home"}):
  context = indicator.GLib.MainContext.new()
  context.push_thread_default()
  plain_watch = indicator.ProfileWatch(lambda: moved.append("changed"))
  os.rename(plain_root + "/home/.config", plain_root + "/home/.config.old")
  os.makedirs(plain_root + "/dotfiles/fcitx5")
  os.symlink("../dotfiles", plain_root + "/home/.config")
  run_until(0.3)
  assert moved, "moving ~/.config aside is seen"
  moved.clear()
  with open(plain_root + "/dotfiles/fcitx5/profile", "w") as file:
    file.write("[Groups/0]\n")
  run_until(0.3)
  assert moved, "a save in the linked configuration is seen"
  context.pop_thread_default()

# With ~/.config linked into a dotfiles tree, replacing the whole tree is seen
# through the watch on the tree's own directory.
tree_root = tempfile.mkdtemp()
os.makedirs(tree_root + "/home/dotfiles/config/fcitx5")
os.symlink("dotfiles/config", tree_root + "/home/.config")
replaced = []
with patch.dict(os.environ, {"HOME": tree_root + "/home"}):
  context = indicator.GLib.MainContext.new()
  context.push_thread_default()
  tree_watch = indicator.ProfileWatch(lambda: replaced.append("changed"))
  os.rename(tree_root + "/home/dotfiles", tree_root + "/home/dotfiles.old")
  os.makedirs(tree_root + "/home/dotfiles/config/fcitx5")
  run_until(0.3)
  assert replaced, "replacing the dotfiles tree is seen"
  replaced.clear()
  with open(tree_root + "/home/dotfiles/config/fcitx5/profile", "w") as file:
    file.write("[Groups/0]\n")
  run_until(0.3)
  assert replaced, "a save in the replacement tree is seen"
  context.pop_thread_default()

# A profile kept directly in the home directory is still watched there.
open(plain_root + "/home/profile", "w").close()
with patch.dict(os.environ, {"HOME": plain_root + "/home", "FCITX_CONFIG_HOME": plain_root + "/home"}):
  assert indicator.watched_entries() == [(plain_root + "/home", "profile")], indicator.watched_entries()

# A link written with a trailing slash still leads to the profile's directory.
slash_root = tempfile.mkdtemp()
os.makedirs(slash_root + "/home/.config/first")
os.symlink("first/.", slash_root + "/home/.config/fcitx5")
with patch.dict(os.environ, {"HOME": slash_root + "/home"}):
  os.environ.pop("XDG_CONFIG_HOME", None)
  assert (slash_root + "/home/.config", "first") in indicator.watched_entries(), indicator.watched_entries()

# The path changing while the watches are armed is resolved again.
armed = []
real_new_for_path = indicator.Gio.File.new_for_path
def recording_new_for_path(path):
  armed.append(path)
  return real_new_for_path(path)
early, late = [(fresh_root, "config")], [(fresh_root + "/config", "fcitx5")]
with patch.object(indicator, "watched_entries", side_effect=[early, late, late]), \
     patch.object(indicator.Gio.File, "new_for_path", side_effect=recording_new_for_path):
  indicator.ProfileWatch(lambda: None)
assert armed == [fresh_root, fresh_root + "/config"], armed
print("ok - a missing configuration is watched until it exists, and a vanishing link keeps its watch")

# The profile is the one the Fcitx process saves, whose environment a service
# drop-in can set without the shell knowing.
daemon_dir = tempfile.mkdtemp()
os.makedirs(daemon_dir + "/relative/fcitx")
daemon = subprocess.Popen(["sleep", "30"], cwd=daemon_dir,
                          env={"HOME": daemon_dir, "FCITX_CONFIG_HOME": "relative/fcitx"})
class OwnerBus:
  def call_sync(self, name, path, interface, method, args, *rest):
    assert method == "GetConnectionUnixProcessID" and args.unpack() == (indicator.BUS,)
    return indicator.GLib.Variant("(u)", (daemon.pid,))
try:
  owner = indicator.owner_environment(OwnerBus())
  assert indicator.profile_path(owner) == daemon_dir + "/relative/fcitx/profile", indicator.profile_path(owner)
  appeared, armed = {}, []
  def watch_name(bus, name, flags, on_appeared, on_vanished):
    appeared["callback"] = on_appeared
    return 1
  with patch.object(indicator.Gio, "bus_watch_name_on_connection", side_effect=watch_name), \
       patch.object(indicator.Gio.File, "new_for_path", side_effect=recording_new_for_path):
    indicator.follow(OwnerBus(), lambda: None, lambda present: None)
    armed.clear()
    appeared["callback"]()
  assert armed[-1] == daemon_dir + "/relative/fcitx", armed
finally:
  daemon.kill()
print("ok - the watch follows the profile of the process that owns Fcitx's bus name")

groups.append("Second")
with patch.object(indicator, "call", return_value=(groups,)):
  assert indicator.Indicator(None).switchable(["keyboard-us"])
  groups.pop()
  assert not indicator.Indicator(None).switchable(["keyboard-us"])
  assert indicator.Indicator(None).switchable(["keyboard-us", "mozc"])
  assert indicator.Indicator(None).switchable(["pinyin"])
print("ok - a second group or a lone composition engine keeps polling, since neither switch has a signal")

PY

stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT
calls="$stubs/calls"
cat >"$stubs/omarchy-shell" <<'SH'
#!/bin/bash
echo "shell $*" >>"$CALLS"
echo "$SHELL_REPLY"
SH
chmod +x "$stubs/omarchy-shell"

CALLS=$calls SHELL_REPLY=ok PATH="$stubs:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-input-method" cycle
[[ $(<"$calls") == "shell shell cycleInput next" ]] || fail "Super+I goes through the shell's reader" "$(<"$calls")"
pass "Super+I goes through the shell's reader, which retains a choice made without focus"

if CALLS=$calls SHELL_REPLY="not running" PATH="$stubs:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-input-method" cycle 2>/dev/null; then
  fail "Super+I reports a missing input reader"
fi
pass "Super+I reports a missing input reader instead of silently doing nothing"

: >"$calls"
CALLS=$calls SHELL_REPLY=ok PATH="$stubs:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-input-method" cycle back
[[ $(<"$calls") == "shell shell cycleInput back" ]] || fail "Super+Shift+I cycles back" "$(<"$calls")"
if CALLS=$calls PATH="$stubs:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-input-method" cycle sideways 2>/dev/null; then
  fail "an unknown cycle direction is rejected"
fi
pass "Super+Shift+I cycles back through the shell, and other directions are rejected"

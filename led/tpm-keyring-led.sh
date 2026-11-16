#!/usr/bin/env bash
# tpm-keyring-unlock: power-button LED
#
# tpm-keyring-led: blinks the power-button LED of a Framework laptop while
# fprintd waits for a finger. The fingerprint reader sits in that button, and
# nothing else shows when it is listening - sudo, the lock screen, polkit.
# (The line above is the marker install.sh and uninstall.sh know this file by:
# a file at this path without it is not this tool's to replace or remove.)
#
# The optional part of tpm-keyring-unlock. install.sh offers it on a Framework
# laptop only, and installs it as tpm-keyring-led.service: a system user of
# its own with no capabilities, sandboxed. A udev rule lets that user's group
# write this LED's trigger, brightness and colour, and nothing else.
# README.md, "Power-button LED".
#
# The idea and the approach come from framework-fingerprint-led-blink by
# alejandroqh (https://github.com/alejandroqh/framework-fingerprint-led-blink,
# Apache-2.0): blink while fprintd's own `finger-needed` property is true, read
# from signals the bus vouches came from fprintd, and hand the LED back to the
# EC through its `chromeos-auto` trigger. This is a separate implementation in
# bash, so the feature needs no interpreter beyond the one the rest of this
# tool runs on.
#
#   tpm-keyring-led            watch fprintd and blink (what the service runs)
#   tpm-keyring-led --restore  give back an LED a killed watcher left taken,
#                              then exit (the unit's ExecStopPost)
#
# No `set -e`: one failed write to the LED must not end the watcher.
set -uo pipefail
# The C locale, for two things that read numbers: $EPOCHREALTIME is written
# with the locale's decimal separator (a comma under de_DE, seen on a machine
# with LC_NUMERIC=de_DE.UTF-8), and read -t's timeouts below are written with
# a point.
export LC_ALL=C

# Overridable for the test suite. The service does not set it.
LEDS="${TPM_KEYRING_LED_SYSFS:-/sys/class/leds}"
FPRINT_BUS=net.reactivated.Fprint

# The power-button LED: chromeos:white:power on most models, a multicolour
# chromeos:multicolor:power on the older Framework 13 (Intel 11th-13th gen).
# NOTE: bin/lib.sh's LED_SYSFS_NAMES and the udev rule name the same two, and
# test/led-test.sh holds the three to each other. lib.sh cannot be sourced
# from here: install.sh copies this file alone.
LED_CANDIDATES=(chromeos:white:power chromeos:multicolor:power)

HALF_US=250000  # microseconds dark, then microseconds lit
COLOUR=white    # the only channel lit on a multicolour LED, whose default is red
# Seconds one stretch of blinking may last at most. Overridable for the test
# suite, which cannot wait out a minute; the service does not set it.
MAX_BLINK="${TPM_KEYRING_LED_MAX_BLINK:-60}"
[[ "$MAX_BLINK" =~ ^[1-9][0-9]*$ ]] || MAX_BLINK=60

# While the LED is this watcher's, a note of that sits here: the LED's name,
# then a multicolour LED's colours from before. It is how a later --restore,
# or the next start, tells an LED a killed watcher left dark from one its
# owner switched off on purpose - both read `trigger none`, and only the first
# is this tool's to change. The unit's RuntimeDirectory= provides the
# directory; run by hand without one, there is no note and nothing to recover.
MARK=""
[ -z "${RUNTIME_DIRECTORY:-}" ] || MARK="${RUNTIME_DIRECTORY%%:*}/taken"

led=""              # the LED's sysfs directory while it is ours, else empty
max=100             # its max_brightness
saved_intensity=""  # a multicolour LED's colours from before it was taken
lit=false
blinking=false
blink_until=0       # microseconds: when the cap ends this stretch
next_tick=0         # microseconds: when the LED next goes dark or lit
capped=false        # the cap ended the last stretch, and no new prompt since
fresh_need=false    # the line just read said finger-needed: <true>

log() { printf 'tpm-keyring-led: %s\n' "$*" >&2; }

# Microseconds since the epoch, into $now. Either separator is taken out, in
# case the locale above did not reach $EPOCHREALTIME.
clock() { now="${EPOCHREALTIME/[.,]/}"; }

# Prints the active trigger of the LED directory $1: the word the kernel
# brackets in the list it reads back. A file holding a single word - which
# sysfs never gives, but the test suite's plain files do - is that word.
active_trigger() {
  local t
  { t="$(<"$1/trigger")"; } 2>/dev/null || return 1
  if [[ "$t" =~ \[([^]]+)\] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ -n "$t" && "$t" != *" "* ]]; then
    printf '%s\n' "$t"
  else
    return 1
  fi
}

# Writes $3 into the attribute $2 of the LED directory $1.
put() {
  { printf '%s\n' "$3" >"$1/$2"; } 2>/dev/null || log "could not write '$3' to $1/$2"
}

# Gives back the LED the note says an earlier watcher took and never returned:
# its colours first, then the EC - the trigger only if it is still the `none`
# that watcher set, since any other is somebody's choice made since. With no
# note, nothing is touched. Run at startup and by the unit's ExecStopPost.
restore_marked() {
  local name="" intensity="" c known=false d
  [ -n "$MARK" ] && [ -f "$MARK" ] || return 0
  { read -r name && read -r intensity; } <"$MARK" 2>/dev/null
  for c in "${LED_CANDIDATES[@]}"; do
    [ "$c" != "$name" ] || known=true
  done
  d="$LEDS/$name"
  if [ "$known" = true ] && [ -e "$d/trigger" ]; then
    [[ ! "$intensity" =~ ^[0-9]+(\ [0-9]+)*$ ]] || put "$d" multi_intensity "$intensity"
    [ "$(active_trigger "$d")" != none ] || put "$d" trigger chromeos-auto
  fi
  rm -f "$MARK" 2>/dev/null
}

# Takes the first power-button LED the EC drives, lighting only COLOUR on a
# multicolour one. Fails, changing nothing, when there is none. An LED on any
# other trigger is somebody's own setting - a button switched off with
# `trigger none`, say - and is never taken, so giving back always means
# chromeos-auto again. Looked up afresh every time, so an LED whose driver
# loads after this service starts is still found.
take_led() {
  local name d channels=() c intensity=""
  led=""
  for name in "${LED_CANDIDATES[@]}"; do
    d="$LEDS/$name"
    [ "$(active_trigger "$d")" = chromeos-auto ] || continue
    led="$d"
    break
  done
  [ -n "$led" ] || return 1
  { max="$(<"$led/max_brightness")"; } 2>/dev/null || max=100
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=100
  saved_intensity=""
  # One channel (white:power reports exactly that) needs no choosing.
  if { read -r -a channels <"$led/multi_index"; } 2>/dev/null \
    && [ "${#channels[@]}" -ge 2 ] && [[ " ${channels[*]} " == *" $COLOUR "* ]] \
    && { saved_intensity="$(<"$led/multi_intensity")"; } 2>/dev/null; then
    for c in "${channels[@]}"; do
      if [ "$c" = "$COLOUR" ]; then intensity+="$max "; else intensity+="0 "; fi
    done
  fi
  # The note before the first write, so no kill can leave the LED taken with
  # nothing saying so.
  if [ -n "$MARK" ]; then
    { printf '%s\n%s\n' "$name" "$saved_intensity" >"$MARK"; } 2>/dev/null \
      || log "could not note the LED as taken in $MARK"
  fi
  put "$led" trigger none
  [ -z "$intensity" ] || put "$led" multi_intensity "${intensity% }"
  return 0
}

# Lets go of the LED without writing to it: somebody else has set its trigger
# while it blinked, and theirs is the last word.
let_go() {
  led=""
  saved_intensity=""
  blinking=false
  [ -z "$MARK" ] || rm -f "$MARK" 2>/dev/null
}

# Hands the LED taken by take_led() back: its colours first, then the EC -
# the trigger only if it is still the `none` take_led() set.
give_back() {
  [ -n "$led" ] || return 0
  [ -z "$saved_intensity" ] || put "$led" multi_intensity "$saved_intensity"
  [ "$(active_trigger "$led")" != none ] || put "$led" trigger chromeos-auto
  let_go
}

blink_start() {
  take_led || return 0
  blinking=true
  clock
  blink_until=$((now + MAX_BLINK * 1000000))
  next_tick=$((now + HALF_US))
  # Dark first: the power LED is normally lit, so starting lit would show no
  # change for the first half period.
  lit=false
  put "$led" brightness 0
}

blink_stop() {
  blinking=false
  give_back
}

# Flips the LED between dark and lit. Fails, having let go, when somebody else
# set its trigger since it was taken: writing brightness then would undo their
# setting.
blink_toggle() {
  if [ "$(active_trigger "$led")" != none ]; then
    log "somebody else set $led's trigger - letting go of it"
    let_go
    return 1
  fi
  if [ "$lit" = true ]; then
    put "$led" brightness 0
    lit=false
  else
    put "$led" brightness "$max"
    lit=true
  fi
}

case "${1:-}" in
  "") ;;
  --restore)
    restore_marked
    exit 0
    ;;
  *)
    log "usage: ${0##*/} [--restore]"
    exit 2
    ;;
esac

restore_marked

# `gdbus monitor --dest` subscribes to signals from the current owner of
# fprintd's bus name only. The bus stamps every message with its real sender,
# so another local user cannot fake a finger-needed signal - such a signal is
# never delivered here. It needs no privilege, and keeps running when fprintd
# exits after its idle timeout, saying so: "does not have an owner". Starting
# it activates fprintd, which exits again after its 30 s idle timeout.
#
# A coprocess rather than `< <(...)`: process substitution is opened through
# /dev/fd, and the unit's PrivateDevices= gives the service a /dev of its own.
# The coprocess is plain pipes. Its descriptor is copied at once, because bash
# unsets MON once it has reaped gdbus, and lines still in the pipe would be
# unreadable then.
coproc MON { exec gdbus monitor --system --dest "$FPRINT_BUS"; }
mon_pid=$MON_PID
exec {mon}<&"${MON[0]}"

stop() {
  blink_stop
  kill "$mon_pid" 2>/dev/null
}
trap 'stop; exit 0' TERM INT HUP

# The lines that matter, as gdbus prints them:
#   /net/reactivated/Fprint/Device/0: org.freedesktop.DBus.Properties.PropertiesChanged ('net.reactivated.Fprint.Device', {'finger-needed': <true>}, @as [])
#   The name net.reactivated.Fprint does not have an owner
#   The name net.reactivated.Fprint is owned by :1.155
PROPS_RE="^(/net/reactivated/Fprint/Device/[A-Za-z0-9_]+): org\\.freedesktop\\.DBus\\.Properties\\.PropertiesChanged \\('net\\.reactivated\\.Fprint\\.Device', \\{([^}]*)\\}"
# A device path in GetDevices' reply: ([objectpath '/net/.../Device/0'],)
DEVICE_RE="'(/net/reactivated/Fprint/Device/[A-Za-z0-9_]+)'"

# The devices whose finger-needed / finger-present is true right now. It
# blinks while some device needs a finger and has none on it: fprintd keeps
# finger-needed true for over a second after a match, so a touch stops it
# straight away, and lifting the finger off a bad scan starts it again.
# finger-present alone never starts it.
declare -A needed=() present=()

# Records what the property dictionary $2 says about the device $1. Fails
# when it says nothing about a finger.
note_props() {
  local path="$1" props="$2" changed=1
  case "$props" in
    *"'finger-needed': <true>"*) needed[$path]=1; fresh_need=true; changed=0 ;;
    *"'finger-needed': <false>"*) unset "needed[$path]"; changed=0 ;;
  esac
  case "$props" in
    *"'finger-present': <true>"*) present[$path]=1; changed=0 ;;
    *"'finger-present': <false>"*) unset "present[$path]"; changed=0 ;;
  esac
  return "$changed"
}

wants_blink() {
  local p
  for p in "${!needed[@]}"; do
    [ -n "${present[$p]:-}" ] || return 0
  done
  return 1
}

# Asks fprintd what it is waiting for right now. Signals only report changes,
# so a watcher started while a prompt is already up - a restart, an update -
# would otherwise stay dark until the next change. Asked once, when fprintd's
# name first shows an owner: by then the subscription is in place, so nothing
# between the answer and the next signal is lost. The replies come from the
# owner of the name, routed by the bus, like the signals.
seeded=false
seed_state() {
  local out path props
  seeded=true
  out="$(timeout 5 gdbus call --system --dest "$FPRINT_BUS" \
    --object-path /net/reactivated/Fprint/Manager \
    --method "$FPRINT_BUS.Manager.GetDevices" 2>/dev/null)" || return 0
  while [[ "$out" =~ $DEVICE_RE ]]; do
    path="${BASH_REMATCH[1]}"
    out="${out#*"'$path'"}"
    props="$(timeout 5 gdbus call --system --dest "$FPRINT_BUS" --object-path "$path" \
      --method org.freedesktop.DBus.Properties.GetAll "$FPRINT_BUS.Device" 2>/dev/null)" || continue
    note_props "$path" "$props" || true
  done
}

log "watching $FPRINT_BUS for the power-button LED"

# While blinking, the clock decides: each pass toggles the LED when its half
# period is up and ends the stretch when the cap is, and then waits for a line
# from gdbus only until the next tick. Lines arriving faster than that - a
# chatty device, a second reader - cannot hold the LED still or keep it past
# the cap (review, 2026-11-16). A timeout can land mid-line, and read keeps
# what it got, so that part is carried over to the next read.
partial=""
while :; do
  line=""
  if [ "$blinking" = true ]; then
    clock
    if [ "$now" -ge "$blink_until" ]; then
      # The cap. Only a new prompt - finger-needed turning true again - starts
      # it again. Any other line would not do: a stream of them, a second
      # device's finger-present say, would otherwise take the LED straight
      # back, and the cap would hold nothing (found by its test, 2026-11-16).
      blink_stop
      capped=true
      continue
    fi
    if [ "$now" -ge "$next_tick" ]; then
      blink_toggle || continue
      next_tick=$((now + HALF_US))
    fi
    wait_us=$((next_tick - now))
    [ "$wait_us" -gt 0 ] || wait_us=1
    printf -v tmo '%d.%06d' $((wait_us / 1000000)) $((wait_us % 1000000))
    # Not `if ! read`: after that, $? is the negation's status, and a timeout
    # read as end of input. The first version did that, and stopped at the
    # first tick (JOURNAL.md, 2026-11-15).
    rc=0
    IFS= read -r -t "$tmo" -u "$mon" line || rc=$?
    if [ "$rc" -ne 0 ]; then
      # Above 128 is a timeout; anything else is the end of gdbus's output.
      [ "$rc" -gt 128 ] || break
      partial+="$line"
      continue
    fi
  else
    IFS= read -r -u "$mon" line || break
  fi
  line="$partial$line"
  partial=""

  if [[ "$line" =~ $PROPS_RE ]]; then
    note_props "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" || continue
  elif [[ "$line" == "The name $FPRINT_BUS is owned by "* ]]; then
    # A new fprintd: nothing known about the old one holds.
    needed=()
    present=()
    [ "$seeded" = true ] || seed_state
  elif [[ "$line" == "The name $FPRINT_BUS does not have an owner" ]]; then
    # fprintd went away: nothing is waiting for a finger.
    needed=()
    present=()
  else
    continue
  fi

  if wants_blink; then
    if [ "$blinking" != true ] && { [ "$capped" = false ] || [ "$fresh_need" = true ]; }; then
      capped=false
      blink_start
    fi
  else
    capped=false
    [ "$blinking" != true ] || blink_stop
  fi
  fresh_need=false
done

# gdbus's output ended. Leave the LED to the EC, make sure gdbus is gone too,
# and let the service manager restart this.
stop
log "gdbus monitor exited"
exit 1

#!/usr/bin/env bash
# tpm-keyring-led: blinks the power-button LED of a Framework laptop while
# fprintd waits for a finger. The fingerprint reader sits in that button, and
# nothing else shows when it is listening - sudo, the lock screen, polkit.
#
# The optional part of tpm-keyring-unlock. install.sh offers it on a Framework
# laptop only, and installs it as tpm-keyring-led.service: a throwaway user
# with no capabilities, sandboxed. A udev rule lets that service's group write
# this LED's trigger, brightness and colour, and nothing else. README.md,
# "Power-button LED".
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

# Overridable for the test suite. The service does not set it.
LEDS="${TPM_KEYRING_LED_SYSFS:-/sys/class/leds}"
FPRINT_BUS=net.reactivated.Fprint

# The power-button LED: chromeos:white:power on most models, a multicolour
# chromeos:multicolor:power on the older Framework 13 (Intel 11th-13th gen).
# NOTE: bin/lib.sh's LED_SYSFS_NAMES and the udev rule name the same two, and
# test/led-test.sh holds the three to each other. lib.sh cannot be sourced
# from here: install.sh copies this file alone.
LED_CANDIDATES=(chromeos:white:power chromeos:multicolor:power)

HALF=0.25     # seconds dark, then seconds lit
COLOUR=white  # the only channel lit on a multicolour LED, whose default is red
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
blink_until=0

log() { printf 'tpm-keyring-led: %s\n' "$*" >&2; }

# Succeeds when the EC drives the LED directory $1 right now. The kernel
# brackets the active trigger.
ec_has_it() {
  local t
  { t="$(<"$1/trigger")"; } 2>/dev/null || return 1
  [[ " $t " == *" [chromeos-auto] "* ]]
}

# Writes $3 into the attribute $2 of the LED directory $1.
put() {
  { printf '%s\n' "$3" >"$1/$2"; } 2>/dev/null || log "could not write '$3' to $1/$2"
}

# Gives back the LED the note says an earlier watcher took and never returned:
# its colours first, then the EC. With no note, nothing is touched. Run at
# startup and by the unit's ExecStopPost.
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
    ec_has_it "$d" || put "$d" trigger chromeos-auto
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
    ec_has_it "$d" || continue
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

# Hands the LED taken by take_led() back: its colours first, then the EC.
give_back() {
  [ -n "$led" ] || return 0
  [ -z "$saved_intensity" ] || put "$led" multi_intensity "$saved_intensity"
  saved_intensity=""
  ec_has_it "$led" || put "$led" trigger chromeos-auto
  led=""
  [ -z "$MARK" ] || rm -f "$MARK" 2>/dev/null
}

blink_start() {
  take_led || return 0
  blinking=true
  blink_until=$((SECONDS + MAX_BLINK))
  # Dark first: the power LED is normally lit, so starting lit would show no
  # change for the first half period.
  lit=false
  put "$led" brightness 0
}

blink_stop() {
  blinking=false
  give_back
}

blink_toggle() {
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
    *"'finger-needed': <true>"*) needed[$path]=1; changed=0 ;;
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

# read -t is the clock: while blinking, every half period without a line from
# gdbus is a toggle. A timeout can land mid-line, and read keeps what it got,
# so that part is carried over to the next read rather than lost.
partial=""
while :; do
  line=""
  if [ "$blinking" = true ]; then
    # Not `if ! read`: after that, $? is the negation's status, and a timeout
    # read as end of input. The first version did that, and stopped at the
    # first tick (JOURNAL.md, 2026-11-15).
    rc=0
    IFS= read -r -t "$HALF" -u "$mon" line || rc=$?
    if [ "$rc" -ne 0 ]; then
      # Above 128 is a timeout; anything else is the end of gdbus's output.
      [ "$rc" -gt 128 ] || break
      partial+="$line"
      if [ "$SECONDS" -ge "$blink_until" ]; then
        # The cap. Only a new change reported by fprintd starts it again.
        blink_stop
      else
        blink_toggle
      fi
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
    [ "$blinking" = true ] || blink_start
  elif [ "$blinking" = true ]; then
    blink_stop
  fi
done

# gdbus's output ended. Leave the LED to the EC, make sure gdbus is gone too,
# and let the service manager restart this.
stop
log "gdbus monitor exited"
exit 1

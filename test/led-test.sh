#!/usr/bin/env bash
# Tests the optional power-button LED service: led/tpm-keyring-led.sh, the
# watcher, and bin/lib.sh's part - who is asked (framework_power_led), and the
# install, update, rollback and removal install.sh and uninstall.sh run.
#
# No container, no root, no D-Bus. A fake `gdbus` first in PATH plays a
# scripted run of fprintd's signals, exactly as `gdbus monitor` prints them,
# and answers `gdbus call` the way fprintd does. A directory of plain files
# stands in for /sys/class/leds. The fake also looks at the LED at chosen
# moments of its script, so every check is tied to the signal before it. For
# the install, sudo, systemctl, udevadm and friends are stubs, and /etc is a
# directory under the test's own - without a sysusers.d, as on Ubuntu, Debian
# and Arch.
#
# A plain file is not sysfs: sysfs reads `trigger` back as the whole list, the
# active one bracketed ("none [chromeos-auto] ..."), while a file holds the
# last word written. The fake turns a bare word back into that list before it
# sends each line, which is when the watcher reads it next. Checks made right
# after the watcher wrote see the bare word.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$REPO_DIR/led/tpm-keyring-led.sh"

T="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT

fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (got: $got, want: $want)"
    fail=1
  fi
}

LIST_WORDS="none kbd-capslock disk-activity chromeos-auto rfkill-any"
TRIGGERS='none kbd-capslock disk-activity [chromeos-auto] rfkill-any'

# $1: LED name, $2: multi_index, $3: multi_intensity, $4: trigger file content
make_led() {
  local d="$T/leds/$1"
  mkdir -p "$d"
  printf '%s\n' "${4:-$TRIGGERS}" >"$d/trigger"
  printf '100\n' >"$d/brightness"
  printf '100\n' >"$d/max_brightness"
  printf '%s\n' "$2" >"$d/multi_index"
  printf '%s\n' "$3" >"$d/multi_intensity"
  chmod 0644 "$d"/*
}

mkdir -p "$T/bin"
# The fake gdbus. `gdbus monitor` records how it was called and sources the
# scenario named by $SCENARIO, whose emit/snap/sample calls write fprintd's
# lines and record what the LED looked like at that moment. `gdbus call`
# answers GetDevices and GetAll as fprintd does, finger-needed as $FAKE_NEEDED
# says, and logs each call.
cat >"$T/bin/gdbus" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "$1" = call ]; then
  printf '%s\n' "$*" >>"$OUT/calls"
  case "$*" in
    *GetDevices*) echo "([objectpath '/net/reactivated/Fprint/Device/0'],)" ;;
    *GetAll*) echo "({'name': <'Fake'>, 'scan-type': <'press'>, 'finger-present': <false>, 'finger-needed': <${FAKE_NEEDED:-false}>},)" ;;
  esac
  exit 0
fi
printf '%s\n' "$*" >"$OUT/argv"
LED="$TPM_KEYRING_LED_SYSFS/$LED_NAME"
settle() {
  local t w out=""
  t="$(<"$LED/trigger")"
  [ -n "$t" ] && [[ "$t" != *" "* ]] || return 0
  for w in $LIST_WORDS; do
    if [ "$w" = "$t" ]; then out+="[$w] "; else out+="$w "; fi
  done
  printf '%s\n' "${out% }" >"$LED/trigger"
}
emit() { settle; printf '%s\n' "$1"; }
needed() { emit "/net/reactivated/Fprint/Device/${2:-0}: org.freedesktop.DBus.Properties.PropertiesChanged ('net.reactivated.Fprint.Device', {'finger-needed': <$1>}, @as [])"; }
present() { emit "/net/reactivated/Fprint/Device/${2:-0}: org.freedesktop.DBus.Properties.PropertiesChanged ('net.reactivated.Fprint.Device', {'finger-present': <$1>}, @as [])"; }
# snap NAME: the LED's trigger, brightness and colours, one line
snap() { printf '%s|%s|%s\n' "$(<"$LED/trigger")" "$(<"$LED/brightness")" "$(<"$LED/multi_intensity")" >"$OUT/$1"; }
# mark NAME: the watcher's note that the LED is taken, or "no note"
mark() { if [ -f "$OUT/run/taken" ]; then tr '\n' '|' <"$OUT/run/taken"; else echo "no note"; fi >"$OUT/$1"; }
# sample NAME SECONDS: every brightness value seen over that long, sorted, unique
sample() {
  local i n
  n=$(awk -v s="$2" 'BEGIN { printf "%d", s / 0.05 }')
  for ((i = 0; i < n; i++)); do cat "$LED/brightness"; sleep 0.05; done | sort -u | tr '\n' ' ' >"$OUT/$1"
}
emit "Monitoring signals from all objects owned by net.reactivated.Fprint"
emit "The name net.reactivated.Fprint is owned by :1.42"
# shellcheck disable=SC1090
source "$SCENARIO"
EOF
chmod +x "$T/bin/gdbus"
export LIST_WORDS

# Runs the watcher against scenario $1 with LED $2 and, optionally, the cap
# $3, with a runtime directory for its note as systemd would give it. Leaves
# its exit status in $OUT/rc and its stderr in $OUT/log.
run_watcher() {
  OUT="$T/out-$1"
  mkdir -p "$OUT/run"
  ( export OUT SCENARIO="$T/$1.sh" LED_NAME="$2" TPM_KEYRING_LED_SYSFS="$T/leds"
    export RUNTIME_DIRECTORY="$OUT/run" PATH="$T/bin:$PATH" ${3:+TPM_KEYRING_LED_MAX_BLINK=$3}
    rc=0
    timeout 30 bash "$WATCHER" 2>"$OUT/log" || rc=$?
    echo "$rc" >"$OUT/rc" )
}
out() { cat "$T/out-$1/$2" 2>/dev/null || echo missing; }
# The active trigger in a snapshot: the bracketed word of a list, or a bare
# word as the watcher wrote it. Which of the two a snapshot holds depends on
# whether the fake sent another line after the write, which is timing.
act() {
  local t
  t="$(out "$1" "$2" | cut -d'|' -f1)"
  if [[ "$t" =~ \[([^]]+)\] ]]; then echo "${BASH_REMATCH[1]}"; else echo "$t"; fi
}
calls() { grep -c -- "$2" "$T/out-$1/calls" 2>/dev/null || true; }

# --- the white LED, through a whole prompt ---------------------------------
make_led chromeos:white:power white 100
cat >"$T/white.sh" <<'EOF'
sleep 0.3; snap start
# Signals that are not about a finger change nothing.
emit "/net/reactivated/Fprint/Device/0: net.reactivated.Fprint.Device.VerifyFingerSelected ('right-index-finger',)"
sleep 0.3; snap unrelated
needed true
sample waiting 1.2; snap waiting-state; mark waiting-note
present true
sleep 0.3; snap touched; mark touched-note
present false
sample lifted 1.0
needed false
sleep 0.4; snap done; mark done-note
sample done-sampled 0.6
EOF
run_watcher white chromeos:white:power
check "subscribes to fprintd's own signals only (gdbus monitor --dest)" \
  "$(out white argv)" "monitor --system --dest net.reactivated.Fprint"
check "startup leaves an LED the EC drives untouched (no trigger write)" \
  "$(out white start)" "$TRIGGERS|100|100"
check "a signal that is not about a finger starts nothing" \
  "$(out white unrelated)" "$TRIGGERS|100|100"
check "finger-needed: blinks, dark and lit" "$(out white waiting)" "0 100 "
check "finger-needed: the LED is taken from the EC" "$(act white waiting-state)" "none"
check "while taken, a note says so, naming the LED" "$(out white waiting-note)" "chromeos:white:power||"
check "a finger on the sensor stops it, back to the EC" "$(act white touched)" "chromeos-auto"
check "given back, the note is gone" "$(out white touched-note)" "no note"
check "the finger lifted while still needed: blinks again" "$(out white lifted)" "0 100 "
check "finger-needed false: back to the EC" "$(act white done)" "chromeos-auto"
check "finger-needed false: no note left" "$(out white done-note)" "no note"
check "finger-needed false: no more blinking" "$(wc -w <"$T/out-white/done-sampled" | tr -d ' ')" "1"
check "a single-channel LED's colour is left alone" "$(out white done | cut -d'|' -f3)" "100"
check "gdbus ending is a failure, for the service manager to restart" "$(out white rc)" "1"
check "fprintd's state is asked for once, when its name shows an owner" "$(calls white GetDevices)" "1"

# --- started while fprintd is already waiting -------------------------------
cat >"$T/seed.sh" <<'EOF'
sample seeded 1.0; snap seeded-state
needed false
sleep 0.4; snap done
emit "The name net.reactivated.Fprint is owned by :1.43"
sleep 0.3
EOF
FAKE_NEEDED=true run_watcher seed chromeos:white:power
check "started mid-prompt: blinks with no new signal" "$(out seed seeded)" "0 100 "
check "started mid-prompt: the LED is taken" "$(act seed seeded-state)" "none"
check "started mid-prompt: stops when the prompt ends" "$(act seed done)" "chromeos-auto"
check "a later owner does not ask again (the signals cover it)" "$(calls seed GetDevices)" "1"
check "the device's properties are read from that device" \
  "$(calls seed 'object-path /net/reactivated/Fprint/Device/0 --method org.freedesktop.DBus.Properties.GetAll')" "1"

# --- older Framework 13: the multicolour LED, red by default ----------------
rm -rf "$T/leds"
make_led chromeos:multicolor:power "red green blue yellow white amber" "100 0 0 0 0 0"
cat >"$T/multi.sh" <<'EOF'
needed true
sleep 0.6; snap waiting; mark waiting-note
needed false
sleep 0.4; snap done
EOF
run_watcher multi chromeos:multicolor:power
check "multicolour: only white is lit while blinking" "$(act multi waiting)|$(out multi waiting | cut -d'|' -f3)" "none|0 0 0 0 100 0"
check "multicolour: the note keeps its colours from before" "$(out multi waiting-note)" "chromeos:multicolor:power|100 0 0 0 0 0|"
check "multicolour: its colours come back afterwards" "$(act multi done)|$(out multi done | cut -d'|' -f3)" "chromeos-auto|100 0 0 0 0 0"

# --- fprintd going away, two devices ----------------------------------------
rm -rf "$T/leds"
make_led chromeos:white:power white 100
cat >"$T/owner.sh" <<'EOF'
needed true
sleep 0.5; snap waiting
emit "The name net.reactivated.Fprint does not have an owner"
sleep 0.4; snap gone
# A finger on one device does not hide another device that wants one.
needed true 0
present true 1
sleep 0.5; snap two-devices
needed false 0
sleep 0.4; snap two-done
EOF
run_watcher owner chromeos:white:power
check "fprintd losing its bus name stops it" "$(act owner gone)" "chromeos-auto"
check "finger-present on another device does not stop it" "$(act owner two-devices)" "none"
check "and it stops when that device is done" "$(act owner two-done)" "chromeos-auto"

# --- LEDs that are not the EC's are never taken -----------------------------
rm -rf "$T/leds"
make_led chromeos:white:power white 100 "none default kbd-capslock [disk-activity]"
cat >"$T/noauto.sh" <<'EOF'
needed true
sleep 0.6; snap waiting
EOF
run_watcher noauto chromeos:white:power
check "an LED with no chromeos-auto trigger is never taken" \
  "$(out noauto waiting)" "none default kbd-capslock [disk-activity]|100|100"

rm -rf "$T/leds"
make_led chromeos:white:power white 100 "[none] kbd-capslock chromeos-auto"
cp "$T/noauto.sh" "$T/off.sh"
run_watcher off chromeos:white:power
check "a button its owner switched off (trigger none) is not woken, at start or prompt" \
  "$(out off waiting)" "[none] kbd-capslock chromeos-auto|100|100"

# --- the safety cap, and a line split across a blink tick -------------------
rm -rf "$T/leds"
make_led chromeos:white:power white 100
# With a 2 s cap the blinking ends 1 to 2.25 s in: the cap is counted in
# whole seconds and checked at each tick. The checks sit at 0.5 s and 3.5 s.
cat >"$T/cap.sh" <<'EOF'
needed true
sleep 0.5; snap early
sleep 3.0; snap capped
sample capped-sampled 0.6
EOF
run_watcher cap chromeos:white:power 2
check "cap: blinking at first" "$(act cap early)" "none"
check "cap: back to the EC once it runs out, still needed" "$(act cap capped)" "chromeos-auto"
check "cap: and no more blinking" "$(wc -w <"$T/out-cap/capped-sampled" | tr -d ' ')" "1"

cat >"$T/split.sh" <<'EOF'
needed true
sleep 0.6
# Half a line, then a pause past the blink tick, then the rest.
printf '%s' "/net/reactivated/Fprint/Device/0: org.freedesktop.DBus.Properties.Pro"
sleep 0.6
emit "pertiesChanged ('net.reactivated.Fprint.Device', {'finger-needed': <false>}, @as [])"
sleep 0.4; snap done
EOF
run_watcher split chromeos:white:power
check "a line cut by a blink tick still counts" "$(act split done)" "chromeos-auto"

# --- stopped mid-blink: by SIGTERM, and by SIGKILL ---------------------------
LEDDIR="$T/leds/chromeos:white:power"
cat >"$T/hold.sh" <<'EOF'
needed true
sleep 30
EOF
# Starts the watcher in the background on hold.sh; its PID goes in $wpid.
start_held() {
  OUT="$T/out-$1"
  mkdir -p "$OUT/run"
  ( export OUT SCENARIO="$T/hold.sh" LED_NAME=chromeos:white:power TPM_KEYRING_LED_SYSFS="$T/leds"
    export RUNTIME_DIRECTORY="$OUT/run" PATH="$T/bin:$PATH"
    exec bash "$WATCHER" 2>"$OUT/log" ) &
  wpid=$!
  sleep 0.8
}
start_held term
mid="$(cut -d' ' -f1 <"$LEDDIR/trigger")"
kill -TERM "$wpid"
rc=0
wait "$wpid" || rc=$?
check "SIGTERM mid-blink: it was blinking" "$mid" "none"
check "SIGTERM mid-blink: exits 0" "$rc" "0"
check "SIGTERM mid-blink: the LED goes back to the EC" "$(<"$LEDDIR/trigger")" "chromeos-auto"
check "SIGTERM mid-blink: no note left" "$(ls "$T/out-term/run")" ""
sleep 0.2
if pgrep -f "$T/bin/gdbus" >/dev/null; then got=running; else got=gone; fi
check "SIGTERM mid-blink: gdbus is stopped too" "$got" "gone"

printf '%s\n' "$TRIGGERS" >"$LEDDIR/trigger"
start_held kill
kill -KILL "$wpid"
wait "$wpid" 2>/dev/null || true
pkill -f "$T/bin/gdbus" || true
check "SIGKILL mid-blink: the LED stays taken" "$(<"$LEDDIR/trigger")" "none"
check "SIGKILL mid-blink: and the note says so" "$(tr '\n' '|' <"$T/out-kill/run/taken")" "chromeos:white:power||"
printf '[none] kbd-capslock chromeos-auto\n' >"$LEDDIR/trigger"
RUNTIME_DIRECTORY="$T/out-kill/run" TPM_KEYRING_LED_SYSFS="$T/leds" bash "$WATCHER" --restore
check "--restore (ExecStopPost) gives it back, on the note's word" "$(<"$LEDDIR/trigger")" "chromeos-auto"
check "--restore: and the note is gone" "$(ls "$T/out-kill/run")" ""

# Without a note an LED at `trigger none` is its owner's setting.
printf '[none] kbd-capslock chromeos-auto\n' >"$LEDDIR/trigger"
touch -d '2000-01-01' "$LEDDIR/trigger"
RUNTIME_DIRECTORY="$T/out-kill/run" TPM_KEYRING_LED_SYSFS="$T/leds" bash "$WATCHER" --restore
check "--restore with no note leaves the LED unwritten" \
  "$(stat -c %Y "$LEDDIR/trigger")" "$(date -d '2000-01-01' +%s)"
TPM_KEYRING_LED_SYSFS="$T/leds" bash "$WATCHER" --restore
check "--restore with no runtime directory leaves it unwritten too" \
  "$(stat -c %Y "$LEDDIR/trigger")" "$(date -d '2000-01-01' +%s)"
# A note naming anything but a power-button LED is not acted on.
printf '../../etc\n\n' >"$T/out-kill/run/taken"
RUNTIME_DIRECTORY="$T/out-kill/run" TPM_KEYRING_LED_SYSFS="$T/leds" bash "$WATCHER" --restore
check "--restore ignores a note naming something else, and drops it" \
  "$(stat -c %Y "$LEDDIR/trigger"):$(ls "$T/out-kill/run")" "$(date -d '2000-01-01' +%s):"

# The next start acts on a note a killed watcher left, as ExecStopPost would.
rm -rf "$T/leds"
make_led chromeos:multicolor:power "red green blue yellow white amber" "0 0 0 0 100 0" \
  "[none] kbd-capslock chromeos-auto"
mkdir -p "$T/out-boot/run"
printf 'chromeos:multicolor:power\n100 0 0 0 0 0\n' >"$T/out-boot/run/taken"
cat >"$T/boot.sh" <<'EOF'
sleep 0.3; snap start
EOF
run_watcher boot chromeos:multicolor:power
check "startup gives back what a killed watcher noted, colours included" \
  "$(act boot start)|$(out boot start | cut -d'|' -f3)" "chromeos-auto|100 0 0 0 0 0"

rc=0
TPM_KEYRING_LED_SYSFS="$T/leds" bash "$WATCHER" --bogus 2>/dev/null || rc=$?
check "an unknown option is refused" "$rc" "2"

# --- framework_power_led(): who gets asked at all ---------------------------
# shellcheck source=../bin/lib.sh
source "$REPO_DIR/bin/lib.sh"
dmi() {
  mkdir -p "$T/dmi"
  printf '%s\n' "$1" >"$T/dmi/sys_vendor"
  printf '%s\n' "$2" >"$T/dmi/product_name"
}
led_offered() {
  if LED_SYSFS="$T/leds" DMI_DIR="$T/dmi" framework_power_led >"$T/led-path"; then
    cat "$T/led-path"
  else
    echo no
  fi
}
rm -rf "$T/leds"
make_led chromeos:white:power white 100
dmi Framework "Laptop 13 (AMD Ryzen AI 300 Series)"
check "Framework Laptop 13 with the power LED: offered" "$(led_offered)" "$T/leds/chromeos:white:power"
dmi Framework "Laptop (12th Gen Intel Core)"
check "the first Framework 13s are named 'Laptop' too: offered" "$(led_offered)" "$T/leds/chromeos:white:power"
dmi Framework "Laptop 16 (AMD Ryzen 7040 Series)"
check "Framework Laptop 16: offered" "$(led_offered)" "$T/leds/chromeos:white:power"
dmi Framework "Desktop (AMD Ryzen AI Max 300 Series)"
check "Framework Desktop (no reader in its button): not offered" "$(led_offered)" "no"
dmi Google "Pixelbook"
check "another cros_ec machine with the same LED: not offered" "$(led_offered)" "no"
rm -rf "$T/dmi"
check "no DMI data: not offered" "$(led_offered)" "no"
dmi Framework "Laptop 13 (AMD Ryzen AI 300 Series)"
rm -rf "$T/leds"
mkdir -p "$T/leds"
check "a Framework laptop without the LED (no leds_cros_ec): not offered" "$(led_offered)" "no"
make_led chromeos:white:power white 100 "none default [kbd-capslock]"
check "an LED the EC cannot take back: not offered" "$(led_offered)" "no"
rm -rf "$T/leds"
make_led chromeos:multicolor:power "red green blue yellow white amber" "100 0 0 0 0 0"
check "older Framework 13, multicolour LED: offered" "$(led_offered)" "$T/leds/chromeos:multicolor:power"

# --- the files install.sh installs -------------------------------------------
RULE_SRC="$REPO_DIR/led/90-tpm-keyring-led.rules"
UNIT_SRC="$REPO_DIR/led/tpm-keyring-led.service"
SYSUSERS_SRC="$REPO_DIR/led/tpm-keyring-led.sysusers"
# The LED names and attributes live in three files that cannot read each
# other: the watcher, the udev rule, and bin/lib.sh. Held together here.
check "the watcher looks for the LEDs bin/lib.sh names" \
  "$(sed -n 's/^LED_CANDIDATES=(\(.*\))$/\1/p' "$WATCHER")" "${LED_SYSFS_NAMES[*]}"
check "the udev rule matches the LEDs bin/lib.sh names" \
  "$(sed -n 's/.*KERNEL=="\([^"]*\)".*/\1/p' "$RULE_SRC")" "$(IFS='|'; echo "${LED_SYSFS_NAMES[*]}")"
check "the udev rule hands over the attributes bin/lib.sh names" \
  "$(sed -n 's/.*for a in \([a-z_ ]*\); do.*/\1/p' "$RULE_SRC")" "${LED_ATTRS[*]}"
check "the udev rule runs on add only, not on every trigger write" \
  "$(grep -o 'ACTION=="[^"]*"' "$RULE_SRC")" 'ACTION=="add"'
for f in "$UNIT_SRC" "$RULE_SRC" "$SYSUSERS_SRC"; do
  check "${f##*/} starts with the marker uninstall.sh knows it by" "$(head -n1 "$f")" "$LED_FILE_MARKER"
done
led_unit_render "$UNIT_SRC" /usr/local/sbin/tpm-keyring-led >"$T/unit"
check "rendered unit: starts the watcher" "$(sed -n 's/^ExecStart=//p' "$T/unit")" "/usr/local/sbin/tpm-keyring-led"
check "rendered unit: its ExecStopPost restores the LED, and may fail" \
  "$(sed -n 's/^ExecStopPost=//p' "$T/unit")" "-/usr/local/sbin/tpm-keyring-led --restore"
check "rendered unit: gives the watcher a runtime directory for its note" \
  "$(sed -n 's/^RuntimeDirectory=//p' "$T/unit")" "tpm-keyring-led"
check "rendered unit: the note outlives a kill of the whole cgroup, until reboot" \
  "$(sed -n 's/^RuntimeDirectoryPreserve=//p' "$T/unit")" "yes"
check "rendered unit: skipped when the watcher is gone" \
  "$(sed -n 's/^ConditionPathExists=//p' "$T/unit")" "/usr/local/sbin/tpm-keyring-led"
check "rendered unit: a failing watcher stops restarting (limit reachable at RestartSec=2)" \
  "$(sed -n 's/^StartLimitIntervalSec=//p; s/^StartLimitBurst=//p' "$T/unit" | tr '\n' ' ')" "120 10 "
check "rendered unit: no placeholder left" "$(grep -c '@LED_BIN@' "$T/unit" || true)" "0"
check "rendered unit: the packaged watcher's path works too" \
  "$(led_unit_render "$UNIT_SRC" /usr/libexec/tpm-keyring-unlock/tpm-keyring-led | sed -n 's/^ExecStart=//p')" \
  "/usr/libexec/tpm-keyring-unlock/tpm-keyring-led"
for bad in relative/tpm-keyring-led "/opt/with space/x" '/opt/a|b' '/opt/a&b' '/opt/$x' ''; do
  if led_unit_render "$UNIT_SRC" "$bad" >/dev/null 2>&1; then got=rendered; else got=refused; fi
  check "rendered unit: refuses the path '$bad'" "$got" "refused"
done
check "the unit's group is the one the sysusers file creates" \
  "$(sed -n 's/^SupplementaryGroups=//p' "$UNIT_SRC")" "$(awk '$1 == "g" { print $2 }' "$SYSUSERS_SRC")"
check "and the one lib.sh names" "$LED_GROUP" "$(awk '$1 == "g" { print $2 }' "$SYSUSERS_SRC")"
# ProtectKernelTunables=yes makes /sys read-only, and the LED lives there.
if grep -q '^ProtectKernelTunables=yes' "$UNIT_SRC"; then got=yes; else got=no; fi
check "the unit does not make /sys read-only" "$got" "no"

# /etc/passwd, not a program: /usr/bin/env is a symlink on Ubuntu 26.04
# (rust coreutils), which the check rightly refuses.
if led_path_is_roots_alone /etc/passwd; then got=yes; else got=no; fi
check "a root-owned file under root-owned directories is root's alone" "$got" "yes"
touch "$T/mine"
if led_path_is_roots_alone "$T/mine"; then got=yes; else got=no; fi
check "a file this account owns is not" "$got" "no"
ln -s /usr/bin/env "$T/link"
if led_path_is_roots_alone "$T/link"; then got=yes; else got=no; fi
check "a symlink, even to a root file, is not" "$got" "no"

# --- install, update, rollback, removal (bin/lib.sh), with stubs ------------
# Run in a subshell: the stubs are functions and PATH entries that must not
# outlive this block. /etc lives under $E, without a sysusers.d. The LED
# group is this account's own, so the stub udevadm can hand it the LED.
E="$T/sys"
mkdir -p "$E/bin"
cat >"$E/bin/install" <<'EOF'
#!/usr/bin/env bash
# install without -o/-g, which only root may use
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in -o | -g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
EOF
cat >"$E/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$E/calls"
case "$*" in
  *MainPID*)
    if [ "${STUB_MODE:-}" = crashloop ]; then
      n="$(cat "$E/pid" 2>/dev/null || echo 100)"; echo $((n + 1)) >"$E/pid"; echo "$n"
    else
      echo 4242
    fi ;;
  *ExecMainStartTimestamp*) echo "${STARTED:-}" ;;
  *is-enabled*) exit "${ENABLED_RC:-0}" ;;
  *is-active*) exit "${ACTIVE_RC:-0}" ;;
esac
exit 0
EOF
cat >"$E/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
echo "udevadm $*" >>"$E/calls"
if [ "$1" = trigger ] && [ "${STUB_MODE:-}" != noudev ]; then
  d="${*: -1}"
  for a in trigger brightness multi_intensity; do
    [ -e "$d/$a" ] && chgrp "$(id -gn)" "$d/$a" && chmod g+w "$d/$a"
  done
fi
exit 0
EOF
for c in systemd-sysusers groupdel restorecon; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$E/calls"\n' "$c" >"$E/bin/$c"
done
chmod +x "$E/bin"/*

(
  export E PATH="$E/bin:$PATH" LED_SYSFS="$T/leds" DMI_DIR="$T/dmi"
  export STUB_MODE STARTED ENABLED_RC ACTIVE_RC
  LED_UNIT="$E/etc/systemd/system/tpm-keyring-led.service"
  LED_RULE="$E/etc/udev/rules.d/90-tpm-keyring-led.rules"
  LED_SYSUSERS="$E/etc/sysusers.d/tpm-keyring-led.conf"
  LED_SRC_DIR="$REPO_DIR/led"
  LED_BIN="$E/sbin/tpm-keyring-led"
  LED_WATCHER_SRC="$WATCHER"
  LED_GROUP="$(id -gn)"
  sudo() { "$@"; }
  sleep() { :; }
  # Whether a group by LED_GROUP's name exists, as the scenario says.
  getent() { [ -n "${GROUP_EXISTS:-}" ]; }
  fresh() {
    rm -rf "$E/etc" "$E/sbin" "$E/calls" "$E/pid"
    mkdir -p "$E/etc/systemd/system" "$E/etc/udev/rules.d" "$E/sbin"
    rm -rf "$T/leds"
    make_led chromeos:white:power white 100
    STUB_MODE="" STARTED="" ENABLED_RC=0 ACTIVE_RC=0 GROUP_EXISTS=""
  }
  attr_mode() { stat -c %a "$T/leds/chromeos:white:power/trigger"; }
  ran() { if grep -qF -- "$1" "$E/calls" 2>/dev/null; then echo yes; else echo no; fi; }

  fresh
  rc=0
  led_service_install install >"$E/out" 2>&1 || rc=$?
  check "install: succeeds where /etc/sysusers.d does not exist yet" "$rc" "0"
  check "install: creates /etc/sysusers.d" "$(stat -c %a "$E/etc/sysusers.d" 2>/dev/null || echo missing)" "755"
  check "install: unit, rule and sysusers file are this tool's" \
    "$(led_file_is_ours "$LED_UNIT" && led_file_is_ours "$LED_RULE" && led_file_is_ours "$LED_SYSUSERS" && echo yes || echo no)" "yes"
  check "install: copies the watcher" "$(cmp -s "$WATCHER" "$LED_BIN" && echo same || echo differs)" "same"
  check "install: applies the rule with an add event" "$(ran "udevadm trigger --action=add $T/leds/chromeos:white:power")" "yes"
  check "install: the LED is writable by the group" "$(attr_mode)" "664"
  check "install: enables and starts the service" \
    "$(ran 'systemctl enable --quiet tpm-keyring-led.service'):$(ran 'systemctl restart tpm-keyring-led.service')" "yes:yes"
  check "install: says how to switch it off without uninstall.sh" \
    "$(grep -c 'systemctl disable --now tpm-keyring-led' "$E/out")" "1"

  STARTED="@$(date +%s)"
  if led_service_up_to_date; then got=yes; else got=no; fi
  check "up to date: right after the install" "$got" "yes"
  STARTED="@1"
  if led_service_up_to_date; then got=yes; else got=no; fi
  check "not up to date: the running watcher is older than the file (package update)" "$got" "no"
  STARTED=""
  if led_service_up_to_date; then got=yes; else got=no; fi
  check "up to date: a stopped service has no running watcher to be stale" "$got" "yes"
  echo '# changed' >>"$LED_RULE"
  if led_service_up_to_date; then got=yes; else got=no; fi
  check "not up to date: a file differs" "$got" "no"

  # A failed update goes back to the earlier files and restarts the service.
  : >"$E/calls"
  before="$(sha256sum "$LED_RULE" "$LED_UNIT" "$LED_SYSUSERS" "$LED_BIN")"
  STUB_MODE=crashloop
  rc=0
  led_service_install refresh >"$E/out" 2>&1 || rc=$?
  check "failed update: reported as a failure" "$rc" "1"
  check "failed update: the earlier files are back, byte for byte" \
    "$(sha256sum "$LED_RULE" "$LED_UNIT" "$LED_SYSUSERS" "$LED_BIN")" "$before"
  check "failed update: the earlier service is started again" \
    "$(grep -c 'systemctl restart tpm-keyring-led.service' "$E/calls")" "2"
  check "failed update: the group is kept" "$(ran groupdel)" "no"
  check "failed update: the LED stays writable by the group" "$(attr_mode)" "664"
  STUB_MODE=""

  : >"$E/calls"
  ENABLED_RC=1
  rc=0
  led_service_install refresh >"$E/out" 2>&1 || rc=$?
  check "update of a disabled service: succeeds" "$rc" "0"
  check "update of a disabled service: it stays disabled" \
    "$(ran 'systemctl enable'):$(ran 'systemctl restart')" "no:no"
  ENABLED_RC=0

  # Removal takes only what carries the marker; the group only when the
  # sysusers file did.
  printf '# somebody else'"'"'s rule\n' >"$LED_RULE"
  : >"$E/calls"
  GROUP_EXISTS=1
  led_service_remove
  check "remove: the unit and the sysusers file go" \
    "$([ -e "$LED_UNIT" ] || [ -e "$LED_SYSUSERS" ] && echo left || echo gone)" "gone"
  check "remove: a rule by the same name that is not this tool's stays" "$(head -n1 "$LED_RULE")" "# somebody else's rule"
  check "remove: the LED loses group write" "$(attr_mode)" "644"
  check "remove: the group it created goes" "$(ran groupdel)" "yes"
  check "remove: the kept runtime directory is cleaned" "$(ran 'systemctl clean --what=runtime tpm-keyring-led.service')" "yes"
  check "remove: never writes the LED's trigger" "$(<"$T/leds/chromeos:white:power/trigger")" "$TRIGGERS"

  # A fresh install that fails is taken out whole, the directory it made too.
  fresh
  STUB_MODE=noudev
  rc=0
  led_service_install install >"$E/out" 2>&1 || rc=$?
  check "failed install: reported as a failure" "$rc" "1"
  check "failed install: nothing of it is left" \
    "$(find "$E/etc" "$E/sbin" -type f | wc -l | tr -d ' ')" "0"
  check "failed install: the sysusers.d it created is gone again" \
    "$([ -e "$E/etc/sysusers.d" ] && echo left || echo gone)" "gone"
  check "failed install: the LED keeps its own mode" "$(attr_mode)" "644"

  # State by this tool's names that is not this tool's.
  fresh
  printf '[Unit]\nDescription=somebody else\n' >"$LED_UNIT"
  if reason="$(led_install_conflict)"; then got="$reason"; else got=none; fi
  check "conflict: a unit by the name without the marker" "$got" "$LED_UNIT is there already, and is not this tool's"
  before="$(sha256sum "$LED_UNIT")"
  rc=0
  led_service_install install >"$E/out" 2>&1 || rc=$?
  check "conflict: the install refuses" "$rc" "1"
  check "conflict: and leaves the unit alone" "$(sha256sum "$LED_UNIT")" "$before"
  check "conflict: and writes nothing else" "$([ -e "$LED_RULE" ] || [ -e "$LED_BIN" ] && echo wrote || echo nothing)" "nothing"
  fresh
  GROUP_EXISTS=1
  if reason="$(led_install_conflict)"; then got="$reason"; else got=none; fi
  check "conflict: a group by the name that this tool did not create" \
    "$got" "a group named $LED_GROUP exists already, and is not this tool's"

  # A package's watcher: run where it lies, so it has to be root's alone.
  fresh
  LED_WATCHER_SRC=""
  cp "$WATCHER" "$LED_BIN"
  rc=0
  led_service_install install >"$E/out" 2>&1 || rc=$?
  check "packaged watcher this account could replace: refused" "$rc" "1"
  check "packaged watcher this account could replace: nothing written" \
    "$([ -e "$LED_UNIT" ] && echo wrote || echo nothing)" "nothing"
  exit "$fail"
) || fail=1

exit "$fail"

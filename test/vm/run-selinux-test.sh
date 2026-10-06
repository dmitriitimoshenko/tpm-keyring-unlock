#!/usr/bin/env bash
# VM test for an SELinux distribution: Fedora's cloud image, SELinux enforcing
# as it ships, a swtpm TPM 2.0 behind OVMF with Secure Boot on. It covers what
# test/vm/run-vm-test.sh structurally cannot on Ubuntu (GitHub issue #23):
#
# - install.sh on the stock Fedora 44 gdm PAM files: gdm-fingerprint, which has
#   no keyring line of its own, gets the keyring lines with ours, and the
#   SELinux policy module is planned and loaded;
# - the helper reached from a PAM stack that runs as xdm_t, the domain GDM's
#   session worker runs in - set up the way systemd starts gdm itself, by
#   executing a file labelled xdm_exec_t. With the module the real
#   gdm-fingerprint stack sets PAM_AUTHTOK; without it the helper names its
#   own SELinux context in the journal, as GDM's journal stream would carry it;
# - a lock directory a `sudo` run created first (var_run_t) no longer stops
#   those runs;
# - a second install.sh run plans the module again once it is gone, and finds
#   the stacks already wired;
# - uninstall.sh puts gdm-fingerprint back byte for byte and removes the module;
# - and, with no pre-install copy to prove the keyring lines are its own, takes
#   out only its own line.
#
# The finger is pam_flow_stub standing in for pam_fprintd, which needs a
# reader. Everything else on the auth path is real: libpam, the authselect
# fingerprint-auth, our module, the helper, tpm2-tools, pam_gnome_keyring.
#
# Opt-in (`make test-vm-selinux`), like run-vm-test.sh: KVM, swtpm, OVMF and a
# ~580 MB image fetched once and cached. Not in CI yet.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=""
PIDS=()
FAIL=0

# Same reasons as in run-vm-test.sh: qemu daemonizes away from this shell, so
# `wait` proves nothing, and only polling the PID does.
stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill "$pid" >/dev/null 2>&1 || return 0
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && stop_pid "$pid"
  done
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

check() {
  local desc="$1" got="$2" want="$3" errfile="${4:-}"
  if [ "$got" = "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (got: $got, want: $want)"
    if [ -n "$errfile" ] && [ -s "$errfile" ]; then
      echo "  -- $errfile: --"
      sed 's/^/  | /' "$errfile"
    fi
    FAIL=1
  fi
}

# --- preflight: a clean SKIPPED (exit 0) when the host cannot run it --------
MISSING=()
for bin in qemu-system-x86_64 qemu-img swtpm ssh ssh-keygen scp curl python3 sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Missing tools, skipping the SELinux VM test: ${MISSING[*]}" >&2
  exit 0
fi
if [ ! -e /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "No usable /dev/kvm - skipping the SELinux VM test." >&2
  exit 0
fi
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS_ON=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
for f in "$OVMF_CODE" "$OVMF_VARS_ON"; do
  if [ ! -f "$f" ]; then
    echo "Missing OVMF firmware file: $f - skipping. (sudo apt install ovmf)" >&2
    exit 0
  fi
done

# mktemp's short /tmp path on purpose: the swtpm socket lives in here, and a
# UNIX socket path must stay under 108 bytes.
WORK=$(mktemp -d)

# --- the base image: fetched once, checked against Fedora's published
# CHECKSUM file on every run ---------------------------------------------------
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tpm-keyring-unlock-vm-test"
FEDORA_RELEASE="${FEDORA_RELEASE:-44}"
FEDORA_COMPOSE="${FEDORA_COMPOSE:-1.7}"
IMG_NAME="Fedora-Cloud-Base-Generic-$FEDORA_RELEASE-$FEDORA_COMPOSE.x86_64.qcow2"
IMG_BASE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/$FEDORA_RELEASE/Cloud/x86_64/images"
SUMS_NAME="Fedora-Cloud-$FEDORA_RELEASE-$FEDORA_COMPOSE-x86_64-CHECKSUM"
BASE_IMG="$CACHE_DIR/$IMG_NAME"

mkdir -p "$CACHE_DIR"
echo "-- checking the cached Fedora image against the published checksum --"
EXPECTED_SHA="$(curl -fsSL --max-time 30 "$IMG_BASE_URL/$SUMS_NAME" \
  | sed -n "s/^SHA256 ($IMG_NAME) = \([0-9a-f]\{64\}\)$/\1/p")"
if [ -z "$EXPECTED_SHA" ]; then
  echo "Couldn't fetch/parse $SUMS_NAME - skipping (no network?)." >&2
  exit 0
fi
if [ ! -f "$BASE_IMG" ] || ! echo "$EXPECTED_SHA  $BASE_IMG" | sha256sum -c - >/dev/null 2>&1; then
  echo "-- downloading $IMG_NAME (~580 MB, cached at $CACHE_DIR after this) --"
  curl -fL --max-time 1200 -o "$BASE_IMG.tmp" "$IMG_BASE_URL/$IMG_NAME"
  if ! echo "$EXPECTED_SHA  $BASE_IMG.tmp" | sha256sum -c - >/dev/null 2>&1; then
    echo "Downloaded image failed checksum verification - aborting." >&2
    rm -f "$BASE_IMG.tmp"
    exit 1
  fi
  mv "$BASE_IMG.tmp" "$BASE_IMG"
else
  echo "ok   - cached image matches the published checksum"
fi

pick_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}

ssh-keygen -t ed25519 -N "" -f "$WORK/id_test" -q
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes
  -o ConnectTimeout=5 -o LogLevel=ERROR)
SSHPORT=$(pick_free_port)
HTTPPORT=$(pick_free_port)
vm_ssh() { ssh "${SSH_OPTS[@]}" -i "$WORK/id_test" -p "$SSHPORT" fedora@127.0.0.1 "$@"; }
vm_scp() { scp -q "${SSH_OPTS[@]}" -i "$WORK/id_test" -P "$SSHPORT" "$@"; }
VM_TTY_TIMEOUT="${VM_TTY_TIMEOUT:-420}"
# Answers each prompt only once it has appeared - see test/vm/pty-drive.py.
vm_drive() {
  local logfile="$1" cmd="$2"
  shift 2
  local expects=() e
  for e in "$@"; do expects+=(--expect "$e"); done
  python3 "$REPO_DIR/test/vm/pty-drive.py" \
    --timeout "$VM_TTY_TIMEOUT" --log "$logfile" "${expects[@]}" \
    -- ssh "${SSH_OPTS[@]}" -tt -i "$WORK/id_test" -p "$SSHPORT" fedora@127.0.0.1 "$cmd"
}

# --- boot -------------------------------------------------------------------
mkdir -p "$WORK/seed" "$WORK/tpmstate"
cat >"$WORK/seed/meta-data" <<EOF
instance-id: tpm-keyring-unlock-selinux-test-$$
local-hostname: f$FEDORA_RELEASE
EOF
# gnome-keyring-pam because install.sh names pam_gnome_keyring.so in the
# lines it adds, and checks the module is there first. The rest is what
# install.sh would dnf-install itself, plus pamtester and auditd for the checks.
cat >"$WORK/seed/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$WORK/id_test.pub")
packages:
  - tpm2-tools
  - gcc
  - make
  - pam-devel
  - pamtester
  - mokutil
  - gnome-keyring-pam
  - audit
EOF
( cd "$WORK/seed" && exec python3 -m http.server "$HTTPPORT" --bind 0.0.0.0 >/dev/null 2>&1 ) &
PIDS+=("$!")
swtpm socket --tpm2 --tpmstate "dir=$WORK/tpmstate" \
  --ctrl "type=unixio,path=$WORK/tpm.sock" --log level=1 >"$WORK/swtpm.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 50); do [ -S "$WORK/tpm.sock" ] && break; sleep 0.1; done
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$WORK/disk.qcow2" 20G >/dev/null
cp "$OVMF_VARS_ON" "$WORK/vars.fd"
qemu-system-x86_64 \
  -M q35 -accel kvm -cpu host -m 3072 -smp 2 \
  -display none -monitor none -serial "file:$WORK/console.log" \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
  -drive "if=virtio,file=$WORK/disk.qcow2,format=qcow2" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSHPORT}-:22" -device virtio-net-pci,netdev=n0 \
  -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:${HTTPPORT}/" \
  -chardev "socket,id=chrtpm,path=$WORK/tpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
  -pidfile "$WORK/qemu.pid" -daemonize >"$WORK/qemu.log" 2>&1
PIDS+=("$(cat "$WORK/qemu.pid" 2>/dev/null)")

echo "-- waiting for the VM --"
up=0
for _ in $(seq 1 80); do
  if vm_ssh true >/dev/null 2>&1; then up=1; break; fi
  sleep 3
done
if [ "$up" = 0 ]; then
  check "the Fedora VM is reachable over SSH" unreachable reachable "$WORK/console.log"
  exit 1
fi
vm_ssh 'sudo cloud-init status --wait' >/dev/null 2>&1 || true

check "SELinux is enforcing, as Fedora ships it" "$(vm_ssh getenforce 2>/dev/null)" "Enforcing"
check "Secure Boot is on" \
  "$(vm_ssh 'mokutil --sb-state 2>/dev/null | grep -c "SecureBoot enabled"')" "1"
check "the TPM is there, labelled as the policy expects" \
  "$(vm_ssh 'stat -c %C /dev/tpmrm0' 2>/dev/null)" "system_u:object_r:tpm_device_t:s0"

# --- the machine: Fedora 44's gdm stacks, and a finger that always matches -----
vm_ssh 'mkdir -p ~/tpm-keyring-unlock/test/fixtures/pam.d ~/tpm-keyring-unlock/test/fixtures/expected'
vm_scp -r "$REPO_DIR/bin" "$REPO_DIR/pam" "$REPO_DIR/selinux" "$REPO_DIR/install.sh" \
  "$REPO_DIR/uninstall.sh" fedora@127.0.0.1:tpm-keyring-unlock/
vm_scp "$REPO_DIR/test/fixtures/pam_flow_stub.c" fedora@127.0.0.1:tpm-keyring-unlock/test/fixtures/
vm_scp -r "$REPO_DIR/test/fixtures/pam.d/fedora44" fedora@127.0.0.1:tpm-keyring-unlock/test/fixtures/pam.d/
vm_scp "$REPO_DIR/test/fixtures/expected/fedora44-gdm-fingerprint" \
  fedora@127.0.0.1:tpm-keyring-unlock/test/fixtures/expected/

# A cloud image has no gdm, so its PAM files come from the fixture tree - the
# files gdm-50.3-1.fc44 installs, which reach the VM's own authselect files.
# with-fingerprint is what Fedora Workstation runs, and what puts pam_fprintd
# into fingerprint-auth. The stand-in for pam_fprintd returns PAM_SUCCESS; it
# has no max-tries= in it, so install.sh offers no attempt stack here.
vm_ssh 'set -e
  cd ~/tpm-keyring-unlock
  for f in gdm-autologin gdm-fingerprint gdm-launch-environment gdm-password gdm-smartcard gdm-switchable-auth; do
    sudo install -m 0644 test/fixtures/pam.d/fedora44/$f /etc/pam.d/$f
  done
  sudo restorecon /etc/pam.d/gdm-*
  cp /etc/pam.d/gdm-fingerprint /tmp/gdm-fingerprint.orig
  stat -c %C /etc/pam.d/gdm-fingerprint >/tmp/gdm-fingerprint.label
  cp /etc/pam.d/gdm-password /tmp/gdm-password.orig
  sudo authselect enable-feature with-fingerprint >/dev/null
  gcc -Wall -Wextra -fPIC -shared -o /tmp/pam_fprintd.so test/fixtures/pam_flow_stub.c -lpam
  sudo install -m 0755 /tmp/pam_fprintd.so /usr/lib64/security/pam_fprintd.so
  sudo restorecon /usr/lib64/security/pam_fprintd.so' >"$WORK/setup.out" 2>&1
check "the Fedora 44 gdm stacks and the stand-in finger are in place" "$?" "0" "$WORK/setup.out"

# Runs a PAM service the way gdm-session-worker does: as xdm_t, with stdout
# and stderr on a journal stream named gdm-session-worker (gdm's
# session_worker_job_setup_journal_fds). systemd executing a file labelled
# xdm_exec_t transitions to xdm_t - the rule that puts /usr/sbin/gdm there.
vm_ssh 'set -e
  sudo install -m 0755 /usr/bin/pamtester /usr/local/libexec/tku-pamtester-xdm
  sudo install -m 0755 /usr/bin/bash /usr/local/libexec/tku-bash-xdm
  sudo chcon -t xdm_exec_t /usr/local/libexec/tku-pamtester-xdm /usr/local/libexec/tku-bash-xdm' \
  >"$WORK/harness.out" 2>&1
check "the xdm_t harness is in place" "$?" "0" "$WORK/harness.out"
# --pipe hands systemd this command's own descriptors over D-Bus, and the
# policy lets dbus-broker take a pipe made in the shell's domain but not one
# made by sshd ("Connection reset by peer"), hence the shell's own pipe.
check "...and really runs as xdm_t" \
  "$(vm_ssh 'sudo systemd-run --wait --pipe --quiet /usr/local/libexec/tku-bash-xdm -c "id -Z" </dev/null 2>&1 | cat' 2>/dev/null)" \
  "system_u:system_r:xdm_t:s0-s0:c0.c1023"

# Prints "<pamtester status> <unseal outcome> <AVC count>" for one run of
# gdm-fingerprint as xdm_t, and leaves its journal and AVCs in $WORK/$1.*.
xdm_run() {
  local tag="$1"
  vm_ssh 'n=$(sudo sh -c "wc -l </var/log/audit/audit.log"); since=$(date +%s); sleep 1
    sudo systemd-run --wait --quiet -p SyslogIdentifier=gdm-session-worker \
      -p StandardOutput=journal -p StandardError=journal \
      /usr/local/libexec/tku-pamtester-xdm gdm-fingerprint fedora authenticate; rc=$?
    sleep 1
    sudo journalctl --since "@$since" --no-pager -o cat >/tmp/xdm.journal 2>/dev/null
    sudo sh -c "tail -n +$((n + 1)) /var/log/audit/audit.log" | grep "type=AVC" >/tmp/xdm.avc || true
    if grep -q "TPM keyring unseal succeeded for user fedora, PAM_AUTHTOK set" /tmp/xdm.journal; then
      u=unsealed
    else
      u=not-unsealed
    fi
    echo "$rc $u $(wc -l </tmp/xdm.avc)"' 2>/dev/null
  vm_ssh 'cat /tmp/xdm.journal' >"$WORK/$tag.journal" 2>/dev/null
  vm_ssh 'cat /tmp/xdm.avc' >"$WORK/$tag.avc" 2>/dev/null
}

# --- install.sh, end to end ---------------------------------------------------
echo
echo "-- install.sh on Fedora $FEDORA_RELEASE, SELinux enforcing --"
SECRET="vm-selinux-secret-$(date +%s)"
vm_drive "$WORK/install.out" 'cd ~/tpm-keyring-unlock && ./install.sh' \
  'Proceed with all of the above\? \[Y/n\] =' \
  "Password to seal[^:]*: =$SECRET" \
  "Confirm: =$SECRET"
check "install.sh completes a full run" "$?" "0" "$WORK/install.out"
check "the plan offered the SELinux module" \
  "$(grep -c 'Load the SELinux module tpm_keyring_unlock' "$WORK/install.out")" "1" "$WORK/install.out"
check "the plan offered gdm-fingerprint the keyring lines" \
  "$(grep -c 'Give gdm-fingerprint the keyring lines' "$WORK/install.out")" "1" "$WORK/install.out"
check "gdm-fingerprint is exactly what the fixture expects" \
  "$(vm_ssh 'cmp -s /etc/pam.d/gdm-fingerprint ~/tpm-keyring-unlock/test/fixtures/expected/fedora44-gdm-fingerprint && echo identical || echo differs')" \
  "identical" "$WORK/install.out"
check "...with its SELinux label kept" \
  "$(vm_ssh '[ "$(stat -c %C /etc/pam.d/gdm-fingerprint)" = "$(cat /tmp/gdm-fingerprint.label)" ] && echo kept || echo changed')" \
  "kept"
check "nothing was refused" "$(grep -c 'NOT wiring' "$WORK/install.out")" "0" "$WORK/install.out"
check "the backup holds the stock file byte for byte" \
  "$(vm_ssh 'b=$(ls /etc/pam.d/gdm-fingerprint.bak-* 2>/dev/null | head -1); [ -n "$b" ] && cmp -s "$b" /tmp/gdm-fingerprint.orig && echo identical || echo differs')" \
  "identical"
check "gdm-password is wired the ordinary way, our line above its keyring line" \
  "$(vm_ssh 'awk "/pam_tpm_keyring_authtok\.so/{f=NR} /^auth.*pam_gnome_keyring\.so/{if (f && NR==f+1) print \"adjacent\"}" /etc/pam.d/gdm-password')" \
  "adjacent"
check "the module is loaded" \
  "$(vm_ssh 'sudo semodule -l | grep -cx tpm_keyring_unlock')" "1"
# Last, once a stack is wired: a run that stops early must not leave all of
# xdm_t able to open the TPM for nothing (review of PR #24).
check "...after the PAM stacks are wired, not before" \
  "$(awk '/^-- Login PAM stacks --/ { p = NR } /^-- SELinux --/ { s = NR }
      END { print (p && s > p) ? "after" : "before" }' "$WORK/install.out")" \
  "after" "$WORK/install.out"
check "the kernel now lets xdm_t open the TPM" \
  "$(vm_ssh 'source ~/tpm-keyring-unlock/bin/lib.sh; selinux_domain_may_use_tpm; echo $?')" "0"

# --- the helper from GDM's domain ---------------------------------------------
echo
echo "-- gdm-fingerprint as xdm_t --"
# What README's troubleshooting suggests, run first, so the lock directory is
# made by unconfined_t and labelled var_run_t: until the helper locked the
# directory itself, xdm_t could not write the lock file in it, and every GDM
# login failed until the next reboot.
vm_ssh 'sudo rm -rf /run/tpm-keyring-unlock; sudo /usr/local/sbin/tpm-keyring-unseal fedora >/dev/null' 2>/dev/null
check "(a sudo run left a var_run_t lock directory behind)" \
  "$(vm_ssh 'sudo stat -c %C /run/tpm-keyring-unlock' 2>/dev/null)" \
  "unconfined_u:object_r:var_run_t:s0"
read -r RC UNSEAL AVCS <<<"$(xdm_run with-module)"
check "the stand-in finger matches, so gdm-fingerprint authenticates" "$RC" "0" "$WORK/with-module.journal"
check "the helper unseals from xdm_t and PAM_AUTHTOK is set" "$UNSEAL" "unsealed" "$WORK/with-module.journal"
check "no AVC denial on the way" "$AVCS" "0" "$WORK/with-module.avc"
check "pam_gnome_keyring got the token" \
  "$(grep -c 'gkr-pam: stashed password' "$WORK/with-module.journal")" "1" "$WORK/with-module.journal"

# --- the same without the module: the issue as reported, and what the helper
# says about it now ------------------------------------------------------------
vm_ssh 'sudo semodule -r tpm_keyring_unlock' >/dev/null 2>&1
read -r RC UNSEAL AVCS <<<"$(xdm_run without-module)"
check "without the module, login itself is unaffected" "$RC" "0" "$WORK/without-module.journal"
check "...but nothing is unsealed" "$UNSEAL" "not-unsealed" "$WORK/without-module.journal"
check "...the denial is on the TPM device" \
  "$(grep -c 'denied  { read write } .*scontext=system_u:system_r:xdm_t.*tcontext=system_u:object_r:tpm_device_t' "$WORK/without-module.avc")" \
  "1" "$WORK/without-module.avc"
check "...and the helper names its SELinux context instead of blaming the primary" \
  "$(grep -c 'tpm-keyring-unseal: cannot open /dev/tpmrm0 (Permission denied) as system_u:system_r:xdm_t:s0-s0:c0.c1023' "$WORK/without-module.journal")" \
  "1" "$WORK/without-module.journal"
check "...and does not claim the primary was evicted" \
  "$(grep -c 'has been evicted' "$WORK/without-module.journal")" "0" "$WORK/without-module.journal"

# --- a second run: the module planned again, the stacks left as they are -----
echo
echo "-- install.sh, second run --"
vm_drive "$WORK/install2.out" 'cd ~/tpm-keyring-unlock && ./install.sh' \
  'Proceed with all of the above\? \[Y/n\] =' \
  'Overwrite\? \[Y/n\] =n'
check "the second run completes" "$?" "0" "$WORK/install2.out"
check "it plans the module again, the kernel having said no" \
  "$(grep -c 'Load the SELinux module tpm_keyring_unlock' "$WORK/install2.out")" "1" "$WORK/install2.out"
check "it calls gdm-fingerprint already wired" \
  "$(grep -c 'gdm-fingerprint: already wired in' "$WORK/install2.out")" "1" "$WORK/install2.out"
check "gdm-fingerprint is unchanged" \
  "$(vm_ssh 'cmp -s /etc/pam.d/gdm-fingerprint ~/tpm-keyring-unlock/test/fixtures/expected/fedora44-gdm-fingerprint && echo identical || echo differs')" \
  "identical" "$WORK/install2.out"
read -r RC UNSEAL AVCS <<<"$(xdm_run reloaded)"
check "with the module back, xdm_t unseals again" "$UNSEAL $AVCS" "unsealed 0" "$WORK/reloaded.journal"

# --- uninstall.sh ---------------------------------------------------------------
echo
echo "-- uninstall.sh --"
vm_drive "$WORK/uninstall.out" 'cd ~/tpm-keyring-unlock && ./uninstall.sh' '*\[Y/n\] ='
check "uninstall.sh completes a full run" "$?" "0" "$WORK/uninstall.out"
check "gdm-fingerprint is back to the stock file byte for byte" \
  "$(vm_ssh 'cmp -s /etc/pam.d/gdm-fingerprint /tmp/gdm-fingerprint.orig && echo identical || echo differs')" \
  "identical" "$WORK/uninstall.out"
check "...restored from the exact pre-install copy" \
  "$(grep -c 'Restored exactly, from /etc/pam.d/gdm-fingerprint.bak-' "$WORK/uninstall.out")" "1" "$WORK/uninstall.out"
check "gdm-password is back byte for byte" \
  "$(vm_ssh 'cmp -s /etc/pam.d/gdm-password /tmp/gdm-password.orig && echo identical || echo differs')" \
  "identical" "$WORK/uninstall.out"
check "the SELinux module is gone" \
  "$(vm_ssh 'sudo semodule -l | grep -cx tpm_keyring_unlock')" "0" "$WORK/uninstall.out"
check "...and xdm_t may not open the TPM again" \
  "$(vm_ssh 'source ~/tpm-keyring-unlock/bin/lib.sh; selinux_domain_may_use_tpm; echo $?')" "1"

# --- keyring lines nothing proves are this tool's ------------------------------
# The same three lines, but with no pre-install copy beside the file: written
# by hand from README, say, and wired by install.sh the ordinary way. The
# shape alone cannot tell them from install.sh's, so uninstall.sh takes out
# only its own line and says why the other two stay (review of PR #24).
echo
echo "-- uninstall.sh, keyring lines without a pre-install copy --"
vm_ssh 'sudo rm -f /etc/pam.d/gdm-fingerprint.bak-*
  sudo cp ~/tpm-keyring-unlock/test/fixtures/expected/fedora44-gdm-fingerprint /etc/pam.d/gdm-fingerprint
  sudo restorecon /etc/pam.d/gdm-fingerprint' >/dev/null 2>&1
vm_drive "$WORK/uninstall2.out" 'cd ~/tpm-keyring-unlock && ./uninstall.sh' '*\[Y/n\] ='
check "uninstall.sh completes again" "$?" "0" "$WORK/uninstall2.out"
check "it says no pre-install copy proves the keyring lines are its own" \
  "$(grep -c 'no pre-install copy (.bak-\*) proves this tool put them there' "$WORK/uninstall2.out")" \
  "1" "$WORK/uninstall2.out"
check "...takes its own line out" \
  "$(vm_ssh 'grep -c pam_tpm_keyring_authtok /etc/pam.d/gdm-fingerprint')" "0" "$WORK/uninstall2.out"
check "...and leaves both keyring lines where they were" \
  "$(vm_ssh 'grep -c pam_gnome_keyring /etc/pam.d/gdm-fingerprint')" "2" "$WORK/uninstall2.out"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All SELinux VM tests passed."
else
  echo "Some SELinux VM tests FAILED." >&2
fi
exit "$FAIL"

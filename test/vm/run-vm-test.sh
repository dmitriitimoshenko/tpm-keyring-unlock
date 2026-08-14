#!/usr/bin/env bash
# VM-based test layer: the one thing the Docker suite structurally can't
# cover (see test/README.md) - a real TPM 2.0 device (swtpm) behind real
# UEFI firmware with genuinely toggleable Secure Boot state (OVMF, both the
# secboot-capable code and both vars variants), running the actual
# bin/seal.sh and pam/tpm-keyring-unseal.sh - including a real reboot cycle
# (full swtpm+qemu process restart against the same persisted TPM state and
# disk). That reboot cycle is exactly the failure class ("integrity check
# failed" / "PCR have changed since checked") found and fixed by hand in
# JOURNAL.md; no container can reproduce it, since containers share the
# host kernel and have no independent TPM.
#
# Opt-in (`make test-vm`), not part of test/run-all.sh or the default CI
# job: needs KVM, swtpm, and network access to fetch a cloud image once
# (cached after that), and is slower than everything else in test/ (real VM
# boots, not containers). See test/README.md.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=""
PIDS=()
FAIL=0

# Sends SIGTERM and actively polls for the process to actually disappear
# (up to 5s), escalating to SIGKILL if it hasn't. `wait "$pid"` looks like
# the obvious way to confirm death, but doesn't work here: qemu is started
# with -daemonize (it forks internally and reparents away from this shell),
# so the PID in $pidfile is never actually a direct child of this script -
# `wait` on it fails immediately ("not a child of this shell") and returns
# right away regardless of whether the process is still alive. Learned this
# the hard way: a full test run reported "All VM tests passed" and exited
# cleanly, yet qemu/swtpm/the seed http.server were all still running ~7
# minutes later - the old wait-based cleanup had declared victory instantly
# every time without ever actually confirming anything. See JOURNAL.md.
stop_pid() {
  local pid="$1" i
  [ -n "$pid" ] || return 0
  kill "$pid" >/dev/null 2>&1 || return 0
  for i in $(seq 1 50); do
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

# Issues a clean guest shutdown and waits for qemu to exit on its own,
# instead of an abrupt kill, before the B1->B2 transition specifically -
# the transition that's supposed to model a real reboot. This replaces
# (not just supplements) the earlier guest-side `sync` fix: `sync` only
# guaranteed the *guest's* ext4 write-back cache reached the virtual disk.
# It said nothing about whatever qemu's own device models had or hadn't
# flushed to their backing files by the time the process died - the pflash
# store backing OVMF_VARS in particular (a `-drive if=pflash` with no
# explicit cache= defaults to writeback, buffered at the qemu/host layer,
# a completely different cache from the guest's own). A real reboot is
# always an orderly OS shutdown before power is actually cut, never a
# yanked cord - letting the guest own its own shutdown, and letting qemu's
# block backends go through their normal close/flush path on ACPI poweroff
# (no -no-shutdown is passed, so qemu exits on its own once the guest
# powers off), addresses every buffering layer at once instead of chasing
# them one at a time as each is discovered. See JOURNAL.md.
graceful_poweroff_and_wait() {
  local qemu_pid="$1" port="$2" timeout="${3:-30}" waited=0
  # Backgrounded and not waited on: the SSH session/connection dies out
  # from under this command mid-shutdown, which would otherwise make the
  # ssh invocation itself hang or return a spurious non-zero.
  vm_ssh "$port" 'sudo systemctl poweroff' >/dev/null 2>&1 &
  while [ "$waited" -lt "$timeout" ]; do
    kill -0 "$qemu_pid" 2>/dev/null || return 0
    sleep 1
    waited=$((waited + 1))
  done
  # Didn't exit cleanly in time - fall back so the script can't hang
  # forever, though this reintroduces the exact question this function
  # exists to avoid, for whatever fraction of the poweroff was still
  # pending.
  stop_pid "$qemu_pid"
}

check() {
  local desc="$1" got="$2" want="$3" errfile="${4:-}"
  if [ "$got" = "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (got: $got, want: $want)"
    if [ -n "$errfile" ] && [ -s "$errfile" ]; then
      echo "  -- stderr ($errfile): --"
      sed 's/^/  | /' "$errfile"
    fi
    FAIL=1
  fi
}

# --- preflight: everything here is a clean SKIPPED (exit 0), matching the
# convention the rest of test/ already uses for "capability genuinely
# absent on this host" (see test/run-all.sh's docker/qemu checks) ----------
MISSING=()
for bin in qemu-system-x86_64 qemu-img swtpm ssh ssh-keygen scp curl python3 sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Missing tools, skipping VM tests: ${MISSING[*]}" >&2
  echo "Install with: sudo apt install -y swtpm swtpm-tools qemu-system-x86 qemu-utils openssh-client curl" >&2
  exit 0
fi

if [ ! -e /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "No usable /dev/kvm (need read+write access) - skipping VM tests." >&2
  echo "(sudo usermod -aG kvm \$USER, then log out/in, if the device exists" >&2
  echo "but isn't accessible to your user)" >&2
  exit 0
fi

OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS_OFF=/usr/share/OVMF/OVMF_VARS_4M.fd
OVMF_VARS_ON=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
for f in "$OVMF_CODE" "$OVMF_VARS_OFF" "$OVMF_VARS_ON"; do
  if [ ! -f "$f" ]; then
    echo "Missing OVMF firmware file: $f - skipping VM tests. (sudo apt install ovmf)" >&2
    exit 0
  fi
done

WORK=$(mktemp -d)

# --- base cloud image: downloaded once, cached outside the repo, checksum
# re-verified against Ubuntu's currently-published SHA256SUMS every run
# (not a hash frozen in this script - the file at this URL gets refreshed
# upstream periodically, a frozen hash would just force pointless re-fetches
# or bit-rot into a false failure) ------------------------------------------
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tpm-keyring-unlock-vm-test"
IMG_NAME="ubuntu-24.04-minimal-cloudimg-amd64.img"
IMG_BASE_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release"
BASE_IMG="$CACHE_DIR/$IMG_NAME"

mkdir -p "$CACHE_DIR"
echo "-- checking cached base cloud image against upstream checksum --"
EXPECTED_SHA="$(curl -fsSL --max-time 30 "$IMG_BASE_URL/SHA256SUMS" | awk -v f="$IMG_NAME" '$2 == "*"f {print $1}')"
if [ -z "$EXPECTED_SHA" ]; then
  echo "Couldn't fetch/parse upstream SHA256SUMS - skipping VM tests (no network?)." >&2
  exit 0
fi

if [ ! -f "$BASE_IMG" ] || ! echo "$EXPECTED_SHA  $BASE_IMG" | sha256sum -c - >/dev/null 2>&1; then
  echo "-- downloading base cloud image (~250MB, cached at $CACHE_DIR after this) --"
  curl -fL --max-time 600 -o "$BASE_IMG.tmp" "$IMG_BASE_URL/$IMG_NAME"
  if ! echo "$EXPECTED_SHA  $BASE_IMG.tmp" | sha256sum -c - >/dev/null 2>&1; then
    echo "Downloaded image failed checksum verification - aborting." >&2
    rm -f "$BASE_IMG.tmp"
    exit 1
  fi
  mv "$BASE_IMG.tmp" "$BASE_IMG"
else
  echo "ok   - cached image matches upstream checksum, skipping download"
fi

# --- helpers ----------------------------------------------------------
pick_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}

mk_seed() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/meta-data" <<EOF
instance-id: tpm-keyring-unlock-vm-test-$$
local-hostname: vmtest
EOF
  cat >"$dir/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $PUBKEY
package_update: true
packages:
  - tpm2-tools
  - mokutil
EOF
}

start_seed_server() {
  local dir="$1" port="$2"
  ( cd "$dir" && exec python3 -m http.server "$port" --bind 0.0.0.0 >/dev/null 2>&1 ) &
  PIDS+=("$!")
}

start_swtpm() {
  local statedir="$1" sock="$2"
  mkdir -p "$statedir"
  # Explicit redirection matters here, not just tidiness: a long-lived
  # background daemon started with no redirect inherits whatever stdout its
  # caller currently has. boot_b() used to be called as B1_SSHPORT=$(boot_b)
  # - a command substitution, which is a pipe - and since swtpm never exits,
  # that pipe never saw EOF and the substitution hung forever (hit this for
  # real on the first run: scenario B hung indefinitely at its very first
  # line). boot_b() is called directly now, not substituted (see its own
  # comment), but the redirect stays: whether a caller is a plain command or
  # a substitution shouldn't change what this function does. See JOURNAL.md.
  swtpm socket --tpm2 --tpmstate "dir=$statedir" --ctrl "type=unixio,path=$sock" --log level=1 \
    >"$statedir.log" 2>&1 &
  LAST_SWTPM_PID=$!
  PIDS+=("$LAST_SWTPM_PID")
  local i
  for i in $(seq 1 50); do
    [ -S "$sock" ] && return 0
    sleep 0.1
  done
  return 1
}

start_vm() {
  local overlay="$1" varsfile="$2" tpmsock="$3" sshport="$4" httpport="$5" pidfile="$6"
  # -daemonize forks and detaches on its own, but redirecting explicitly
  # anyway rather than trusting daemonize's exact fd handling across qemu
  # versions - see start_swtpm's comment for why an unredirected long-lived
  # child is a real hang risk, not just noise, if a future caller wraps
  # this in a command substitution again.
  qemu-system-x86_64 \
    -M q35 -accel kvm -cpu host -m 2048 -smp 2 \
    -display none -monitor none -serial "file:$WORK/console-$sshport.log" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$varsfile" \
    -drive "if=virtio,file=$overlay,format=qcow2" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${sshport}-:22" -device virtio-net-pci,netdev=n0 \
    -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:${httpport}/" \
    -chardev "socket,id=chrtpm,path=$tpmsock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -pidfile "$pidfile" -daemonize \
    >"$pidfile.log" 2>&1
  LAST_QEMU_PID="$(cat "$pidfile")"
  PIDS+=("$LAST_QEMU_PID")
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5)
vm_ssh() { local port="$1"; shift; ssh "${SSH_OPTS[@]}" -i "$WORK/id_test" -p "$port" ubuntu@127.0.0.1 "$@"; }
vm_scp() { local port="$1"; shift; scp "${SSH_OPTS[@]}" -i "$WORK/id_test" -P "$port" "$@"; }

wait_for_ssh() {
  local port="$1" timeout="${2:-240}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    vm_ssh "$port" true >/dev/null 2>&1 && return 0
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

ssh-keygen -t ed25519 -N "" -f "$WORK/id_test" -q
PUBKEY="$(cat "$WORK/id_test.pub")"

# ===========================================================================
# Scenario A: Secure Boot OFF -> require_secure_boot() must refuse
# ===========================================================================
echo
echo "########################################"
echo "# Scenario A: Secure Boot OFF"
echo "########################################"

A_OVERLAY="$WORK/a-disk.qcow2"
A_VARS="$WORK/a-vars.fd"
A_SEED="$WORK/a-seed"
A_SSHPORT=$(pick_free_port)
A_HTTPPORT=$(pick_free_port)

qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$A_OVERLAY" >/dev/null
cp "$OVMF_VARS_OFF" "$A_VARS"
mk_seed "$A_SEED"
start_seed_server "$A_SEED" "$A_HTTPPORT"
start_swtpm "$WORK/a-tpmstate" "$WORK/a-tpm.sock"
A_SWTPM_PID="$LAST_SWTPM_PID"
start_vm "$A_OVERLAY" "$A_VARS" "$WORK/a-tpm.sock" "$A_SSHPORT" "$A_HTTPPORT" "$WORK/a-qemu.pid"
A_QEMU_PID="$LAST_QEMU_PID"

if wait_for_ssh "$A_SSHPORT"; then
  vm_ssh "$A_SSHPORT" 'cloud-init status --wait' >/dev/null 2>&1 || true
  vm_ssh "$A_SSHPORT" 'mkdir -p ~/tpm-keyring-unlock'
  vm_scp "$A_SSHPORT" -r "$REPO_DIR/bin" "ubuntu@127.0.0.1:~/tpm-keyring-unlock/"

  if vm_ssh "$A_SSHPORT" 'source ~/tpm-keyring-unlock/bin/lib.sh; require_secure_boot' \
       >"$WORK/a-sb.out" 2>"$WORK/a-sb.err"; then
    got=allowed
  else
    got=refused
  fi
  check "Secure Boot OFF: require_secure_boot() refuses" "$got" "refused" "$WORK/a-sb.err"
else
  check "VM A reachable over SSH" "unreachable" "reachable"
fi

stop_pid "$A_QEMU_PID"
stop_pid "$A_SWTPM_PID"

# ===========================================================================
# Scenario B: Secure Boot ON -> real seal/unseal round trip, reboot
# survival, and concurrent-unseal-call safety
# ===========================================================================
echo
echo "########################################"
echo "# Scenario B: Secure Boot ON"
echo "########################################"

B_OVERLAY="$WORK/b-disk.qcow2"
B_VARS="$WORK/b-vars.fd"
B_TPMSTATE="$WORK/b-tpmstate"
B_SOCK="$WORK/b-tpm.sock"
B_SEED="$WORK/b-seed"
SECRET="vm-test-throwaway-secret-$(date +%s)"

qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$B_OVERLAY" >/dev/null
cp "$OVMF_VARS_ON" "$B_VARS"
mk_seed "$B_SEED"

# (Re)starts swtpm + qemu against the same persistent B_TPMSTATE / B_VARS /
# B_OVERLAY. Called twice: once for the initial seal, once more afterward
# with everything fully stopped and restarted in between - a full swtpm+qemu
# process restart against on-disk state is what actually reproduces a real
# TPM reset-count increment across a reboot, not just an in-guest `reboot`.
# Sets B_BOOT_SSHPORT / B_BOOT_QEMU_PID / B_BOOT_SWTPM_PID as its "return
# value" - must be called directly, NOT as boot_b's stdout captured via
# $(...). Command substitution always forks a subshell, and these variable
# assignments (along with everything start_swtpm/start_vm set) would vanish
# with it the moment the subshell exits, well before the caller could read
# them - hit exactly this ("B_BOOT_QEMU_PID: unbound variable") on the
# first attempt, when this used to `echo "$sshport"` and get called as
# B1_SSHPORT=$(boot_b). See JOURNAL.md.
boot_b() {
  local sshport httpport
  sshport=$(pick_free_port)
  httpport=$(pick_free_port)
  start_seed_server "$B_SEED" "$httpport"
  start_swtpm "$B_TPMSTATE" "$B_SOCK"
  B_BOOT_SWTPM_PID="$LAST_SWTPM_PID"
  start_vm "$B_OVERLAY" "$B_VARS" "$B_SOCK" "$sshport" "$httpport" "$WORK/b-qemu-$sshport.pid"
  B_BOOT_QEMU_PID="$LAST_QEMU_PID"
  B_BOOT_SSHPORT="$sshport"
}

boot_b
B1_SSHPORT="$B_BOOT_SSHPORT"
B1_QEMU_PID="$B_BOOT_QEMU_PID"
B1_SWTPM_PID="$B_BOOT_SWTPM_PID"

if wait_for_ssh "$B1_SSHPORT"; then
  vm_ssh "$B1_SSHPORT" 'cloud-init status --wait' >/dev/null 2>&1 || true
  vm_ssh "$B1_SSHPORT" 'mkdir -p ~/tpm-keyring-unlock'
  vm_scp "$B1_SSHPORT" -r "$REPO_DIR/bin" "$REPO_DIR/pam" "ubuntu@127.0.0.1:~/tpm-keyring-unlock/"

  if vm_ssh "$B1_SSHPORT" 'source ~/tpm-keyring-unlock/bin/lib.sh; require_secure_boot' \
       >"$WORK/b-sb.out" 2>"$WORK/b-sb.err"; then
    got=allowed
  else
    got=refused
  fi
  check "Secure Boot ON: require_secure_boot() allows" "$got" "allowed" "$WORK/b-sb.err"

  # tss group membership needs a fresh SSH session (fresh login) to take
  # effect - matches the real install.sh flow (usermod -aG tss, relogin).
  vm_ssh "$B1_SSHPORT" 'sudo usermod -aG tss ubuntu'

  printf '%s\n%s\n' "$SECRET" "$SECRET" | vm_ssh "$B1_SSHPORT" \
    'bash ~/tpm-keyring-unlock/bin/seal.sh' >"$WORK/seal.out" 2>"$WORK/seal.err"
  if [ $? -eq 0 ]; then got=sealed; else got=failed; fi
  check "seal.sh seals the throwaway secret" "$got" "sealed" "$WORK/seal.err"

  GOT_SECRET="$(vm_ssh "$B1_SSHPORT" 'sudo bash ~/tpm-keyring-unlock/pam/tpm-keyring-unseal.sh ubuntu' \
    2>"$WORK/unseal1.err")"
  check "tpm-keyring-unseal.sh returns the sealed secret (same boot)" "$GOT_SECRET" "$SECRET" "$WORK/unseal1.err"

  # Two concurrent unseal calls against the same real TPM must both still
  # succeed - validates the flock serialization fix for the "PCR have
  # changed since checked" race (JOURNAL.md, second regression). Docker
  # can't exercise this at all: the fake helper there has no real TPM to
  # contend over.
  vm_ssh "$B1_SSHPORT" \
    'sudo bash ~/tpm-keyring-unlock/pam/tpm-keyring-unseal.sh ubuntu >/tmp/o1 2>/tmp/e1 &
     sudo bash ~/tpm-keyring-unlock/pam/tpm-keyring-unseal.sh ubuntu >/tmp/o2 2>/tmp/e2 &
     wait'
  CONC1="$(vm_ssh "$B1_SSHPORT" 'cat /tmp/o1' 2>/dev/null)"
  CONC2="$(vm_ssh "$B1_SSHPORT" 'cat /tmp/o2' 2>/dev/null)"
  if [ "$CONC1" = "$SECRET" ] && [ "$CONC2" = "$SECRET" ]; then
    got=both-correct
  else
    got="1=$CONC1 2=$CONC2"
  fi
  check "two concurrent unseal calls both succeed (flock serialization)" "$got" "both-correct"

  B1_OK=1
else
  check "VM B reachable over SSH (boot 1)" "unreachable" "reachable"
  B1_OK=0
fi

if [ "$B1_OK" -eq 1 ]; then
  # Clean guest shutdown, not an abrupt kill - see graceful_poweroff_and_wait's
  # comment. Only matters when boot 2 is actually going to happen (B1_OK=1);
  # if B1 never came up at all, there's nothing to flush and no reboot check
  # will run, so a plain stop_pid is fine.
  graceful_poweroff_and_wait "$B1_QEMU_PID" "$B1_SSHPORT"
else
  stop_pid "$B1_QEMU_PID"
fi
stop_pid "$B1_SWTPM_PID"

if [ "$B1_OK" -eq 1 ]; then
  echo
  echo "-- restarting scenario B's VM (same disk + TPM state + OVMF vars) to test reboot survival --"
  boot_b
  B2_SSHPORT="$B_BOOT_SSHPORT"
  B2_QEMU_PID="$B_BOOT_QEMU_PID"
  B2_SWTPM_PID="$B_BOOT_SWTPM_PID"

  if wait_for_ssh "$B2_SSHPORT"; then
    GOT_SECRET2="$(vm_ssh "$B2_SSHPORT" 'sudo bash ~/tpm-keyring-unlock/pam/tpm-keyring-unseal.sh ubuntu' \
      2>"$WORK/unseal2.err")"
    check "tpm-keyring-unseal.sh survives a real reboot (fresh primary, same sealed blob)" \
      "$GOT_SECRET2" "$SECRET" "$WORK/unseal2.err"
  else
    check "VM B reachable over SSH (boot 2, post-reboot)" "unreachable" "reachable"
  fi

  stop_pid "$B2_QEMU_PID"
  stop_pid "$B2_SWTPM_PID"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All VM tests passed."
else
  echo "Some VM tests FAILED." >&2
fi
exit "$FAIL"

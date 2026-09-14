#!/usr/bin/env bash
# Runs after the distro-specific Dockerfile has already installed
# dependencies via that distro's real package manager (the part that
# actually differs per distro). From here on the checks are the same
# everywhere: does the module compile against this distro's real PAM
# headers, and does find_pam_module_dir() (bin/lib.sh) land on a directory
# that genuinely holds pam_unix.so - not just "some directory that exists".
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../../bin/lib.sh
source "$REPO_DIR/bin/lib.sh"

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

echo "-- compiling against this distro's real PAM headers --"
if gcc -Wall -Wextra -fPIC -shared \
    -o /tmp/pam_tpm_keyring_authtok.so \
    "$REPO_DIR/pam/pam_tpm_keyring_authtok.c" -lpam 2>&1; then
  check "module compiles cleanly" ok ok
else
  check "module compiles cleanly" fail ok
fi

echo
echo "-- PAM module directory detection --"
DETECTED="$(find_pam_module_dir || true)"
if [ -n "$DETECTED" ]; then
  check "find_pam_module_dir() found something" found found
  if [ -f "$DETECTED/pam_unix.so" ]; then
    check "$DETECTED genuinely contains pam_unix.so" yes yes
  else
    check "$DETECTED genuinely contains pam_unix.so" no yes
  fi
else
  check "find_pam_module_dir() found something" "not-found" found
fi

echo
echo
echo "-- 'sg' group borrowing (what lets install.sh finish in one run) --"
# install.sh adds the user to 'tss' and then keeps going in the same session,
# which only works because `sg` starts a shell with the group list re-read from
# the database. A session's own group list is fixed when it starts, so without
# this the TPM steps would fail and the user would have to log out and re-run.
# Checked per distro because sg comes from shadow-utils and its behaviour (and
# presence) is not guaranteed to be identical everywhere.
if ! command -v sg >/dev/null 2>&1; then
  # not fatal for the project - install.sh falls back to "log out and re-run" -
  # but it should be visible which distros lose the one-run install
  echo "note - no sg on this distro: install.sh will fall back to asking for a"
  echo "       logout and a second run. Not a failure, but worth knowing."
elif ! command -v setpriv >/dev/null 2>&1; then
  # setpriv is how this test builds a process with a deliberately stale group
  # list; some minimal images ship without it. Says nothing about sg on a real
  # install of this distro, so it is a skip, not a failure.
  echo "note - no setpriv in this image, so the stale-group-list setup can't be"
  echo "       built here. Skipping (sg itself is present)."
else
  groupadd -f sgtest >/dev/null 2>&1
  groupadd -f sgother >/dev/null 2>&1
  id sguser >/dev/null 2>&1 || useradd -M -N -s /bin/sh sguser >/dev/null 2>&1
  usermod -aG sgtest,sgother sguser >/dev/null 2>&1

  # The situation to reproduce is a *session whose group list predates the
  # usermod*. Rather than racing a background shell against a group change -
  # which hung two distros' containers when this test held an `su` open on a
  # fifo - build it directly: setpriv starts a process with exactly the groups
  # named, so leaving sgtest out of that list is the same stale state without
  # the timing. The database still lists sguser in sgtest, which is what sg
  # reads.
  SGUID="$(id -u sguser)"
  SGGID="$(id -g sguser)"
  SGOTHER_GID="$(getent group sgother | cut -d: -f3)"

  # timeout: if sg ever decides to prompt for a group password, fail instead of
  # hanging the suite (and flag the same risk for the installer).
  SG_OUT="$(setpriv --reuid "$SGUID" --regid "$SGGID" --groups "$SGOTHER_GID" \
    sh -c '
      id -nG | tr " " "\n" | grep -cx sgtest
      timeout 10 sg sgtest -c "id -nG" | tr " " "\n" | grep -cx sgtest
      timeout 10 sg sgtest -c "id -nG" | tr " " "\n" | grep -cx sgother
    ' 2>/dev/null || true)"
  mapfile -t SG_RESULT <<<"$SG_OUT"

  check "a process whose group list predates the grant does not see the group" \
    "${SG_RESULT[0]:-<no output>}" "0"
  check "sg picks that group up anyway, with no password prompt" \
    "${SG_RESULT[1]:-<no output>}" "1"
  check "sg keeps the groups the process already had (sudo, in real use)" \
    "${SG_RESULT[2]:-<no output>}" "1"
fi

if [ "$fail" -eq 0 ]; then
  echo "All packaging/detection tests passed on $(cat /etc/os-release 2>/dev/null | grep ^PRETTY_NAME= | cut -d= -f2- | tr -d '\"' || echo unknown)."
else
  echo "Some packaging/detection tests FAILED." >&2
fi
exit "$fail"

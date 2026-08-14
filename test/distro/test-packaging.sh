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
if [ "$fail" -eq 0 ]; then
  echo "All packaging/detection tests passed on $(cat /etc/os-release 2>/dev/null | grep ^PRETTY_NAME= | cut -d= -f2- | tr -d '\"' || echo unknown)."
else
  echo "Some packaging/detection tests FAILED." >&2
fi
exit "$fail"

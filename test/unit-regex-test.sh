#!/usr/bin/env bash
# Tests the PAM auth-line detection/insertion regex (bin/lib.sh's
# PAM_GNOME_KEYRING_AUTH_RE) against fixture files, independent of any
# distro - this is pure grep/sed logic install.sh and uninstall.sh both
# rely on. Run directly, no container needed: it only touches files under
# test/fixtures and a throwaway tmp copy, never anything real.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_DIR/test/fixtures/pam.d"

# shellcheck source=../bin/lib.sh
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

# --- detection: which fixtures does the regex match? ----------------------
for f in simple-control bracketed-control already-patched; do
  if grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$FIXTURES/$f"; then got=match; else got=no-match; fi
  check "detects auth-phase pam_gnome_keyring.so in $f" "$got" "match"
done

if grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$FIXTURES/no-match"; then got=match; else got=no-match; fi
check "correctly ignores no-match (no pam_gnome_keyring.so at all)" "$got" "no-match"

# --- install.sh's actual "needs patching" logic: matches regex AND doesn't
# already have our module wired in --------------------------------------
needs_patch() {
  grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$1" && ! grep -q pam_tpm_keyring_authtok.so "$1"
}

for f in simple-control bracketed-control; do
  if needs_patch "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f needs patching" "$got" "yes"
done

if needs_patch "$FIXTURES/already-patched"; then got=yes; else got=no; fi
check "already-patched is correctly skipped" "$got" "no"

# --- insertion: sed actually inserts our line right before the matched
# line, for both control-syntax styles -----------------------------------
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

for f in simple-control bracketed-control; do
  cp "$FIXTURES/$f" "$WORKDIR/$f"
  sed -E -i "/${PAM_GNOME_KEYRING_AUTH_RE}/i auth    optional        pam_tpm_keyring_authtok.so" "$WORKDIR/$f"
  if grep -q pam_tpm_keyring_authtok.so "$WORKDIR/$f"; then got=inserted; else got=missing; fi
  check "sed insertion works on $f" "$got" "inserted"

  # our line must land immediately before the pam_gnome_keyring.so line,
  # not just somewhere in the file
  line_no_ours=$(grep -n pam_tpm_keyring_authtok.so "$WORKDIR/$f" | head -1 | cut -d: -f1)
  line_no_theirs=$(grep -nE "$PAM_GNOME_KEYRING_AUTH_RE" "$WORKDIR/$f" | tail -1 | cut -d: -f1)
  if [ "$((line_no_ours + 1))" = "$line_no_theirs" ]; then got=adjacent; else got=not-adjacent; fi
  check "$f: inserted line is immediately before pam_gnome_keyring.so" "$got" "adjacent"
done

echo
if [ "$fail" -eq 0 ]; then
  echo "All regex/detection tests passed."
else
  echo "Some regex/detection tests FAILED." >&2
fi
exit "$fail"

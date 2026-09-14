#!/usr/bin/env bash
# Tests the PAM auth-line detection/insertion logic in bin/lib.sh (the
# pam_gnome_keyring wiring regex, plus the pam_fprintd idle-timeout rewrite)
# against fixture files, independent of any distro - pure grep/sed/awk logic
# install.sh and uninstall.sh both rely on. Run directly, no container: it
# only touches test/fixtures and a throwaway tmp copy, never anything real.
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

# --- pam_fprintd idle-timeout logic (bin/lib.sh's PAM_FPRINTD_AUTH_RE,
# pam_auth_is_fingerprint_only, pam_fprintd_set/clear_unlimited_timeout) ---
# The dangerous mistake this section exists to catch is applying timeout=-1
# to a *shared* auth stack: PAM is serialised, so an unlimited fingerprint
# wait in something like common-auth would mean sudo never reaches its
# password prompt. Everything else here is formatting.

for f in fprintd-only simple-control already-patched fprintd-unlimited; do
  if pam_auth_is_fingerprint_only "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is recognised as a fingerprint-only auth stack" "$got" "yes"
done

for f in fprintd-shared bracketed-control no-match; do
  if pam_auth_is_fingerprint_only "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is refused (shared stack, or no fingerprint at all)" "$got" "no"
done

# install.sh's actual eligibility test: hardening would change something, there
# is exactly one real fprintd auth line to build on, and the stack is
# fingerprint-only.
fprintd_eligible() {
  ! pam_fprintd_harden <"$1" | cmp -s - "$1" \
    && pam_fprintd_has_single_auth_line "$1" \
    && pam_auth_is_fingerprint_only "$1"
}

for f in fprintd-only simple-control fprintd-unlimited; do
  if fprintd_eligible "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is eligible for the attempt-stack rewrite" "$got" "yes"
done

for f in fprintd-hardened fprintd-shared no-match; do
  if fprintd_eligible "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is correctly skipped (already done, shared stack, or no reader)" "$got" "no"
done

# --- the rewrite itself --------------------------------------------------
pam_fprintd_harden <"$FIXTURES/fprintd-only" >"$WORKDIR/fprintd-only"

got="$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$WORKDIR/fprintd-only")"
check "fprintd-only: the auth phase now holds $PAM_FPRINTD_ATTEMPTS fprintd attempts" \
  "$got" "$PAM_FPRINTD_ATTEMPTS"

got="$(grep -cE "$PAM_FPRINTD_RETRY_LINE_RE" "$WORKDIR/fprintd-only")"
check "fprintd-only: $((PAM_FPRINTD_ATTEMPTS - 1)) of them are generated attempt lines" \
  "$got" "$((PAM_FPRINTD_ATTEMPTS - 1))"

# the jumps must skip exactly the *remaining* attempt lines: the first one
# hops over the other two, the second over one. Getting this wrong either
# re-prompts for a finger after a match or skips the keyring lines entirely.
got="$(grep -oE 'success=[0-9]+' "$WORKDIR/fprintd-only" | tr '\n' ',')"
check "fprintd-only: jump distances count down to the original line" "$got" "success=2,success=1,"

got="$(grep -cE "${PAM_FPRINTD_AUTH_RE}.*timeout=-1" "$WORKDIR/fprintd-only")"
check "fprintd-only: every attempt carries timeout=-1" "$got" "$PAM_FPRINTD_ATTEMPTS"

# max-tries=1 is what makes one line equal one scan: left at the module's
# default of 3, a mismatch would be retried inside a single attempt line and
# the stack's count would mean something different per failure kind.
got="$(grep -cE "${PAM_FPRINTD_AUTH_RE}.*max-tries=1" "$WORKDIR/fprintd-only")"
check "fprintd-only: every attempt carries max-tries=1" "$got" "$PAM_FPRINTD_ATTEMPTS"

# each generated control must let all three failure kinds fall through
got="$(grep -cE 'authinfo_unavail=ignore auth_err=ignore maxtries=ignore default=die' \
  "$WORKDIR/fprintd-only")"
check "fprintd-only: generated controls fall through on every failure kind" \
  "$got" "$((PAM_FPRINTD_ATTEMPTS - 1))"

# everything that is not an auth-phase fprintd line must be untouched - the
# invariant install.sh refuses to write without
if diff -q <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$FIXTURES/fprintd-only") \
  <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$WORKDIR/fprintd-only") >/dev/null; then
  got=untouched
else
  got=modified
fi
check "fprintd-only: every other line, password-phase fprintd included, untouched" \
  "$got" "untouched"

# A trailing comment must stay a trailing comment: appending an option after
# Debian's "# debug" would silently comment the option out instead of
# applying it. Tested on the shared fixture's line shape even though that
# file would never be a target, because the line shape is what matters.
got="$(pam_fprintd_harden <"$FIXTURES/fprintd-shared" \
  | grep -E "$PAM_FPRINTD_AUTH_RE" | tail -1)"
check "existing timeout= is replaced in place, ahead of the # comment" \
  "$got" "$(printf 'auth\t[success=3 default=ignore]\tpam_fprintd.so max-tries=1 timeout=-1 # debug')"

# --- idempotence + round trip -------------------------------------------
if diff -q <(pam_fprintd_harden <"$FIXTURES/fprintd-hardened") \
  "$FIXTURES/fprintd-hardened" >/dev/null; then got=noop; else got=changed; fi
check "hardening an already-hardened file is a no-op" "$got" "noop"

if diff -q <(pam_fprintd_harden <"$FIXTURES/fprintd-only" | pam_fprintd_harden) \
  "$WORKDIR/fprintd-only" >/dev/null; then got=stable; else got=stacked; fi
check "hardening twice cannot stack up extra attempt lines" "$got" "stable"

if diff -q <(pam_fprintd_harden <"$FIXTURES/fprintd-only" | pam_fprintd_unharden) \
  "$FIXTURES/fprintd-only" >/dev/null; then
  got=restored
else
  got=differs
fi
check "harden then unharden restores fprintd-only byte for byte" "$got" "restored"

if diff -q <(pam_fprintd_unharden <"$FIXTURES/fprintd-only") \
  "$FIXTURES/fprintd-only" >/dev/null; then got=noop; else got=changed; fi
check "unharden on a file that was never hardened is a no-op" "$got" "noop"

# fprintd-hardened is what install.sh writes, carrying its own header comment,
# so compare the fprintd lines rather than the whole file
got="$(pam_fprintd_unharden <"$FIXTURES/fprintd-hardened" \
  | grep -cE "$PAM_FPRINTD_AUTH_RE")"
check "unharden collapses the shipped hardened shape back to one attempt" "$got" "1"

got="$(pam_fprintd_unharden <"$FIXTURES/fprintd-hardened" \
  | grep -E "$PAM_FPRINTD_AUTH_RE")"
check "...and that line is the distro's original, options and all" \
  "$got" "$(printf 'auth\trequired\tpam_fprintd.so')"

echo
if [ "$fail" -eq 0 ]; then
  echo "All regex/detection tests passed."
else
  echo "Some regex/detection tests FAILED." >&2
fi
exit "$fail"

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
for f in simple-control bracketed-control already-patched dash-prefixed; do
  if grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$FIXTURES/$f"; then got=match; else got=no-match; fi
  check "detects auth-phase pam_gnome_keyring.so in $f" "$got" "match"
done

if grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$FIXTURES/no-match"; then got=match; else got=no-match; fi
check "correctly ignores no-match (no pam_gnome_keyring.so at all)" "$got" "no-match"

# Every fixture above has exactly one auth-phase pam_gnome_keyring.so line
# plus a *session*-phase one. The count guards the half of the pattern the
# grep -q checks can't see: that allowing the optional pam.conf(5) '-'
# prefix (for '-auth', as Debian-family lightdm stacks write it) didn't
# also start matching '-session optional pam_gnome_keyring.so auto_start'.
# Patching a session line would insert our auth module into the session
# phase, where it does nothing at best.
for f in simple-control bracketed-control already-patched dash-prefixed; do
  got=$(grep -cE "$PAM_GNOME_KEYRING_AUTH_RE" "$FIXTURES/$f")
  check "matches the auth line only, not the session line, in $f" "$got" "1"
done

# --- install.sh's actual "needs patching" logic: matches regex AND doesn't
# already have our module wired in --------------------------------------
needs_patch() {
  grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$1" && ! grep -q pam_tpm_keyring_authtok.so "$1"
}

for f in simple-control bracketed-control dash-prefixed; do
  if needs_patch "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f needs patching" "$got" "yes"
done

if needs_patch "$FIXTURES/already-patched"; then got=yes; else got=no; fi
check "already-patched is correctly skipped" "$got" "no"

# --- insertion: sed actually inserts our line right before the matched
# line, for every control-syntax style -----------------------------------
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

for f in simple-control bracketed-control dash-prefixed; do
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
# pam_auth_is_fingerprint_only, pam_fprintd_harden/unharden) ---
# The dangerous mistake this section exists to catch is applying timeout=-1
# to a *shared* auth stack: PAM is serialised, so an unlimited fingerprint
# wait in something like common-auth would mean sudo never reaches its
# password prompt. Everything else here is formatting.

for f in fprintd-only simple-control already-patched fprintd-unlimited; do
  if pam_auth_is_fingerprint_only "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is recognised as a fingerprint-only auth stack" "$got" "yes"
done

for f in fprintd-shared bracketed-control no-match fprintd-dash-auth \
  fprintd-continuation; do
  if pam_auth_is_fingerprint_only "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is refused (shared stack, or no fingerprint at all)" "$got" "no"
done

# PAM joins a line ending in a backslash with the next one. Read physically,
# the pam_unix.so in fprintd-continuation is invisible and the stack reads as
# fingerprint-only - the same blind spot the leading-dash form had.
if pam_auth_is_fingerprint_only "$FIXTURES/fprintd-continuation"; then got=yes; else got=no; fi
check "a module hidden behind a backslash continuation is still seen" "$got" "no"

got="$(_pam_logical_lines "$FIXTURES/fprintd-continuation" | grep -c '^auth.*pam_unix\.so')"
check "...because the scanners read logical lines, not physical ones" "$got" "1"

for f in fprintd-continuation fprintd-continued-line; do
  if pam_config_has_no_line_continuations "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is flagged as carrying line continuations" "$got" "no"
done

for f in fprintd-only fprintd-shared fprintd-hardened; do
  if pam_config_has_no_line_continuations "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f has no line continuations" "$got" "yes"
done

# A second auth path written as "-auth" is still a second auth path. Called
# out separately from the loop above because it is the one shape that reads
# as fingerprint-only at a glance.
if pam_auth_is_fingerprint_only "$FIXTURES/fprintd-dash-auth"; then got=yes; else got=no; fi
check "a leading-dash '-auth' module counts as another way in" "$got" "no"

# Control field of the service's own fprintd line: the generated attempt lines
# jump and carry on, so an original that ended the stack on success
# (sufficient / success=done) or jumped a distance of its own can't be
# reproduced and has to be refused.
for f in fprintd-only simple-control fprintd-unlimited fprintd-hardened; do
  if pam_fprintd_control_falls_through "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f: the fprintd control falls through on success" "$got" "yes"
done

for f in fprintd-sufficient fprintd-shared; do
  if pam_fprintd_control_falls_through "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f: control ends the stack or jumps its own distance - refused" "$got" "no"
done

# the bracketed spelling of "fall through": success=ok records the result and
# carries on, exactly what success=N does, so it is the one bracketed control
# that is safe to rebuild as an attempt stack
printf '#%%PAM-1.0\nauth\t[success=ok default=ignore]\tpam_fprintd.so\nauth\toptional\tpam_gnome_keyring.so\n' \
  >"$WORKDIR/fprintd-success-ok"
if pam_fprintd_control_falls_through "$WORKDIR/fprintd-success-ok"; then got=yes; else got=no; fi
check "a bracketed [success=ok ...] fprintd control falls through" "$got" "yes"

printf '#%%PAM-1.0\nauth\t[default=ignore]\tpam_fprintd.so\nauth\toptional\tpam_gnome_keyring.so\n' \
  >"$WORKDIR/fprintd-no-success"
if pam_fprintd_control_falls_through "$WORKDIR/fprintd-no-success"; then got=yes; else got=no; fi
check "a bracketed control that never says what success does is refused" "$got" "no"

# Numeric jumps above the fprintd line: inserting attempt lines re-aims them.
for f in fprintd-only simple-control fprintd-hardened; do
  if pam_auth_has_no_relative_jumps "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f has no relative jump above the fprintd line" "$got" "yes"
done

if pam_auth_has_no_relative_jumps "$FIXTURES/fprintd-jump"; then got=yes; else got=no; fi
check "fprintd-jump's success=1 above the reader is spotted" "$got" "no"

# install.sh's actual test, calling the same predicate install.sh does rather
# than a hand-copied list of its parts: hardening would change something, and
# the file is eligible (exactly one real fprintd auth line, fingerprint-only
# stack, a control that falls through, no relative jump above it).
fprintd_eligible() {
  ! pam_fprintd_harden <"$1" | cmp -s - "$1" \
    && pam_fprintd_stack_is_eligible "$1"
}

for f in fprintd-only simple-control fprintd-unlimited; do
  if fprintd_eligible "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is eligible for the attempt-stack rewrite" "$got" "yes"
done

for f in fprintd-hardened fprintd-shared no-match \
  fprintd-sufficient fprintd-dash-auth fprintd-jump \
  fprintd-continuation fprintd-continued-line fprintd-dash-second \
  fprintd-handrolled; do
  if fprintd_eligible "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is correctly skipped (already done, shared stack, or no reader)" "$got" "no"
done

# The install and uninstall sides have to agree about whose stack a file is.
# pam_fprintd_has_single_auth_line() counts any authinfo_unavail=ignore line as
# one this tool generated, which is right for our own output and wrong for a
# hand-written retry stack that predates it - so eligibility asks
# pam_fprintd_stack_is_generated() whenever such lines are present.
if pam_fprintd_stack_is_eligible "$FIXTURES/fprintd-handrolled"; then got=yes; else got=no; fi
check "a hand-written retry stack is not install.sh's to rewrite" "$got" "no"

if pam_fprintd_stack_is_generated "$FIXTURES/fprintd-handrolled"; then got=yes; else got=no; fi
check "...and uninstall.sh agrees it is not ours to revert" "$got" "no"

# The second fingerprint line written with a dash has to be counted, or the
# rewrite leaves it sitting below the generated stack where a jump lands on it.
got="$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$FIXTURES/fprintd-dash-second")"
check "both fprintd auth lines are counted, dash form included" "$got" "2"

# a rewritten -auth line keeps its dash on the generated attempts, or a missing
# pam_fprintd.so would start erroring where the original was silent
got="$(printf -- '-auth\trequired\tpam_fprintd.so\n' | pam_fprintd_harden | grep -c '^-auth')"
check "generated attempts keep the leading dash of the line they copy" \
  "$got" "$PAM_FPRINTD_ATTEMPTS"

# The eligibility check is not a formality install.sh could drop once it has
# the rewrite in hand: the invariants it checks immediately before writing
# ("every non-fprintd line identical, N attempt lines, N-1 generated") only
# compare the rewrite against whatever is on disk, and a *shared* stack
# satisfies all three of them. That is the shape a package update can leave
# behind between the plan and the write - hence the re-check at both moments.
SHARED_REWRITE="$WORKDIR/shared-rewrite"
pam_fprintd_harden <"$FIXTURES/fprintd-shared" >"$SHARED_REWRITE"
if diff -q <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$FIXTURES/fprintd-shared") \
    <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$SHARED_REWRITE") >/dev/null \
  && [ "$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$SHARED_REWRITE")" = "$PAM_FPRINTD_ATTEMPTS" ] \
  && [ "$(grep -cE "$PAM_FPRINTD_RETRY_LINE_RE" "$SHARED_REWRITE")" = "$((PAM_FPRINTD_ATTEMPTS - 1))" ]; then
  got=accepted
else
  got=refused
fi
check "the write-time invariants alone would accept a shared stack" "$got" "accepted"

if pam_fprintd_stack_is_eligible "$FIXTURES/fprintd-shared"; then got=yes; else got=no; fi
check "...and only the eligibility check stops it" "$got" "no"

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

# No attempt may carry timeout=-1: an attempt with no deadline never returns,
# so the stack never reaches the next one and the whole PAM conversation hangs
# instead of falling back to the password. Measured against real libpam; see
# JOURNAL.md, 2026-09-15.
got="$(grep -cE "${PAM_FPRINTD_AUTH_RE}.*timeout=-1" "$WORKDIR/fprintd-only" || true)"
check "fprintd-only: no attempt carries timeout=-1" "$got" "0"

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
check "a distro's own timeout= is left alone, comment still last" \
  "$got" "$(printf 'auth\t[success=3 default=ignore]\tpam_fprintd.so max-tries=1 timeout=10 # debug')"

# An option this tool *does* add must land ahead of a trailing comment, or
# Debian's "# debug" would silently comment it out. Fed on stdin because no
# fixture happens to pair a comment with a missing max-tries=.
got="$(printf 'auth\t[success=3 default=ignore]\tpam_fprintd.so timeout=10 # debug\n' \
  | pam_fprintd_harden | grep -E "$PAM_FPRINTD_AUTH_RE" | tail -1)"
check "an appended option goes ahead of the # comment" \
  "$got" "$(printf 'auth\t[success=3 default=ignore]\tpam_fprintd.so timeout=10 max-tries=1 # debug')"

# --- idempotence + round trip -------------------------------------------
if diff -q <(pam_fprintd_harden <"$FIXTURES/fprintd-hardened") \
  "$FIXTURES/fprintd-hardened" >/dev/null; then got=noop; else got=changed; fi
check "hardening an already-hardened file is a no-op" "$got" "noop"

# --- migration from the pre-2026-09-15 stack (timeout=-1 on every attempt) ---
# An older install must still be recognised as this tool's own work, must
# upgrade cleanly to the current shape, and must still come apart on uninstall.
# Compared on the fprintd lines alone: the two fixtures deliberately carry
# different header comments, and harden passes comments through untouched.
if diff -q <(pam_fprintd_harden <"$FIXTURES/fprintd-hardened-legacy" | grep -E "$PAM_FPRINTD_AUTH_RE") \
  <(grep -E "$PAM_FPRINTD_AUTH_RE" "$FIXTURES/fprintd-hardened") >/dev/null; then
  got=migrated
else
  got=unchanged
fi
check "hardening a legacy stack migrates it to the current shape" "$got" "migrated"

got="$(pam_fprintd_harden <"$FIXTURES/fprintd-hardened-legacy" \
  | grep -cE "${PAM_FPRINTD_AUTH_RE}.*timeout=-1" || true)"
check "migration strips timeout=-1 from every attempt" "$got" "0"

if pam_fprintd_stack_is_generated "$FIXTURES/fprintd-hardened-legacy"; then
  got=ours
else
  got=unrecognised
fi
check "a legacy stack is still recognised as generated by this tool" "$got" "ours"

if diff -q <(pam_fprintd_unharden <"$FIXTURES/fprintd-hardened-legacy" | grep -E "$PAM_FPRINTD_AUTH_RE") \
  <(pam_fprintd_unharden <"$FIXTURES/fprintd-hardened" | grep -E "$PAM_FPRINTD_AUTH_RE") >/dev/null; then
  got=same
else
  got=differs
fi
check "legacy and current stacks unharden to the same file" "$got" "same"

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

# --- what uninstall.sh keys off ------------------------------------------
# The gate has to be "this is a stack we generated", proved by round trip -
# not "unharden would change something". unharden strips max-tries=1, and
# Debian's pam-auth-update writes exactly that into common-auth (the
# fprintd-shared fixture *is* that line), so the loose test offered to
# "restore" - and would have rewritten - a shared stack install.sh refuses to
# touch by design. See JOURNAL.md, 2026-09-15.
if pam_fprintd_stack_is_generated "$FIXTURES/fprintd-hardened"; then got=yes; else got=no; fi
check "fprintd-hardened is recognised as a stack install.sh wrote" "$got" "yes"

for f in fprintd-shared fprintd-only fprintd-unlimited fprintd-handrolled simple-control; do
  if pam_fprintd_stack_is_generated "$FIXTURES/$f"; then got=yes; else got=no; fi
  check "$f is not ours to revert" "$got" "no"
done

# the regression itself: unharden alone still changes Debian's common-auth,
# which is why the gate above can't be that
if pam_fprintd_unharden <"$FIXTURES/fprintd-shared" | cmp -s - "$FIXTURES/fprintd-shared"; then
  got=unchanged
else
  got=changed
fi
check "unharden alone does still rewrite common-auth (hence the strict gate)" \
  "$got" "changed"

# a stack written with some other attempt count has to round-trip too, or
# changing PAM_FPRINTD_ATTEMPTS later would strand every existing install
_pam_fprintd_rewrite_stack 5 <"$FIXTURES/fprintd-only" >"$WORKDIR/five-attempts"
if pam_fprintd_stack_is_generated "$WORKDIR/five-attempts"; then got=yes; else got=no; fi
check "a stack written with a different attempt count is still recognised" "$got" "yes"

# --- restoring the distro's exact original line --------------------------
# unharden only removes what install.sh adds. Since harden stopped writing
# timeout=, a distro's own timeout= now survives the round trip - but
# max-tries= does not, because harden still overwrites it with 1. The
# .bak-<timestamp> copy remains the only place that value survives, which is
# what pam_fprintd_exact_original() is for.
EX="$WORKDIR/exact"
mkdir -p "$EX"
sed -E 's/^(auth\trequired\tpam_fprintd\.so)$/\1 timeout=45 max-tries=2/' \
  "$FIXTURES/fprintd-only" >"$EX/svc.bak-20260101010101"
pam_fprintd_harden <"$EX/svc.bak-20260101010101" >"$EX/svc"

got="$(pam_fprintd_exact_original "$EX/svc" || echo none)"
check "the pre-install backup is found as the exact original" \
  "$got" "$EX/svc.bak-20260101010101"

got="$(pam_fprintd_unharden <"$EX/svc" | grep -cE "${PAM_FPRINTD_AUTH_RE}.*timeout=45" || true)"
check "the distro's own timeout=45 survives harden and unharden" "$got" "1"

got="$(pam_fprintd_unharden <"$EX/svc" | grep -cE "${PAM_FPRINTD_AUTH_RE}.*max-tries=2" || true)"
check "unharden alone cannot bring the distro's own max-tries=2 back" "$got" "0"

got="$(grep -cE "${PAM_FPRINTD_AUTH_RE}.*timeout=45" "$EX/svc.bak-20260101010101")"
check "...but restoring that backup does" "$got" "1"

# newest wins, and a backup that is itself a hardened stack is not an original
cp "$EX/svc" "$EX/svc.bak-20270101010101"
got="$(pam_fprintd_exact_original "$EX/svc" || echo none)"
check "a backup that is itself hardened is not mistaken for the original" \
  "$got" "$EX/svc.bak-20260101010101"

# a backup that isn't the direct ancestor (something edited the file since)
# must not be restored over newer content
printf 'session\toptional\tpam_gnome_keyring.so auto_start\n' >>"$EX/svc"
got="$(pam_fprintd_exact_original "$EX/svc" || echo none)"
check "a stale backup is refused once the file has moved on" "$got" "none"

# and with no backup beside it at all, there is nothing to restore
cp "$FIXTURES/fprintd-hardened" "$EX/lonely"
got="$(pam_fprintd_exact_original "$EX/lonely" || echo none)"
check "no backup beside the file means no exact restore" "$got" "none"

# --- /etc/pam.d/ entries that aren't services ----------------------------
# .bak-<ts> is this tool's own, the rest is what the package managers leave
# behind. They all carry real auth lines and PAM never reads any of them.
for f in gdm-password.bak-20260914231615 gdm-password.bak-1.bak-2 \
  gdm-fingerprint.pacnew common-auth.rpmnew common-auth.rpmsave \
  gdm-password.dpkg-old gdm-password.dpkg-dist common-auth.ucf-old; do
  if [[ "/etc/pam.d/$f" =~ $PAM_NON_SERVICE_RE ]]; then got=skipped; else got=scanned; fi
  check "/etc/pam.d/$f is skipped as a non-service file" "$got" "skipped"
done

# ...while the directory's own dot must not take real services with it
for f in gdm-fingerprint gdm-password common-auth common-session-noninteractive \
  sudo-i runuser-l sssd-shadowutils; do
  if [[ "/etc/pam.d/$f" =~ $PAM_NON_SERVICE_RE ]]; then got=skipped; else got=scanned; fi
  check "/etc/pam.d/$f is still scanned" "$got" "scanned"
done

echo
if [ "$fail" -eq 0 ]; then
  echo "All regex/detection tests passed."
else
  echo "Some regex/detection tests FAILED." >&2
fi
exit "$fail"

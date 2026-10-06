#!/usr/bin/env bash
# Tests the PAM auth-line detection/insertion logic in bin/lib.sh (the
# pam_gnome_keyring wiring regex, plus the pam_fprintd idle-timeout rewrite)
# against fixture files, independent of any distro - pure grep/sed/awk logic
# install.sh and uninstall.sh both rely on. Run directly, no container: it
# only touches test/fixtures and a throwaway tmp copy, never anything real.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_DIR/test/fixtures/pam.d"

# One cleanup for every temp dir below. `trap ... EXIT` replaces the trap set
# before it rather than adding to it, and this file used to set three - so
# every temp dir but the last outlived the run.
CLEANUP=()
trap '[ "${#CLEANUP[@]}" -eq 0 ] || rm -rf -- "${CLEANUP[@]}"' EXIT

# The predicates take colon-separated search paths (PAM_CONFIG_PATH), so a
# fixture directory cannot contain a colon. A checkout path that does gets its
# fixtures copied somewhere that doesn't.
if [[ "$FIXTURES" == *:* ]]; then
  FIXTURE_COPY="$(mktemp -d)"
  CLEANUP+=("$FIXTURE_COPY")
  cp -R "$FIXTURES/." "$FIXTURE_COPY/"
  FIXTURES="$FIXTURE_COPY"
fi

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
CLEANUP+=("$WORKDIR")

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

# --- the competing shared auth stack ------------------------------------
# The attempt stack only helps if it is the stack that gets the sensor. While
# pam_fprintd is also in common-auth, gdm-password races gdm-fingerprint for
# the reader and wins, so the hardened stack never prompts. See JOURNAL.md,
# 2026-09-15.

if pam_fprintd_in_shared_stack "$FIXTURES/shared/common-auth"; then got=conflict; else got=clear; fi
check "detects pam_fprintd in the shared auth stack" "$got" "conflict"

if pam_fprintd_in_shared_stack "$FIXTURES/shared-auth-plain"; then got=conflict; else got=clear; fi
check "no conflict reported for a shared stack without pam_fprintd" "$got" "clear"

# A continuation would hide the line from a plain grep, and the predicate that
# decides whether to warn has to see through it - otherwise install.sh hardens
# a stack that then silently never gets the reader.
if pam_fprintd_in_shared_stack "$FIXTURES/shared-auth-continued"; then got=conflict; else got=clear; fi
check "detects pam_fprintd split across a line continuation" "$got" "conflict"

if pam_shared_stack_is_sane_without_fprintd "$FIXTURES/shared-auth-plain"; then got=sane; else got=unsafe; fi
check "shared stack with pam_unix and no fprintd is sane" "$got" "sane"

if pam_shared_stack_is_sane_without_fprintd "$FIXTURES/shared/common-auth"; then got=sane; else got=unsafe; fi
check "shared stack still carrying fprintd is not 'done'" "$got" "unsafe"

# The post-condition that decides whether install.sh puts the backups back.
if pam_shared_stack_is_sane_without_fprintd "$FIXTURES/shared-auth-broken"; then got=sane; else got=unsafe; fi
check "shared stack with no primary auth module is refused" "$got" "unsafe"

# Which services actually lose fingerprint - the cost quoted to the user
# before they agree to it.
mapfile -t losers < <(pam_fprintd_services_losing_fingerprint \
  "$FIXTURES/shared/common-auth" "$FIXTURES/shared")
losers_str=" ${losers[*]} "

for want in gdm-password sudo-i; do
  case "$losers_str" in *"/shared/$want "*) got=listed ;; *) got=absent ;; esac
  check "$want loses fingerprint with the shared stack's line gone" "$got" "listed"
done

# This sudo has its own pam_fprintd.so line above the @include, so it keeps
# fingerprint either way and must not be quoted as a cost. It is this repo's
# own machine, where the line was added by hand - Ubuntu's stock file has
# none (the vendor tree below is the stock layout; GitHub issue #19). Its
# sudo-i was never given one, so `sudo -i` loses fingerprint there.
case "$losers_str" in *"/shared/sudo "*) got=listed ;; *) got=absent ;; esac
check "a service with its own fprintd line is not counted as a loss" "$got" "absent"

# gdm-fingerprint never includes the shared stack at all.
case "$losers_str" in *"/shared/gdm-fingerprint "*) got=listed ;; *) got=absent ;; esac
check "a service that doesn't include the shared stack is not listed" "$got" "absent"

case "$losers_str" in *".bak-20260101000000 "*) got=listed ;; *) got=absent ;; esac
check "a .bak- copy of a qualifying service is not listed" "$got" "absent"

case "$losers_str" in *"/shared/common-auth "*) got=listed ;; *) got=absent ;; esac
check "the shared stack does not list itself" "$got" "absent"

check "exactly two services lose fingerprint in the fixture tree" \
  "${#losers[@]}" "2"

# What the question that disables the profile names out of that list: only
# the prompts a person meets, and only where they really lose fingerprint.
check "a sudo with its own line leaves only sudo -i to name" \
  "$(pam_fprintd_shared_stack_prompts "$FIXTURES/shared/common-auth" "$FIXTURES/shared")" \
  "sudo -i"

check "no sudo or polkit among the losses means nothing is named" \
  "$(pam_fprintd_shared_stack_prompts "$FIXTURES/ordering/common-auth" "$FIXTURES/ordering")" \
  ""

# --- the same, on the layout Ubuntu 26.04 ships (GitHub issue #19) -------
# vendor/etc stands for /etc/pam.d and vendor/usr-lib for /usr/lib/pam.d.
# Every file but the `shadowed` pair is byte for byte what the Ubuntu 26.04
# packages install (sudo-common, util-linux, login, libpam-runtime, gdm3,
# polkitd, systemd), with common-auth as pam-auth-update writes it once the
# fprintd profile is on. Stock sudo and sudo-i carry no fingerprint line of
# their own, so both lose it along with the shared stack's; polkit's service
# file exists only in /usr/lib/pam.d, where a scan of /etc/pam.d never looked;
# su-l and the smartcard stack reach common-auth through `auth include su` and
# `auth substack`. The installer used to promise that sudo keeps fingerprint.
VENDOR="$FIXTURES/vendor"
VENDOR_PATH="$VENDOR/etc:$VENDOR/usr-lib"

# resolving a name the way libpam does: /etc/pam.d first, then the vendor
# directory, an absolute name as it stands (measured; JOURNAL.md, 2026-09-25)
check "a name in both directories resolves to the /etc/pam.d copy" \
  "$(pam_config_file shadowed "$VENDOR_PATH")" "$VENDOR/etc/shadowed"
check "a vendor-only name resolves into the vendor directory" \
  "$(pam_config_file polkit-1 "$VENDOR_PATH")" "$VENDOR/usr-lib/polkit-1"
check "an absolute name resolves to itself" \
  "$(pam_config_file "$VENDOR/usr-lib/polkit-1" /nonexistent)" "$VENDOR/usr-lib/polkit-1"
if pam_config_file no-such-service "$VENDOR_PATH" >/dev/null; then got=found; else got=missing; fi
check "a name found in no directory fails" "$got" "missing"

mapfile -t losers < <(pam_fprintd_services_losing_fingerprint \
  "$VENDOR/etc/common-auth" "$VENDOR_PATH")
losers_str=" ${losers[*]} "

for want in etc/sudo etc/sudo-i etc/other etc/gdm-password etc/su etc/su-l \
  etc/login etc/gdm-smartcard-sssd-or-password usr-lib/polkit-1; do
  case "$losers_str" in *" $VENDOR/$want "*) got=listed ;; *) got=absent ;; esac
  check "stock layout: $want loses fingerprint with the shared stack's line gone" \
    "$got" "listed"
done

# libpam reads /etc/pam.d/shadowed, which keeps fingerprint, and never the
# vendor copy beneath it - so neither may be quoted as a loss. gdm-fingerprint
# has fingerprint of its own and no shared stack; the rest have no auth phase.
for unwanted in etc/shadowed usr-lib/shadowed usr-lib/systemd-user etc/common-auth \
  etc/gdm-fingerprint etc/common-account etc/common-password etc/common-session \
  etc/common-session-noninteractive; do
  case "$losers_str" in *" $VENDOR/$unwanted "*) got=listed ;; *) got=absent ;; esac
  check "stock layout: $unwanted is not listed" "$got" "absent"
done

check "stock layout: exactly nine services lose fingerprint" "${#losers[@]}" "9"

# The /etc/pam.d-only view of the same tree, which is what the scan used to
# be: polkit is simply not in it.
mapfile -t losers < <(pam_fprintd_services_losing_fingerprint \
  "$VENDOR/etc/common-auth" "$VENDOR/etc")
case " ${losers[*]} " in *"/polkit-1 "*) got=listed ;; *) got=absent ;; esac
check "reading /etc/pam.d alone misses polkit - the scan has to follow libpam" \
  "$got" "absent"

check "stock layout: the question names sudo and polkit" \
  "$(pam_fprintd_shared_stack_prompts "$VENDOR/etc/common-auth" "$VENDOR_PATH")" \
  "sudo and polkit"

# --- every way a service reaches the shared stack (review of PR #20) ------
# `auth include` and `auth substack` as well as `@include`, keywords in any
# case, a comment or extra words after the name, and through another file -
# every form libpam accepts (measured; JOURNAL.md, 2026-09-26). Reading only a
# literal `@include common-auth` left five stock services out of the cost on
# a real Ubuntu 26.04, and would have left sudo out of the question had it
# been spelled `auth include`.
FORMS="$FIXTURES/forms"

for line in "@include common-auth" "@include common-auth # a comment" \
  "@include common-auth extra words" "@INCLUDE common-auth" \
  "auth include common-auth" "AUTH Include common-auth" \
  "-auth substack common-auth" "$(printf '  auth\tsubstack\tcommon-auth')"; do
  check "an include is read out of: $line" \
    "$(_pam_include_target "$line" || echo none)" "common-auth"
done

for line in "account include common-auth" "auth required pam_unix.so" \
  "# @include common-auth" "@include" "session include common-session"; do
  check "no auth-phase include in: $line" \
    "$(_pam_include_target "$line" || echo none)" "none"
done

mapfile -t losers < <(pam_fprintd_services_losing_fingerprint \
  "$FORMS/common-auth" "$FORMS")
losers_str=" ${losers[*]} "

for want in sudo other upper-case dashed-substack chain-top chain-mid own-below; do
  case "$losers_str" in *" $FORMS/$want "*) got=listed ;; *) got=absent ;; esac
  check "spelled another way: $want loses fingerprint" "$got" "listed"
done

# own-via-include keeps fingerprint through a line of its own that runs before
# the shared stack (own-below's runs after it, so it loses fingerprint anyway);
# fp-snippet and session-only never reach the shared stack; polkit-1 has no
# auth phase, so its cost is other's.
for unwanted in own-via-include fp-snippet session-only polkit-1 common-auth; do
  case "$losers_str" in *" $FORMS/$unwanted "*) got=listed ;; *) got=absent ;; esac
  check "spelled another way: $unwanted is not listed" "$got" "absent"
done

check "spelled another way: exactly seven services lose fingerprint" "${#losers[@]}" "7"

# libpam authenticates a polkit whose file has no auth phase with other's, and
# other loses fingerprint here - so the question has to name polkit, and the
# sudo that says `auth include` as well.
check "a sudo reached by auth include, and a polkit with no auth phase, are named" \
  "$(pam_fprintd_shared_stack_prompts "$FORMS/common-auth" "$FORMS")" \
  "sudo and polkit"

# README's per-service recipe leaves a service with a fingerprint line of its
# own *and* the shared stack: once the profile is back, it tries the reader
# twice. uninstall.sh names these before it re-enables the profile.
mapfile -t twice < <(pam_fprintd_services_asking_twice "$FORMS/common-auth" "$FORMS")
check "services with a fingerprint line of their own are the ones that ask twice" \
  "${twice[*]##*/}" "own-via-include"

# A service file the installing user cannot read is counted as a loss, not
# dropped and not left to print "Permission denied" into the cost. Skipped as
# root, which reads a mode-000 file regardless.
if [ "$(id -u)" != 0 ]; then
  UNREADABLE_TREE="$WORKDIR/unreadable-tree"
  mkdir -p "$UNREADABLE_TREE"
  cp "$FORMS/common-auth" "$UNREADABLE_TREE/"
  printf 'auth\tinclude\tcommon-auth\n' >"$UNREADABLE_TREE/polkit-1"
  chmod 000 "$UNREADABLE_TREE/polkit-1"
  check "a service file that cannot be read is named, quietly" \
    "$(pam_fprintd_shared_stack_prompts "$UNREADABLE_TREE/common-auth" "$UNREADABLE_TREE" 2>&1)" \
    "polkit"
  chmod 600 "$UNREADABLE_TREE/polkit-1"
fi

# The question itself, as install.sh asks it at both of its call sites. It
# defaults to yes, so it has to carry a cost whenever there is one.
check "the question names the prompts when there are any" \
  "$(pam_fprintd_conflict_question "sudo and polkit" 9)" \
  "Fix the lock screen? Fingerprint stops being offered in sudo and polkit prompts."
check "...and otherwise still states what is lost" \
  "$(pam_fprintd_conflict_question "" 4)" \
  "Fix the lock screen? The 4 services above fall back to the password."
check "...in the singular too" \
  "$(pam_fprintd_conflict_question "" 1)" \
  "Fix the lock screen? The service above falls back to the password."
check "...and is bare only when nothing is lost" \
  "$(pam_fprintd_conflict_question "" 0)" "Fix the lock screen?"

# --- the machine-wide TPM primary handle ----------------------------------
# bin/lib.sh's tpm_handle_is_wellformed / tpm_primary_handle_dependents, which
# is what uninstall.sh now consults before evicting a handle every user of the
# tool shares (GitHub issue #7, JOURNAL.md 2026-09-15). Pure filesystem +
# string logic, so it needs no TPM, no container and no root: the predicate
# takes a passwd-format file as its third argument for exactly this reason.
# The home directories have to be absolute paths into a throwaway tree, so the
# passwd fixture is generated here rather than committed.

# A handle read out of an unprivileged user's home ends up as tpm2_load's -C,
# which is spelled --parent-context and accepts a CONTEXT FILE PATH as well as
# a handle. So this check is what stands between that file's contents and a
# root-side open of an arbitrary path during authentication - the reject cases
# below are the point of it, not the accept case.
check "well-formed persistent handle accepted" \
  "$(tpm_handle_is_wellformed 0x81018000 && echo yes || echo no)" "yes"
for bad in "0X81018000" "0x81018000  extra" "" "0x71018000" "/tmp/evil.ctx" "0x8101800"; do
  check "malformed handle rejected: '$bad'" \
    "$(tpm_handle_is_wellformed "$bad" && echo yes || echo no)" "no"
done

HANDLE_TREE="$(mktemp -d)"
CLEANUP+=("$HANDLE_TREE")

mkhome() {
  local user="$1" handle="$2" with_blob="$3"
  local d="$HANDLE_TREE/$user/.local/share/tpm-keyring-unlock"
  mkdir -p "$d"
  [ "$handle" = "-" ] || printf '%s\n' "$handle" >"$d/primary.handle"
  [ "$with_blob" != "blob" ] || : >"$d/seal.priv"
  printf '%s:x:1001:1001::%s:/bin/bash\n' "$user" "$HANDLE_TREE/$user"
}

{
  printf 'root:x:0:0:root:/root:/bin/bash\n'
  mkhome alice   0x81018000 blob     # depends on it - the one that must be found
  mkhome bob     0x81018000 noblob   # handle file left behind, no sealed blob
  mkhome carol   0x81018001 blob     # sealed under a different handle
  mkhome dave    0x81018000 blob     # this is the uninstalling user
  mkhome erin    -          blob     # never persisted a primary at all
  printf 'ghost:x:1005:1005::%s/nowhere:/bin/bash\n' "$HANDLE_TREE"
  printf 'nohome:x:1006:1006:::/usr/sbin/nologin\n'
} >"$HANDLE_TREE/passwd"

deps="$(tpm_primary_handle_dependents 0x81018000 dave "$HANDLE_TREE/passwd" | sort | tr '\n' ' ')"
check "finds the other user who sealed under the same handle" "$deps" "alice "

# Each of these is a way the old code would have been wrong in the unsafe
# direction (claiming a dependency that isn't there, so refusing forever) or
# the dangerous one (missing a real dependency, so evicting anyway).
case "$deps" in *bob*)   got=listed ;; *) got=absent ;; esac
check "a stale handle file with no sealed blob is not a dependency" "$got" "absent"
case "$deps" in *carol*) got=listed ;; *) got=absent ;; esac
check "a user sealed under a different handle is not a dependency" "$got" "absent"
case "$deps" in *dave*)  got=listed ;; *) got=absent ;; esac
check "the uninstalling user is not counted as their own dependent" "$got" "absent"
case "$deps" in *erin*)  got=listed ;; *) got=absent ;; esac
check "a user who never persisted a primary is not a dependency" "$got" "absent"
case "$deps" in *ghost*) got=listed ;; *) got=absent ;; esac
check "a user whose home doesn't exist is skipped, not an error" "$got" "absent"

# Whitespace: seal.sh writes the handle with a trailing newline, and a file
# that picked up CRLF must still compare equal rather than silently reading
# as "nobody depends on this".
printf '0x81018000\r\n' >"$HANDLE_TREE/alice/.local/share/tpm-keyring-unlock/primary.handle"
deps_crlf="$(tpm_primary_handle_dependents 0x81018000 dave "$HANDLE_TREE/passwd" | tr '\n' ' ')"
check "a CRLF-terminated handle file still matches" "$deps_crlf" "alice "

# The empty result must be a SUCCESSFUL scan: uninstall.sh tells "nobody
# depends on this" apart from "couldn't check" purely by exit status, and
# fails closed on the latter. A non-zero exit here would turn every clean
# uninstall into a refusal.
if none="$(tpm_primary_handle_dependents 0x81018999 dave "$HANDLE_TREE/passwd")"; then
  got="ok:[$none]"
else
  got="nonzero-exit"
fi
check "a handle nobody uses returns empty AND exits zero" "$got" "ok:[]"

# --- nothing below the insertion point may consume PAM_AUTHTOK ------------
# install.sh puts `auth optional pam_tpm_keyring_authtok.so` immediately above
# the pam_gnome_keyring auth line, and that module sets PAM_AUTHTOK from the
# TPM before anyone has authenticated. The module never votes (PAM_IGNORE on
# every path), so the hazard is a password module BELOW it taking that token
# instead of prompting - pam_unix.so with try_first_pass - which would log
# somebody in on a secret nobody typed.
#
# Both directions are load-bearing, and the safe ones more so: a false
# "unsafe" refuses gdm-fingerprint, which is the entire scenario this tool
# exists for. See JOURNAL.md, 2026-09-15.
ORDERING="$FIXTURES/ordering"

for f in safe-direct safe-include safe-substack safe-continued \
         safe-fingerprint-only safe-autologin safe-nested safe-commented-out; do
  if pam_auth_insertion_point_is_safe "$ORDERING/$f" "$ORDERING"; then
    got=safe
  else
    got=refused
  fi
  check "insertion point accepted: $f" "$got" "safe"
done

# The second line of names is libpam's reading of a line that this check used
# to read differently, each one measured with pamtester (JOURNAL.md,
# 2026-09-26): a comment or extra words after an include, a comment ending in
# a backslash, keyword case, a module by absolute path, pam_systemd_home, a
# continuation libpam versions read differently, and an include that fails
# closed one level down.
for f in unsafe-keyring-first unsafe-unix-below unsafe-substack-below loop-below \
         unsafe-include-missing \
         unsafe-include-comment unsafe-include-extra unsafe-comment-backslash \
         unsafe-comment-line-backslash unsafe-upper-case unsafe-include-mixed-case \
         unsafe-at-include-upper unsafe-absolute-module unsafe-systemd-home \
         unsafe-ambiguous unsafe-ambiguous-include unsafe-nested-missing; do
  if pam_auth_insertion_point_is_safe "$ORDERING/$f" "$ORDERING"; then
    got=safe
  else
    got=refused
  fi
  check "insertion point refused: $f" "$got" "refused"
done

# The two that would break a real, working install if the predicate drifted
# back to asking what runs *above* the insertion point. gdm-fingerprint has
# no password module above it at all - pam_fprintd only answers yes/no - and
# is still perfectly safe, because nothing below it can consume PAM_AUTHTOK.
# gdm-password reaches its authenticator through @include common-auth.
if pam_auth_insertion_point_is_safe "$FIXTURES/shared/gdm-password" "$FIXTURES/shared"; then
  got=safe
else
  got=refused
fi
check "a real @include-based gdm-password stack is still accepted" "$got" "safe"

if pam_auth_insertion_point_is_safe "$VENDOR/etc/gdm-password" "$VENDOR_PATH"; then
  got=safe
else
  got=refused
fi
check "...and so is the stock Ubuntu 26.04 one, resolved across both directories" \
  "$got" "safe"

# An include below the insertion point is looked up where libpam looks it up:
# /etc/pam.d, then /usr/lib/pam.d, where libpam >= 1.5.3 finds includes too
# (measured; JOURNAL.md, 2026-09-25). Until then a name missing from
# /etc/pam.d answered "nothing below authenticates", so a vendor-only include
# carrying pam_unix.so try_first_pass was called safe to wire.
if pam_auth_insertion_point_is_safe "$VENDOR/etc/keyring-above-vendor-auth" "$VENDOR_PATH"; then
  got=safe
else
  got=refused
fi
check "a pam_unix.so reached through a vendor-only include is seen" "$got" "refused"

# The same file judged from /etc/pam.d alone - the old view - is refused as
# well: an include found nowhere is "could not tell", never "nothing there".
if pam_auth_insertion_point_is_safe "$VENDOR/etc/keyring-above-vendor-auth" "$VENDOR/etc"; then
  got=safe
else
  got=refused
fi
check "an include found in no directory is refused, not waved through" "$got" "refused"

# Following an include into the vendor directory must not turn into refusing
# everything that lives there.
if pam_auth_insertion_point_is_safe "$VENDOR/etc/keyring-above-vendor-session" "$VENDOR_PATH"; then
  got=safe
else
  got=refused
fi
check "a vendor-only include with no auth module in it is still safe" "$got" "safe"

# An absolute include path is taken as it stands, as libpam takes it. Glued
# onto the directory ("/etc/pam.d//abs/path") it was missing, and so safe.
# Both directions are checked: "refused" alone is also what an unresolvable
# include gives, so only the safe half proves the path was really followed.
# libpam splits a line on blanks, so an absolute path with one in it cannot be
# written at all - from such a checkout path there is nothing to test.
verdict() {
  if pam_auth_insertion_point_is_safe "$@"; then echo safe; else echo refused; fi
}
if [[ "$FIXTURES" =~ [[:space:]] ]]; then
  echo "skip - absolute include paths: the checkout path contains a blank"
else
  printf '#%%PAM-1.0\nauth\toptional\tpam_gnome_keyring.so\n@include %s\n' \
    "$ORDERING/common-auth" >"$WORKDIR/keyring-above-absolute"
  check "an absolute @include path below the keyring line is followed" \
    "$(verdict "$WORKDIR/keyring-above-absolute" "$ORDERING")" "refused"
  printf '#%%PAM-1.0\nauth\toptional\tpam_gnome_keyring.so\n@include %s\n' \
    "$FIXTURES/forms/session-only" >"$WORKDIR/keyring-above-absolute-harmless"
  check "...and one naming a file with no auth phase is followed to a safe verdict" \
    "$(verdict "$WORKDIR/keyring-above-absolute-harmless" "$ORDERING")" "safe"
fi

# A read that fails after the file checked out as readable - /proc/self/mem
# is a regular, readable file that fails every read with EIO - is "could not
# tell", not "no lines". Linux only; skipped where that file is missing.
if [ -f /proc/self/mem ]; then
  printf '#%%PAM-1.0\nauth\toptional\tpam_gnome_keyring.so\n@include /proc/self/mem\n' \
    >"$WORKDIR/keyring-above-read-error"
  check "an include that fails mid-read is refused" \
    "$(verdict "$WORKDIR/keyring-above-read-error" "$ORDERING" 2>&1)" "refused"
fi

# A stack an earlier version wired gets the same verdict with our line in it:
# the line sits above the keyring line, where nothing is looked at. install.sh
# relies on that to re-check wired stacks instead of skipping them.
sed -E "/${PAM_GNOME_KEYRING_AUTH_RE}/i auth    optional        pam_tpm_keyring_authtok.so" \
  "$VENDOR/etc/keyring-above-vendor-auth" >"$WORKDIR/wired-vendor-auth"
check "a wired stack that fails the check today is still refused" \
  "$(verdict "$WORKDIR/wired-vendor-auth" "$VENDOR_PATH")" "refused"
sed -E "/${PAM_GNOME_KEYRING_AUTH_RE}/i auth    optional        pam_tpm_keyring_authtok.so" \
  "$VENDOR/etc/gdm-password" >"$WORKDIR/wired-gdm-password"
check "...and a wired stock gdm-password is still accepted" \
  "$(verdict "$WORKDIR/wired-gdm-password" "$VENDOR_PATH")" "safe"

# --- reading a line the way libpam does ------------------------------------
# _pam_logical_lines(), which every predicate reads through. Each rule was
# measured with pamtester first (JOURNAL.md, 2026-09-26).
# The backslashes at the ends of these lines are the point: they are PAM
# continuations, written literally.
# shellcheck disable=SC1003
printf '%s\n' \
  'AUTH  Required pam_Unix.so ARG' \
  'auth [SUCCESS=DONE default=die] pam_x.so' \
  '@INCLUDE Common-Auth # trailing words' \
  '# a comment line \' \
  'auth optional pam_a.so # a comment \' \
  'auth \   ' \
  '  required pam_b.so' \
  'auth \' \
  '# libpam 1.7 ends the continuation here' \
  'required pam_c.so' >"$WORKDIR/line-model"
LOGICAL_RC=0
LOGICAL="$(_pam_logical_lines "$WORKDIR/line-model")" || LOGICAL_RC=$?
line_check() {
  if grep -qE "$2" <<<"$LOGICAL"; then got=yes; else got=no; fi
  check "$1" "$got" "${3:-yes}"
}
line_check "type and plain control are folded to lower case, the module is not" \
  '^auth  required pam_Unix\.so ARG$'
line_check "a bracketed control keeps its case, as libpam needs it" \
  '^auth \[SUCCESS=DONE default=die\] pam_x\.so$'
line_check "@INCLUDE is read as @include, the file name keeps its case" \
  '^@include Common-Auth *$'
line_check "a comment ending in a backslash continues nothing" \
  '^auth optional pam_a\.so *$'
line_check "a backslash with trailing blanks still continues" \
  '^auth +required pam_b\.so$'
line_check "a comment line inside a continuation ends it (the libpam 1.7 reading)" \
  '^required pam_c\.so$'
check "...which is a file libpam versions read differently: exit status 2" \
  "$LOGICAL_RC" "2"
rc=0
_pam_logical_lines "$ORDERING/safe-continued" >/dev/null || rc=$?
check "a plain continuation is not ambiguous: exit status 0" "$rc" "0"
rc=0
printf 'auth required pam_permit.so \\\n' >"$WORKDIR/continued-into-eof"
_pam_logical_lines "$WORKDIR/continued-into-eof" >/dev/null || rc=$?
check "a continuation that runs into the end of the file is ambiguous too" "$rc" "2"

# An include that exists but cannot be read is "could not tell" too. Skipped
# as root, which reads a mode-000 file regardless.
if [ "$(id -u)" != 0 ]; then
  UNREADABLE="$WORKDIR/unreadable"
  mkdir -p "$UNREADABLE"
  printf 'auth\trequired\tpam_permit.so\n' >"$UNREADABLE/sealed-off"
  chmod 000 "$UNREADABLE/sealed-off"
  printf '#%%PAM-1.0\nauth\toptional\tpam_gnome_keyring.so\n@include sealed-off\n' \
    >"$UNREADABLE/keyring-above-unreadable"
  if pam_auth_insertion_point_is_safe "$UNREADABLE/keyring-above-unreadable" "$UNREADABLE"; then
    got=safe
  else
    got=refused
  fi
  check "an include that cannot be read is refused" "$got" "refused"
  chmod 600 "$UNREADABLE/sealed-off"
fi

# No pam_gnome_keyring auth line means no insertion point, which is not the
# same as a safe one.
if pam_auth_insertion_point_is_safe "$FIXTURES/no-match" "$FIXTURES"; then
  got=safe
else
  got=refused
fi
check "a stack with no keyring auth line is not called safe" "$got" "refused"

# --- only vetted modules may run after the helper (2026-09-26) ------------
# The insertion check lets through nothing below the keyring line but the
# modules on PAM_AFTER_TOKEN_MODULE_RE, read with a strict grammar. The review
# of PR #20 found lines libpam runs that the old "known password modules"
# rule could not see; every one of them has to come back refused here, and
# the stacks distributions actually ship have to come back safe.
BELOW="$WORKDIR/below-keyring"
mkdir -p "$BELOW"
cp "$ORDERING/common-auth" "$ORDERING/common-account" "$BELOW/"
below_keyring() {
  printf '#%%PAM-1.0\nauth    optional        pam_gnome_keyring.so\n%s\n' "$1" >"$BELOW/stack"
  verdict "$BELOW/stack" "$BELOW"
}

# modules that take the token and are not pam_unix: the old list missed them
for line in \
  'auth sufficient pam_extrausers.so try_first_pass' \
  'auth sufficient pam_userdb.so db=/etc/vsftpd/users' \
  'auth sufficient pam_exec.so expose_authtok /usr/local/bin/check' \
  'auth optional pam_brand_new.so' \
  'auth required /usr/lib/x86_64-linux-gnu/security/pam_permit.so'; do
  check "not on the list, refused: $line" "$(below_keyring "$line")" "refused"
done

# the ways of writing a line that libpam runs and the old check could not read
for line in \
  '[auth] sufficient pam_unix.so try_first_pass' \
  '[-auth] sufficient pam_unix.so try_first_pass' \
  'auth [default=ignore]pam_unix.so try_first_pass' \
  'auth sufficient [pam_unix.so] try_first_pass' \
  'auth [default=ignore\] success=ok] pam_permit.so' \
  'auth [include] common-auth' \
  '-@include common-auth' \
  '[@include] common-auth' \
  'auth weird pam_permit.so'; do
  check "not read, refused: $line" "$(below_keyring "$line")" "refused"
done

# and what the stacks distributions ship put below the keyring line
for line in \
  'auth required pam_permit.so' \
  '-auth optional pam_kwallet5.so' \
  'auth [success=ok default=ignore] pam_echo.so hello' \
  '@include common-account' \
  'session include common-auth' \
  'password required pam_unix.so'; do
  check "vetted, safe: $line" "$(below_keyring "$line")" "safe"
done

# The refusal says why, for install.sh to print next to the stack.
below_keyring 'auth sufficient pam_extrausers.so try_first_pass' >/dev/null
pam_auth_insertion_point_is_safe "$BELOW/stack" "$BELOW" || true
case "$PAM_INSERTION_REFUSAL" in
  *pam_extrausers.so*) got=named ;;
  *) got="$PAM_INSERTION_REFUSAL" ;;
esac
check "the refusal names the module it did not know" "$got" "named"

# The writer and the check have to mean the same line. sed inserts above
# every physical line matching the keyring regex; libpam ignores
# `auth optional#x pam_gnome_keyring.so` (the comment leaves no module), and
# the check looks below the first keyring line libpam sees - so our line
# would land above a pam_unix.so the check never looked at.
printf '%s\n' '#%PAM-1.0' 'auth    optional#x pam_gnome_keyring.so' \
  'auth    sufficient      pam_unix.so try_first_pass' \
  'auth    optional        pam_gnome_keyring.so' >"$BELOW/two-anchors"
check "two lines sed would insert above: refused" \
  "$(verdict "$BELOW/two-anchors" "$BELOW")" "refused"
printf '%s\n' '#%PAM-1.0' 'auth    optional        pam_gnome_keyring.so # unlock' \
  >"$BELOW/commented-anchor"
check "a keyring line with a comment on it: refused" \
  "$(verdict "$BELOW/commented-anchor" "$BELOW")" "refused"

# Services that include the stack run our line too, and everything after the
# include runs after it. libpam builds one stack out of both.
INCLUDERS="$WORKDIR/includers"
mkdir -p "$INCLUDERS"
printf '%s\n' '#%PAM-1.0' 'auth    optional        pam_gnome_keyring.so' >"$INCLUDERS/cand"
check "a stack nothing includes: safe" "$(verdict "$INCLUDERS/cand" "$INCLUDERS")" "safe"
printf '%s\n' 'auth    include    cand' 'auth    required   pam_permit.so' >"$INCLUDERS/includer-ok"
check "an includer that only runs vetted modules after it: still safe" \
  "$(verdict "$INCLUDERS/cand" "$INCLUDERS")" "safe"
printf '%s\n' 'session include cand' 'session required pam_unix.so' >"$INCLUDERS/session-only"
check "an include in another phase does not count" \
  "$(verdict "$INCLUDERS/cand" "$INCLUDERS")" "safe"
printf '%s\n' 'auth    include    cand' 'auth    sufficient pam_unix.so try_first_pass' \
  >"$INCLUDERS/includer-bad"
check "an includer that runs pam_unix.so after it: refused" \
  "$(verdict "$INCLUDERS/cand" "$INCLUDERS")" "refused"
rm "$INCLUDERS/includer-bad"
printf '%s\n' 'auth    include    mid' 'auth    sufficient pam_unix.so try_first_pass' >"$INCLUDERS/top"
printf '%s\n' '@include cand' >"$INCLUDERS/mid"
check "...and one that includes it through another file: refused" \
  "$(verdict "$INCLUDERS/cand" "$INCLUDERS")" "refused"
rm "$INCLUDERS/top" "$INCLUDERS/mid"
printf '%s\n' '-@include cand' 'auth    sufficient pam_unix.so try_first_pass' >"$INCLUDERS/dashed"
check "an includer written in a way this tool does not read: refused" \
  "$(verdict "$INCLUDERS/cand" "$INCLUDERS")" "refused"
rm "$INCLUDERS/dashed"

# The case fold runs in the C locale. In a Turkish one bash folds `I` to a
# dotless `ı`, so `INCLUDE` stopped reading as `include`. Skipped where the
# locale is not installed.
if locale -a 2>/dev/null | grep -qi '^tr_TR\.utf-\?8$'; then
  printf '%s\n' '#%PAM-1.0' 'auth    optional        pam_gnome_keyring.so' \
    'AUTH    INCLUDE         common-auth' >"$BELOW/upper-include"
  check "a Turkish locale reads AUTH INCLUDE as libpam does (and refuses it)" \
    "$(LC_ALL=tr_TR.UTF-8 verdict "$BELOW/upper-include" "$BELOW")" "refused"
  printf '%s\n' '#%PAM-1.0' 'auth    optional        pam_gnome_keyring.so' \
    'AUTH    INCLUDE         common-account' >"$BELOW/upper-harmless"
  check "...and follows the include rather than calling it unreadable" \
    "$(LC_ALL=tr_TR.UTF-8 verdict "$BELOW/upper-harmless" "$BELOW")" "safe"
fi

# --- a gdm-fingerprint with no keyring line at all (GitHub issue #23) -------
# Fedora ships gdm-fingerprint with no pam_gnome_keyring.so line in any phase,
# so the candidate grep never matched it and install.sh passed it over without
# a word: fingerprint logins kept prompting. install.sh now adds the keyring
# lines along with its own, after the last auth line and the last session
# line. The fixture tree is the stock Fedora 44 set - gdm-50.3-1.fc44 and
# pam-1.7.2-2.fc44, plus authselect-1.7.1's local profile generated with
# with-fingerprint and with-silent-lastlog - and the expected result is
# checked in, read by eye, rather than computed by the code under test.
F44="$FIXTURES/fedora44"
EXPECTED="$REPO_DIR/test/fixtures/expected"
yes_no() {
  if "$@"; then echo yes; else echo "no: $PAM_INSERTION_REFUSAL"; fi
}
is_ours() {
  if pam_keyring_lines_are_ours "$1"; then echo yes; else echo no; fi
}

if grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$F44/gdm-fingerprint"; then got=candidate; else got=passed-over; fi
check "Fedora's gdm-fingerprint is no keyring candidate by itself" "$got" "passed-over"
check "...so the keyring lines may be added to it" \
  "$(yes_no pam_keyring_lines_can_be_added "$F44/gdm-fingerprint" "$F44")" "yes"

F44_WIRED="$WORKDIR/f44-gdm-fingerprint-wired"
pam_keyring_lines_add <"$F44/gdm-fingerprint" >"$F44_WIRED"
if cmp -s "$F44_WIRED" "$EXPECTED/fedora44-gdm-fingerprint"; then got=as-expected; else got=differs; fi
check "the auth lines land after the last auth line, the session one ahead of postlogin" \
  "$got" "as-expected"
check "the edited file is recognised as install.sh's" \
  "$(is_ours "$F44_WIRED")" "yes"
if pam_keyring_lines_remove <"$F44_WIRED" | cmp -s - "$F44/gdm-fingerprint"; then got=identical; else got=differs; fi
check "...and taking them out gives the original back byte for byte" "$got" "identical"
check "the stock file is not mistaken for one install.sh edited" \
  "$(is_ours "$F44/gdm-fingerprint")" "no"
check "nor is a stack wired the ordinary way" \
  "$(is_ours "$FIXTURES/already-patched")" "no"

# On a re-run the edited file is an ordinary candidate, with our line right
# above its keyring line, and it has to pass the check there - or install.sh
# would take it straight back out.
F44_TREE="$WORKDIR/f44-tree"
mkdir -p "$F44_TREE"
cp "$F44"/* "$F44_TREE/"
cp "$F44_WIRED" "$F44_TREE/gdm-fingerprint"
check "the edited gdm-fingerprint passes the insertion check as it sits" \
  "$(verdict "$F44_TREE/gdm-fingerprint" "$F44_TREE")" "safe"
if grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$F44_TREE/gdm-fingerprint"; then got=candidate; else got=passed-over; fi
check "...as the candidate it now is" "$got" "candidate"
check "...and the re-check install.sh gives a wired stack lets it stay" \
  "$(yes_no pam_wired_stack_is_safe "$F44_TREE/gdm-fingerprint" "$F44_TREE")" "yes"

# The pre-install copy that install.sh's edit provably came from is what
# uninstall.sh restores; a stale one is never taken.
cp "$F44/gdm-fingerprint" "$F44_TREE/gdm-fingerprint.bak-20260101000000"
printf '# stale\n' | cat - "$F44/gdm-fingerprint" >"$F44_TREE/gdm-fingerprint.bak-20260201000000"
check "the exact pre-install copy is found, and the stale newer one skipped" \
  "$(pam_keyring_exact_original "$F44_TREE/gdm-fingerprint" || echo none)" \
  "$F44_TREE/gdm-fingerprint.bak-20260101000000"
rm -f "$F44_TREE"/gdm-fingerprint.bak-*

# The stacks Fedora 44 does ship with a keyring line keep their verdict
# (PR #21's table), and the two with none, other than gdm-fingerprint, are
# still left alone: smartcard and the greeter's own session are not this
# tool's business.
for f in gdm-password gdm-autologin gdm-switchable-auth; do
  check "Fedora 44 $f still passes the insertion check" "$(verdict "$F44/$f" "$F44")" "safe"
done
for f in gdm-smartcard gdm-launch-environment; do
  if grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$F44/$f"; then got=candidate; else got=passed-over; fi
  check "Fedora 44 $f is no candidate" "$got" "passed-over"
done

# Switching on authselect's with-ecryptfs puts pam_ecryptfs into postlogin's
# auth phase. pam_ecryptfs is not on the vetted list - but our lines go after
# postlogin, so it runs before the token exists and nothing has to vet it.
awk '/^session/ && !done { print "auth        optional                   pam_ecryptfs.so unwrap"; done = 1 } { print }' \
  "$F44/postlogin" >"$F44_TREE/postlogin"
cp "$F44/gdm-fingerprint" "$F44_TREE/gdm-fingerprint"
if grep -q '^auth.*pam_ecryptfs' "$F44_TREE/postlogin"; then got=present; else got=missing; fi
check "(the ecryptfs fixture really has its auth line)" "$got" "present"
check "with ecryptfs in postlogin's auth phase, the lines may still be added" \
  "$(yes_no pam_keyring_lines_can_be_added "$F44_TREE/gdm-fingerprint" "$F44_TREE")" "yes"
cp "$F44/postlogin" "$F44_TREE/postlogin"

# A service that includes gdm-fingerprint and runs pam_unix after it would
# take the token the edited file hands on. The draft is checked in a scratch
# directory, so the includers have to be looked up under the real name.
printf '%s\n' 'auth    include    gdm-fingerprint' \
  'auth    sufficient pam_unix.so try_first_pass' >"$F44_TREE/includes-fingerprint"
check "an includer that runs pam_unix.so after gdm-fingerprint: refused" \
  "$(yes_no pam_keyring_lines_can_be_added "$F44_TREE/gdm-fingerprint" "$F44_TREE")" \
  "no: includes-fingerprint includes gdm-fingerprint, and after that: pam_unix.so runs after the keyring line, and is not on the list of modules known to leave PAM_AUTHTOK alone"
rm -f "$F44_TREE/includes-fingerprint"

# What the filter will not take on, each with its reason.
keyringless() {
  printf '%s\n' "$@" >"$F44_TREE/gdm-fingerprint"
  yes_no pam_keyring_lines_can_be_added "$F44_TREE/gdm-fingerprint" "$F44_TREE"
}
case "$(keyringless 'auth substack fingerprint-auth' 'session optional pam_gnome_keyring.so auto_start')" in
  "no: "*pam_gnome_keyring*) got=refused ;; *) got=accepted ;;
esac
check "a keyring line in another phase only: left alone" "$got" "refused"
case "$(keyringless 'auth substack fingerprint-auth' "$PAM_TPM_LINE" 'session include postlogin')" in
  "no: this tool's line"*) got=refused ;; *) got=accepted ;;
esac
check "our line with no keyring line under it: left alone, and said so" "$got" "refused"
# shellcheck disable=SC1003
case "$(keyringless 'auth substack \' '  fingerprint-auth' 'session include postlogin')" in
  "no: "*) got=refused ;; *) got=accepted ;;
esac
check "a continued line: refused" "$got" "refused"
case "$(keyringless 'auth substack fingerprint-auth')" in
  "no: "*session*) got=refused ;; *) got=accepted ;;
esac
check "no session phase of its own (it would be other's): refused" "$got" "refused"
case "$(keyringless 'session include postlogin')" in
  "no: "*) got=refused ;; *) got=accepted ;;
esac
check "no auth phase of its own: refused" "$got" "refused"

# Where the lines go: an @include pulls in every phase, so it counts as the
# last auth and the last session line; keywords are read case-blind, as
# libpam reads them.
printf '%s\n' 'AUTH  substack  fingerprint-auth' 'session include postlogin' \
  '@include gdm-extra' '# trailing comment' | pam_keyring_lines_add >"$WORKDIR/placement"
check "the lines go after an @include, the last line of both phases" \
  "$(sed -n '4,6p' "$WORKDIR/placement" | tr '\n' '|')" \
  "$PAM_TPM_LINE|$PAM_KEYRING_AUTH_LINE|$PAM_KEYRING_SESSION_LINE|"

# A last line with no newline: the filter ends it, so taking the lines out
# again is one byte off - which is why uninstall.sh restores the backup when
# there is one, and why that is exact.
printf 'auth substack fingerprint-auth\nsession include postlogin' >"$F44_TREE/gdm-fingerprint"
cp "$F44_TREE/gdm-fingerprint" "$F44_TREE/gdm-fingerprint.bak-20260101000000"
pam_keyring_lines_add <"$F44_TREE/gdm-fingerprint.bak-20260101000000" >"$F44_TREE/gdm-fingerprint"
check "no final newline: the edit is still recognised" \
  "$(is_ours "$F44_TREE/gdm-fingerprint")" "yes"
ORIG="$(pam_keyring_exact_original "$F44_TREE/gdm-fingerprint" || true)"
if [ -n "$ORIG" ] && cmp -s "$ORIG" "$F44_TREE/gdm-fingerprint.bak-20260101000000"; then got=exact; else got=missing; fi
check "...and the byte-exact original is there to restore" "$got" "exact"
rm -f "$F44_TREE"/gdm-fingerprint.bak-*

# Edited since install.sh wrote it: no longer provably ours, so uninstall.sh
# takes only its own line out, as from any other stack.
sed 's/pam_gnome_keyring.so auto_start/pam_gnome_keyring.so auto_start only_if=gdm/' \
  "$F44_WIRED" >"$F44_TREE/gdm-fingerprint"
check "a hand edit to one of the three lines: not ours any more" \
  "$(is_ours "$F44_TREE/gdm-fingerprint")" "no"
{ cat "$F44_WIRED"; echo 'session optional        pam_gnome_keyring.so'; } >"$F44_TREE/gdm-fingerprint"
check "a fourth keyring line someone added: not ours any more" \
  "$(is_ours "$F44_TREE/gdm-fingerprint")" "no"
awk -v l="$PAM_KEYRING_SESSION_LINE" '$0 != l' "$F44_WIRED" \
  | awk -v l="$PAM_KEYRING_SESSION_LINE" '{print} /^account/ && !d {print l; d=1}' >"$F44_TREE/gdm-fingerprint"
check "the session line moved somewhere else: not ours any more" \
  "$(is_ours "$F44_TREE/gdm-fingerprint")" "no"

# --- what the review of PR #24 found in the add path --------------------------
#
# Each check below failed, or had nothing to check, on the code as PR #24
# first had it. What libpam makes of the lines themselves is measured in
# test/runtime-test.sh.
REVIEW="$WORKDIR/review24"
mkdir -p "$REVIEW"
cp "$F44"/* "$REVIEW/"
review_add() {
  printf '%s\n' "$@" >"$REVIEW/gdm-fingerprint"
  yes_no pam_keyring_lines_can_be_added "$REVIEW/gdm-fingerprint" "$REVIEW"
}

# None of the added lines can vote, so the stack decides what it did before.
check "the auth keyring line cannot vote" \
  "$PAM_KEYRING_AUTH_LINE" "auth    [default=ignore] pam_gnome_keyring.so"
check "nor can the session one" \
  "$PAM_KEYRING_SESSION_LINE" "session [default=ignore] pam_gnome_keyring.so auto_start"

# A phase counts only with a module in it, the way libpam strings them
# together. Any @include used to count for both phases.
printf '%s\n' 'session optional pam_umask.so' >"$REVIEW/session-only"
check "an @include of a session-only file gives no auth phase" \
  "$(review_add '@include session-only' 'account required pam_nologin.so')" \
  "no: it has no keyring line, and no auth phase of its own to add one to"
check "nor does an auth include of one" \
  "$(review_add 'auth include session-only' 'session required pam_unix.so')" \
  "no: it has no keyring line, and no auth phase of its own to add one to"
check "an auth phase that comes wholly through an include counts" \
  "$(review_add 'auth include fingerprint-auth' 'session include postlogin')" "yes"
check "an include found nowhere is refused, not guessed at" \
  "$(review_add 'auth include no-such-file' 'session include postlogin')" \
  "no: it has no keyring line, and what its auth phase includes could not be followed"
check "a file with an auth-phase keyring line of its own is not for this path" \
  "$(yes_no pam_keyring_lines_can_be_added "$F44/gdm-password" "$F44")" \
  "no: it has an auth-phase pam_gnome_keyring.so line of its own"

# A backslash with blanks after it continues the line for libpam (1.5.2 and
# 1.7.2) and for _pam_logical_lines(); the precondition only knew a backslash
# that was the very last byte.
printf 'auth substack fingerprint-auth \\ \nauth include postlogin\nsession include postlogin\n' \
  >"$REVIEW/cont-blank"
if pam_config_has_no_line_continuations "$REVIEW/cont-blank"; then got=none; else got=continued; fi
check "a backslash with a blank after it is a continuation" "$got" "continued"
cp "$REVIEW/cont-blank" "$REVIEW/gdm-fingerprint"
case "$(yes_no pam_keyring_lines_can_be_added "$REVIEW/gdm-fingerprint" "$REVIEW")" in
  "no: "*backslash*) got=refused ;; *) got=accepted ;;
esac
check "...so the keyring lines are not added to such a file" "$got" "refused"
printf 'auth substack fingerprint-auth # \\\nauth include postlogin\n' >"$REVIEW/cont-comment"
if pam_config_has_no_line_continuations "$REVIEW/cont-comment"; then got=none; else got=continued; fi
check "...while a backslash behind a # continues nothing" "$got" "none"
if [ "$(id -u)" != 0 ]; then
  printf 'auth required pam_unix.so\n' >"$REVIEW/unreadable"
  chmod 000 "$REVIEW/unreadable"
  if pam_config_has_no_line_continuations "$REVIEW/unreadable"; then got=none; else got=refused; fi
  check "a file grep cannot read gives no answer either" "$got" "refused"
  chmod 600 "$REVIEW/unreadable"
fi

# A jump whose range takes in the place a line is added counts that line, and
# lands somewhere else - one that ran past the end of its phase, which libpam
# fails as a bad jump, stops failing.
check "a jump that ran past the end of the auth phase: refused" \
  "$(review_add 'auth required pam_env.so' 'auth sufficient pam_fprintd.so' \
    'auth [success=1 default=ignore] pam_succeed_if.so user ingroup nofinger' \
    'session include postlogin')" \
  "no: a jump in its auth phase reaches where the new line goes, and would land elsewhere with it there"
printf '%s\n' 'session [success=1 default=ignore] pam_succeed_if.so quiet' \
  'session [default=2] pam_unix.so' >"$REVIEW/overruns"
check "a jump in an include that runs on into the file around it: refused" \
  "$(review_add 'auth substack fingerprint-auth' 'session required pam_unix.so' 'session include overruns')" \
  "no: a jump in its session phase reaches where the new line goes, and would land elsewhere with it there"
printf '%s\n' 'auth [success=2 default=ignore] pam_unix.so' 'auth required pam_deny.so' >"$REVIEW/substacked"
check "a substack keeps its jumps to itself" \
  "$(review_add 'auth substack substacked' 'session include postlogin')" "yes"
check "Fedora's fingerprint-auth jumps, but not as far as the session line" \
  "$(yes_no pam_keyring_lines_can_be_added "$F44/gdm-fingerprint" "$F44")" "yes"

# The session line goes where gdm-password has its own, ahead of postlogin -
# out of the reach of postlogin's jumps - and after the last session line when
# something follows postlogin.
got="$(printf '%s\n' 'auth substack fingerprint-auth' 'session include postlogin' \
  'session required pam_unix.so' | pam_keyring_lines_add | tail -n 1)"
check "with a line after postlogin, the session line goes after the last one" \
  "$got" "$PAM_KEYRING_SESSION_LINE"

# The plan shows the lines where they land in this very file.
check "the plan's preview of Fedora's gdm-fingerprint" \
  "$(pam_keyring_lines_preview "$F44/gdm-fingerprint")" \
  "$(printf '%s\n' \
    '       auth        include       postlogin' \
    "     + $PAM_TPM_LINE" \
    "     + $PAM_KEYRING_AUTH_LINE" \
    '       ...' \
    '       session     include       fingerprint-auth' \
    "     + $PAM_KEYRING_SESSION_LINE" \
    '       session     include       postlogin')"

# Shape is not provenance. The same lines written by hand, then wired the
# ordinary way: install.sh's backup of that file has the keyring lines in it,
# so no keyring-free ancestor adds up to the file, and they stay.
PROV="$WORKDIR/provenance"
mkdir -p "$PROV"
cp "$F44_WIRED" "$PROV/gdm-fingerprint"
grep -v pam_tpm_keyring_authtok "$F44_WIRED" >"$PROV/gdm-fingerprint.bak-20260101000000"
check "keyring lines written by hand in install.sh's shape have its shape" \
  "$(is_ours "$PROV/gdm-fingerprint")" "yes"
check "...but no pre-install copy proves them this tool's" \
  "$(pam_keyring_exact_original "$PROV/gdm-fingerprint" || echo none)" "none"
cp "$F44/gdm-fingerprint" "$PROV/gdm-fingerprint.bak-20250101000000"
check "the copy install.sh takes before adding them is that proof" \
  "$(pam_keyring_exact_original "$PROV/gdm-fingerprint" || echo none)" \
  "$PROV/gdm-fingerprint.bak-20250101000000"

# A stack carrying our line with no keyring line under it fails the re-check
# install.sh gives every wired stack, so our line is planned back out rather
# than left ahead of whatever runs there. Such a stack used to drop out of
# install.sh's candidate list, and with it out of every check.
printf '%s\n' 'auth required pam_fprintd.so' "$PAM_TPM_LINE" \
  'auth sufficient pam_unix.so try_first_pass' >"$PROV/keyring-gone"
check "our line with its keyring line gone: the re-check refuses it" \
  "$(yes_no pam_wired_stack_is_safe "$PROV/keyring-gone" "$PROV")" \
  "no: it has no auth-phase pam_gnome_keyring.so line"
# And a file the keyring lines were added to is held, on every run, to the
# jump check they were added under: an include can change.
REWIRED="$WORKDIR/rewired"
mkdir -p "$REWIRED"
cp "$F44"/* "$REWIRED/"
cp "$F44_WIRED" "$REWIRED/gdm-fingerprint"
printf '%s\n' 'session [default=3] pam_unix.so' >>"$REWIRED/fingerprint-auth"
check "an include that later jumps into the session line: the re-check refuses it" \
  "$(yes_no pam_wired_stack_is_safe "$REWIRED/gdm-fingerprint" "$REWIRED")" \
  "no: a jump in its session phase reaches where the new line goes, and would land elsewhere with it there"

# What libpam reads from the vendor directory is listed, not passed over: the
# fingerprint service, or a keyring stack. Shadowed copies and non-service
# names are not.
VEND="$WORKDIR/vendor-only"
mkdir -p "$VEND/etc" "$VEND/usr-lib"
cp "$F44/gdm-fingerprint" "$VEND/usr-lib/gdm-fingerprint"
cp "$F44/gdm-fingerprint" "$VEND/usr-lib/gdm-fingerprint.rpmnew"
printf '%s\n' 'auth optional pam_gnome_keyring.so' >"$VEND/usr-lib/keyring-shadowed"
cp "$VEND/usr-lib/keyring-shadowed" "$VEND/etc/keyring-shadowed"
printf '%s\n' 'auth optional pam_gnome_keyring.so' >"$VEND/usr-lib/keyring-vendor"
printf '%s\n' 'session optional pam_umask.so' >"$VEND/usr-lib/no-keyring"
check "stacks read from the vendor directory are named, not passed over" \
  "$(pam_stacks_outside "$VEND/etc" "$VEND/etc:$VEND/usr-lib" | tr '\n' ' ')" \
  "$VEND/usr-lib/gdm-fingerprint $VEND/usr-lib/keyring-vendor "

# On a 64-bit Fedora or openSUSE /lib/security and /usr/lib/security hold the
# 32-bit modules once 32-bit PAM is installed; the native directory comes
# first.
dirs=" ${PAM_MODULE_DIR_CANDIDATES[*]} "
case "${dirs%% /usr/lib64/security *}" in
  *" /lib/security"* | *" /usr/lib/security"*) got=32-bit-first ;;
  *) got=native-first ;;
esac
check "/usr/lib64/security is tried before the directories 32-bit PAM fills" "$got" "native-first"

# --- the predicates have to give the SAME answer every time ---------------
#
# Reported as mtriam/tpm-keyring-unlock#1: under `set -o pipefail` (which
# install.sh sets), a predicate written as `_pam_logical_lines "$f" | grep -q`
# returns a random verdict. grep -q exits on the first match, the shell
# function feeding it dies of SIGPIPE, and pipefail promotes that 141 to a
# failed predicate - so the same file was called safe on one call and unsafe
# on the next, and install.sh's printed plan stopped matching what it wired.
#
# The stack below is padded past the match on purpose. On a short file the
# race is a coin flip that depends on the machine (the reporter saw 5-10% of
# runs, this repo's own machine 0/1000), which would make this test pass by
# luck; with several hundred lines after the match the writer is still going
# when grep leaves, so the old code fails every single iteration and the test
# has teeth anywhere it runs.
STABILITY_DIR="$(mktemp -d)"
CLEANUP+=("$STABILITY_DIR")
{
  echo "auth    optional    pam_gnome_keyring.so"
  # pam_echo because the insertion check only lets vetted modules run below
  # the keyring line; the padding still has to come back "safe" every time
  for i in $(seq 1 400); do echo "auth    optional    pam_echo.so filler $i"; done
} >"$STABILITY_DIR/padded-stack"

verdicts=""
for _ in $(seq 1 200); do
  if pam_auth_insertion_point_is_safe "$STABILITY_DIR/padded-stack" "$STABILITY_DIR"; then
    verdicts="${verdicts}s"
  else
    verdicts="${verdicts}u"
  fi
done
check "pam_auth_insertion_point_is_safe: 200 identical verdicts under pipefail" \
  "$(printf '%s' "$verdicts" | tr -d 's' | wc -c)" "0"

{
  echo "auth    [success=1 default=ignore]    pam_fprintd.so"
  for i in $(seq 1 400); do echo "auth    optional    pam_filler_$i.so"; done
} >"$STABILITY_DIR/padded-shared"

verdicts=""
for _ in $(seq 1 200); do
  if pam_fprintd_in_shared_stack "$STABILITY_DIR/padded-shared"; then
    verdicts="${verdicts}y"
  else
    verdicts="${verdicts}n"
  fi
done
check "pam_fprintd_in_shared_stack: 200 identical verdicts under pipefail" \
  "$(printf '%s' "$verdicts" | tr -d 'y' | wc -c)" "0"

# This one needs a stack that should come back SANE, not the one above. Its
# first grep is negated, so a SIGPIPE there reads as "no fprintd line" - the
# answer it was going to give anyway on a clean file. The damage is in its
# second grep, the one that has to find a real authenticator: that match is on
# line 1 here, so the old code left the writer mid-file, took 141, and declared
# a perfectly good post-fprintd stack insane - which is what install.sh checks
# before putting the file back.
{
  echo "auth    [success=1 default=ignore]    pam_unix.so nullok"
  for i in $(seq 1 400); do echo "auth    optional    pam_filler_$i.so"; done
} >"$STABILITY_DIR/padded-clean"

verdicts=""
for _ in $(seq 1 200); do
  if pam_shared_stack_is_sane_without_fprintd "$STABILITY_DIR/padded-clean"; then
    verdicts="${verdicts}y"
  else
    verdicts="${verdicts}n"
  fi
done
check "pam_shared_stack_is_sane_without_fprintd: 200 identical verdicts under pipefail" \
  "$(printf '%s' "$verdicts" | tr -d 'y' | wc -c)" "0"

# pam_keyring_lines_are_ours() asks grep -q whether anything keyring-ish is
# left once its lines are out. Padded so that a filter on the left of a pipe
# would still be writing when grep leaves - the answer must stay "ours".
{
  echo "auth    substack    fingerprint-auth"
  for i in $(seq 1 400); do echo "account optional    pam_echo.so filler $i"; done
  echo "session include     postlogin"
} | pam_keyring_lines_add >"$STABILITY_DIR/padded-keyringless"

verdicts=""
for _ in $(seq 1 200); do
  if pam_keyring_lines_are_ours "$STABILITY_DIR/padded-keyringless"; then
    verdicts="${verdicts}y"
  else
    verdicts="${verdicts}n"
  fi
done
check "pam_keyring_lines_are_ours: 200 identical verdicts under pipefail" \
  "$(printf '%s' "$verdicts" | tr -d 'y' | wc -c)" "0"

echo
if [ "$fail" -eq 0 ]; then
  echo "All regex/detection tests passed."
else
  echo "Some regex/detection tests FAILED." >&2
fi
exit "$fail"

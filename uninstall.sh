#!/usr/bin/env bash
# Reverses install.sh. Safe to run even if only some steps were applied.
set -euo pipefail

DATA_DIR="$HOME/.local/share/tpm-keyring-unlock"
HELPER_DST="/usr/local/sbin/tpm-keyring-unseal"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib.sh
source "$REPO_DIR/bin/lib.sh"

confirm() {
  local prompt="$1"
  local ans
  # Defaults to yes: an empty answer accepts. A failed read (EOF, i.e. no
  # terminal) is a "no", so nothing here can be auto-approved by a pipe.
  read -rp "$prompt [Y/n] " ans || return 1
  [[ ! "$ans" =~ ^[Nn][Oo]?$ ]]
}

# Same, but an empty answer DECLINES. Used for evicting the TPM primary,
# which is the one step in this script whose blast radius is the whole
# machine rather than this account, and which nothing can undo without every
# affected user re-running bin/seal.sh. Declining costs one TPM NV slot;
# accepting wrongly costs other people their keyring unlock, so the default
# belongs on "don't". See JOURNAL.md, 2026-09-15.
confirm_default_no() {
  local prompt="$1"
  local ans
  read -rp "$prompt [y/N] " ans || return 1
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# One timestamp for the whole run, so a file touched by two different steps
# below gets exactly one backup, holding its pristine pre-run content - same
# rule install.sh follows.
RUN_TS="$(date +%Y%m%d%H%M%S)"

# Backs a PAM file up before its first modification in this run. Undoing an
# edit to a login-critical file is still an edit to a login-critical file, so
# it gets the same .bak-<timestamp> copy the install side takes.
backup_pam_file() {
  local f="$1" bak="$1.bak-$RUN_TS"
  [ -e "$bak" ] || sudo cp "$f" "$bak"
}

# Every prompt below defaults to yes, so a run with no terminal must not be
# allowed to answer them by hitting EOF. read() failing counts as "no" in
# confirm() for that reason, but bail out up front anyway rather than
# half-running and then dying on "sudo: a terminal is required to
# authenticate" partway through.
if [ ! -t 0 ]; then
  echo "This script is interactive - run it directly from a terminal." >&2
  exit 1
fi

echo "== tpm-keyring-unlock uninstaller =="
echo

# Worked out once, up front, because the very first step below already
# affects other people: removing the PAM line from a shared service stops
# their keyring auto-unlocking just as surely as deleting the module does.
# Whoever is answering these prompts should know that before the first one,
# not after three of them. Best-effort and non-fatal - other users' data dirs
# are 0700, so this needs root, and a declined sudo just means we say less.
OTHER_SEALED=""
if command -v getent >/dev/null 2>&1; then
  OTHER_SEALED="$(sudo bash -c '
         while IFS=: read -r u _ _ _ _ h _; do
           [ -n "$u" ] && [ -n "$h" ] || continue
           [ "$u" != "$1" ] || continue
           [ -f "$h/.local/share/tpm-keyring-unlock/seal.priv" ] || continue
           printf "%s\n" "$u"
         done < <(getent passwd)
       ' _ "$USER" 2>/dev/null || true)"
fi
if [ -n "$OTHER_SEALED" ]; then
  echo "Heads up: other users have sealed secrets on this machine -"
  echo "$OTHER_SEALED" | sed 's/^/  /'
  echo "The PAM lines, the module and the helper are shared by all of you."
  echo "Removing any of them stops their keyring auto-unlocking too, and they"
  echo "would need to re-install to get it back. Their sealed secrets and"
  echo "keyring passwords are untouched either way."
  echo
fi

# --- 1. remove the PAM stack line ---------------------------------------
# Scans every /etc/pam.d/ service, not just ones named after fingerprints:
# install.sh patches any service with an auth-phase pam_gnome_keyring.so
# line (gdm-password included, once system-wide fingerprint auth is on).
for f in /etc/pam.d/*; do
  [ -f "$f" ] || continue
  if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi
  if grep -q pam_tpm_keyring_authtok.so "$f"; then
    echo "Found the injected line in $f"
    if confirm "Remove it?"; then
      backup_pam_file "$f"
      sudo sed -i '/pam_tpm_keyring_authtok\.so/d' "$f"
      echo "Removed (previous content backed up as $f.bak-$RUN_TS)."
    fi
  fi
done

# --- 1b. undo the fingerprint attempt-stack edit -------------------------
# Two ways back, best first:
#
#   exact     restore the .bak-<timestamp> copy install.sh took before it
#             edited the file - but only one that is provably the direct
#             ancestor of what's on disk now (see pam_fprintd_exact_original
#             below). This is the only path that brings back an explicit
#             timeout=/max-tries= the distro had set, since unharden has no
#             way to know what was there before.
#   defaults  failing that, strip the attempt lines and the options install.sh
#             set, leaving one pam_fprintd.so line on the module's own
#             defaults (30s idle, and one bad scan ends fingerprint for that
#             prompt - see JOURNAL.md, 2026-09-14).
#
# pam_fprintd_stack_is_generated() is the gate, not "unharden would change
# something": unharden strips max-tries=1, which Debian's pam-auth-update
# writes into common-auth itself, so the looser test offered to "restore" a
# shared stack install.sh refuses to touch by design. A file that carries our
# attempt lines but fails that gate has been edited since, so it gets a
# warning rather than a silent skip - it is the one case where the user walks
# away thinking everything is reverted when it isn't. See JOURNAL.md,
# 2026-09-15.

for f in /etc/pam.d/*; do
  [ -f "$f" ] || continue
  if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi

  HAS_ATTEMPTS=false
  if grep -qE "$PAM_FPRINTD_RETRY_LINE_RE" "$f"; then HAS_ATTEMPTS=true; fi
  # timeout=-1 is a *legacy* signature: versions of this tool before
  # 2026-09-15 put it on every attempt, and no distro ships it, so unlike
  # max-tries=1 (which Debian's own pam-auth-update writes into common-auth)
  # it cannot be confused with somebody else's config. Checked separately so
  # an older install whose attempt lines are gone but whose options are still
  # ours - a partial hand edit - is still offered, instead of being skipped in
  # silence with this tool's settings left on a login path.
  #
  # Current installs leave no such single-line signature, because max-tries=1
  # is all they set and that is genuinely ambiguous. Stated rather than
  # papered over: a current stack whose attempt lines someone deleted by hand
  # is not detected here. That leftover is also far milder than timeout=-1 was
  # - one scan per prompt, which is what the distro's own line does on a bad
  # scan anyway - and the attempt lines remain the reliable marker for every
  # file this tool actually wrote.
  HAS_OUR_OPTS=false
  if grep -qE "${PAM_FPRINTD_AUTH_RE}.*timeout=-1" "$f"; then HAS_OUR_OPTS=true; fi
  if [ "$HAS_ATTEMPTS" = false ] && [ "$HAS_OUR_OPTS" = false ]; then continue; fi

  if [ "$HAS_ATTEMPTS" = true ] && ! pam_fprintd_stack_is_generated "$f"; then
    echo "$f carries fingerprint attempt lines with this tool's marker" >&2
    echo "(authinfo_unavail=ignore), but the file is not what install.sh" >&2
    echo "would have written - either something edited it since, or it was" >&2
    echo "somebody's own retry stack all along. Left untouched rather than" >&2
    echo "guessed at." >&2
    if compgen -G "$f.bak-*" >/dev/null; then
      echo "There is a pre-install copy beside it, if it was ours:" >&2
      # shellcheck disable=SC2012
      ls -1 "$f".bak-* >&2
    fi
    echo >&2
    continue
  fi

  if [ "$HAS_ATTEMPTS" = true ]; then
    echo "Found install.sh's fingerprint attempt stack in $f"
  else
    echo "Found an older install.sh's timeout=-1 on the pam_fprintd.so line in $f"
    echo "(its attempt lines are already gone - only the options are left)"
  fi
  ORIGINAL="$(pam_fprintd_exact_original "$f" || true)"
  if [ -n "$ORIGINAL" ]; then
    PROMPT="Restore the original line exactly, from $(basename "$ORIGINAL")?"
  else
    PROMPT="Put it back to a single pam_fprintd.so line with module defaults?"
  fi
  if confirm "$PROMPT"; then
    if [ -n "$ORIGINAL" ]; then
      backup_pam_file "$f"
      # cp *onto* the existing file rather than replacing it, so its mode and
      # ownership stay exactly as the distro shipped them.
      sudo cp "$ORIGINAL" "$f"
      echo "Restored exactly, from $ORIGINAL"
      echo "(previous content backed up as $f.bak-$RUN_TS)."
      continue
    fi
    REWRITTEN="$(mktemp)"
    pam_fprintd_unharden <"$f" >"$REWRITTEN"
    # same invariant install.sh writes under: every non-fprintd line identical,
    # exactly one fprintd auth line left, no generated lines, no timeout=-1
    if diff -q <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$f") \
        <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$REWRITTEN") >/dev/null \
      && [ "$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$REWRITTEN")" = 1 ] \
      && ! grep -qE "$PAM_FPRINTD_RETRY_LINE_RE" "$REWRITTEN" \
      && ! grep -qE "${PAM_FPRINTD_AUTH_RE}.*timeout=-1" "$REWRITTEN"; then
      backup_pam_file "$f"
      sudo cp "$REWRITTEN" "$f"
      echo "Restored to the module's defaults (no pre-install copy of this file"
      echo "was found, so an explicit timeout= it may have had is not back)."
      echo "Previous content backed up as $f.bak-$RUN_TS."
    else
      echo "Unexpected result rewriting $f - left it untouched." >&2
    fi
    rm -f "$REWRITTEN"
  fi
done

# --- 1c. re-enable the fprintd pam-auth-update profile -------------------
# install.sh disables it so the fingerprint attempt stack can actually get the
# sensor (two PAM conversations, one reader - see bin/lib.sh and JOURNAL.md,
# 2026-09-15). Undo that here, but only on the strength of the marker file
# install.sh wrote: a machine where fingerprint was disabled by hand, or by
# something else, must not have it switched back on by this uninstaller. That
# is the same rule the attempt-stack restore above follows - only claim what
# this tool provably did.
if [ -f "$DATA_DIR/$PAM_FPRINTD_PROFILE_MARKER" ]; then
  if ! command -v pam-auth-update >/dev/null 2>&1; then
    echo "install.sh disabled the 'fprintd' pam-auth-update profile on this" >&2
    echo "machine, but pam-auth-update is gone - re-enable it yourself if you" >&2
    echo "want fingerprint back in $PAM_SHARED_AUTH_STACK." >&2
    echo >&2
  elif pam_fprintd_in_shared_stack; then
    # Already back (someone re-enabled it, or a package did). Nothing to do,
    # and the marker no longer describes reality, so drop it.
    rm -f "$DATA_DIR/$PAM_FPRINTD_PROFILE_MARKER"
  else
    echo "install.sh disabled the 'fprintd' pam-auth-update profile, which is"
    echo "what took pam_fprintd.so out of $PAM_SHARED_AUTH_STACK."
    echo "Re-enabling puts fingerprint back for every service that @include's"
    echo "it (polkit prompts, login, su), and puts back the race with the"
    echo "fingerprint attempt stack if any of that is still installed."
    if confirm "Re-enable the 'fprintd' pam-auth-update profile?"; then
      for f in "$(dirname "$PAM_SHARED_AUTH_STACK")"/common-*; do
        [ -f "$f" ] || continue
        if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi
        backup_pam_file "$f"
      done
      # Same noninteractive frontend install.sh uses, and for the same reason:
      # a refusal over local modifications should be a printed no-op, not a
      # debconf dialog in the middle of this script.
      RC=0
      sudo env DEBIAN_FRONTEND=noninteractive pam-auth-update --enable fprintd || RC=$?
      [ "$RC" = 0 ] || echo "pam-auth-update exited $RC." >&2
      if pam_fprintd_in_shared_stack; then
        rm -f "$DATA_DIR/$PAM_FPRINTD_PROFILE_MARKER"
        echo "Re-enabled (previous content backed up as <file>.bak-$RUN_TS)."
      else
        echo "pam-auth-update did not put the line back - it refuses to" >&2
        echo "rewrite common-* files carrying local modifications it can't" >&2
        echo "reconcile. Nothing was changed; run 'sudo pam-auth-update'" >&2
        echo "yourself and tick 'Fingerprint authentication'. Leaving the" >&2
        echo "marker in place so this is offered again." >&2
      fi
    fi
    echo
  fi
fi

# --- 2. remove installed module + helper --------------------------------
# Same candidate list install.sh picks the install directory from (shared
# via bin/lib.sh), just checking for our own module instead of pam_unix.so.
found_module=""
for candidate in "${PAM_MODULE_DIR_CANDIDATES[@]}"; do
  if [ -f "$candidate/pam_tpm_keyring_authtok.so" ]; then
    found_module="$candidate/pam_tpm_keyring_authtok.so"
    break
  fi
done
# The module and the helper are machine-wide, not this account's: every user
# who sealed here depends on them, and these were the only destructive steps
# in this script with no confirmation at all. Removing them takes keyring
# auto-unlock away from everyone on the box - a wider blast radius than the
# TPM handle eviction further down, which does ask. Same disclosure as there:
# name who else is relying on this before asking. See JOURNAL.md, 2026-09-15.
if [ -n "$found_module" ] || [ -f "$HELPER_DST" ]; then
  echo
  if [ -n "$OTHER_SEALED" ]; then
    echo "Reminder: these users still depend on the module and helper:"
    echo "$OTHER_SEALED" | sed 's/^/  /'
  else
    echo "The PAM module and helper are shared by every user of this tool on"
    echo "this machine. No other user's sealed secret was found, though a home"
    echo "that isn't mounted right now wouldn't show up."
  fi
  if confirm_default_no "Remove the machine-wide PAM module and helper?"; then
    if [ -n "$found_module" ]; then
      sudo rm -f "$found_module"
      echo "Removed $found_module"
    fi
    if [ -f "$HELPER_DST" ]; then
      sudo rm -f "$HELPER_DST"
      echo "Removed $HELPER_DST"
    fi
  else
    echo "Left the PAM module and helper in place."
  fi
fi

# --- 3. unmask the systemd units ----------------------------------------
if systemctl --user is-enabled gnome-keyring-daemon.service 2>/dev/null | grep -q masked; then
  if confirm "Unmask gnome-keyring-daemon systemd units (restores the original,\npre-tpm-keyring-unlock behavior on this machine)?"; then
    systemctl --user unmask gnome-keyring-daemon.socket gnome-keyring-daemon.service
    echo "Unmasked."
  fi
fi

# --- 4. sealed secret + persisted TPM primary ---------------------------
# The primary key may live persisted in the TPM's own NV storage (see
# JOURNAL.md, 2026-08-16) rather than only as ephemeral state - evict it
# before wiping $DATA_DIR (which is what records the handle), so a leftover
# object doesn't sit in the TPM's limited persistent-object slots forever.
# Only present on installs that have re-sealed since that change; older
# sealed data never persisted anything, so there's nothing to evict.
#
# That object is MACHINE-WIDE, though, not this account's: bin/seal.sh
# persists it at one fixed handle every user of this tool shares. The TPM
# itself cannot say who still depends on it - a persistent object has no
# owner and no refcount - so the only available answer is to look for other
# users' recorded handles on disk, which needs root because those data dirs
# are 0700. See bin/lib.sh's tpm_primary_handle_dependents, GitHub issue #7
# and JOURNAL.md, 2026-09-15.
if [ -f "$DATA_DIR/primary.handle" ] && command -v tpm2_evictcontrol >/dev/null 2>&1; then
  PRIMARY_HANDLE="$(tr -d '[:space:]' <"$DATA_DIR/primary.handle" 2>/dev/null || true)"
  if ! tpm_handle_is_wellformed "$PRIMARY_HANDLE"; then
    echo "$DATA_DIR/primary.handle doesn't contain a TPM persistent handle." >&2
    echo "Not evicting anything on the strength of that." >&2
  else
    echo
    echo "-- checking whether other users still depend on $PRIMARY_HANDLE --"
    echo "(needs root: other users' data directories are 0700)"
    # Fail closed. Anything that stops this from producing a trustworthy
    # answer - sudo declined, getent unavailable, an unreadable home - has
    # to count as "somebody might", because the failure mode on the other
    # side is silently breaking someone else's login.
    if DEPENDENTS="$(sudo bash -c '
           set -euo pipefail
           source "$1"
           tpm_primary_handle_dependents "$2" "$3"
         ' _ "$REPO_DIR/bin/lib.sh" "$PRIMARY_HANDLE" "$USER")"; then
      SCAN_OK=1
    else
      SCAN_OK=0
      DEPENDENTS=""
    fi

    if [ "$SCAN_OK" -eq 0 ]; then
      echo "Couldn't check (sudo declined, or the user list is unavailable)." >&2
      echo "Not evicting $PRIMARY_HANDLE - it's shared machine-wide, and an" >&2
      echo "unchecked eviction can break other users' keyring unlock. If you're" >&2
      echo "sure nobody else uses this tool here:" >&2
      echo "  tpm2_evictcontrol -C o -c $PRIMARY_HANDLE" >&2
    elif [ -n "$DEPENDENTS" ]; then
      # Refuse outright rather than prompt. bin/seal.sh sets the precedent
      # for this exact shape: when it finds the handle occupied by an object
      # it didn't create, it refuses and prints the command for someone who
      # knows better, instead of asking a question whose consequences the
      # person answering can't see.
      echo "These users have sealed secrets under $PRIMARY_HANDLE too:" >&2
      echo "$DEPENDENTS" | sed 's/^/  /' >&2
      echo "Not evicting it. It's one shared object - taking it away would make" >&2
      echo "their next login fall back to recreating the primary (several seconds" >&2
      echo "slower) until each of them re-runs bin/seal.sh." >&2
      echo "If you really mean to, after they've re-sealed or moved on:" >&2
      echo "  tpm2_evictcontrol -C o -c $PRIMARY_HANDLE" >&2
    else
      echo "No other user's sealed secret names this handle."
      if confirm_default_no "Evict the TPM primary key at $PRIMARY_HANDLE? It is shared by every
user of this tool on this machine. Nobody else was found using it - though a
home that isn't mounted right now wouldn't show up. Anyone still holding one
keeps logging in, just several seconds slower, until they re-run bin/seal.sh."; then
        if tpm2_evictcontrol -C o -c "$PRIMARY_HANDLE" >/dev/null 2>&1; then
          echo "Evicted."
        else
          echo "Couldn't evict $PRIMARY_HANDLE (already gone, or TPM not reachable" >&2
          echo "right now) - continuing anyway." >&2
        fi
      else
        echo "Left $PRIMARY_HANDLE in place."
      fi
    fi
  fi
fi

if [ -d "$DATA_DIR" ]; then
  if confirm "Delete the TPM-sealed secret at $DATA_DIR?"; then
    rm -rf "$DATA_DIR"
    echo "Deleted."
  fi
fi

# --- 5. tss group membership ----------------------------------------------
# install.sh adds you to 'tss' for passwordless TPM access; mirror that here
# rather than leaving it permanently applied with no way back through this
# tool. Harmless to keep, but shouldn't require finding install.sh's source
# to know how to undo.
if getent group tss >/dev/null && groups "$USER" | grep -qw tss; then
  if confirm "Remove $USER from the 'tss' group (added by install.sh)?"; then
    sudo gpasswd -d "$USER" tss
    echo "Removed. Takes effect on your next login."
  fi
fi

echo
echo "Done. Note: your GNOME keyring password itself was never changed by"
echo "this tool, so nothing needs to be restored there."

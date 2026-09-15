#!/usr/bin/env bash
# Reverses install.sh. Safe to run even if only some steps were applied.
set -euo pipefail

DATA_DIR="$HOME/.local/share/tpm-keyring-unlock"
HELPER_DST="/usr/local/sbin/tpm-keyring-unseal"

# shellcheck source=bin/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/lib.sh"

confirm() {
  local prompt="$1"
  local ans
  # Defaults to yes: an empty answer accepts. A failed read (EOF, i.e. no
  # terminal) is a "no", so nothing here can be auto-approved by a pipe.
  read -rp "$prompt [Y/n] " ans || return 1
  [[ ! "$ans" =~ ^[Nn][Oo]?$ ]]
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
  # timeout=-1 is this tool's signature on its own: no distro ships it, and
  # unlike max-tries=1 (which Debian's own pam-auth-update writes into
  # common-auth) it cannot be confused with somebody else's config. Checked
  # separately so a file whose attempt lines are gone but whose options are
  # still ours - a partial hand edit - is still offered, instead of being
  # skipped in silence with this tool's settings left on a login path.
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
    echo "Found install.sh's timeout=-1 on the pam_fprintd.so line in $f"
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
if [ -n "$found_module" ]; then
  sudo rm -f "$found_module"
  echo "Removed $found_module"
fi
if [ -f "$HELPER_DST" ]; then
  sudo rm -f "$HELPER_DST"
  echo "Removed $HELPER_DST"
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
if [ -f "$DATA_DIR/primary.handle" ] && command -v tpm2_evictcontrol >/dev/null 2>&1; then
  PRIMARY_HANDLE="$(cat "$DATA_DIR/primary.handle")"
  if confirm "Evict the persisted TPM primary key at $PRIMARY_HANDLE?"; then
    if tpm2_evictcontrol -C o -c "$PRIMARY_HANDLE" >/dev/null 2>&1; then
      echo "Evicted."
    else
      echo "Couldn't evict $PRIMARY_HANDLE (already gone, or TPM not reachable" >&2
      echo "right now) - continuing anyway." >&2
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

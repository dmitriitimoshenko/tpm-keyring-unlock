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
  if [[ "$f" =~ $PAM_BACKUP_RE ]]; then continue; fi
  if grep -q pam_tpm_keyring_authtok.so "$f"; then
    echo "Found the injected line in $f"
    if confirm "Remove it?"; then
      sudo sed -i '/pam_tpm_keyring_authtok\.so/d' "$f"
      echo "Removed."
    fi
  fi
done

# --- 1b. undo the fingerprint attempt-stack edit -------------------------
# Drops the attempt lines install.sh generated and the timeout=-1 it set,
# putting the service back on a single pam_fprintd.so line with the module's
# own defaults (30s idle, and one bad scan ends fingerprint for that prompt -
# see JOURNAL.md, 2026-09-14). If the line carried some other explicit timeout
# before install.sh replaced it, the exact original is in the .bak-<timestamp>
# copy install.sh left beside the file.
for f in /etc/pam.d/*; do
  [ -f "$f" ] || continue
  if [[ "$f" =~ $PAM_BACKUP_RE ]]; then continue; fi
  if pam_fprintd_unharden <"$f" | cmp -s - "$f"; then continue; fi
  echo "Found install.sh's fingerprint attempt stack in $f"
  if confirm "Put it back to a single pam_fprintd.so line with module defaults?"; then
    REWRITTEN="$(mktemp)"
    pam_fprintd_unharden <"$f" >"$REWRITTEN"
    # same invariant install.sh writes under: every non-fprintd line identical,
    # exactly one fprintd auth line left, no generated lines, no timeout=-1
    if diff -q <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$f") \
        <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$REWRITTEN") >/dev/null \
      && [ "$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$REWRITTEN")" = 1 ] \
      && ! grep -qE "$PAM_FPRINTD_RETRY_LINE_RE" "$REWRITTEN" \
      && ! grep -qE "${PAM_FPRINTD_AUTH_RE}.*timeout=-1" "$REWRITTEN"; then
      sudo cp "$REWRITTEN" "$f"
      echo "Restored."
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

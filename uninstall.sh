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
  read -rp "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

echo "== tpm-keyring-unlock uninstaller =="
echo

# --- 1. remove the PAM stack line ---------------------------------------
# Scans every /etc/pam.d/ service, not just ones named after fingerprints:
# install.sh patches any service with an auth-phase pam_gnome_keyring.so
# line (gdm-password included, once system-wide fingerprint auth is on).
for f in /etc/pam.d/*; do
  [ -f "$f" ] || continue
  if grep -q pam_tpm_keyring_authtok.so "$f"; then
    echo "Found the injected line in $f"
    if confirm "Remove it?"; then
      sudo sed -i '/pam_tpm_keyring_authtok\.so/d' "$f"
      echo "Removed."
    fi
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

# --- 4. sealed secret -----------------------------------------------------
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

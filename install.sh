#!/usr/bin/env bash
# Installs tpm-keyring-unlock: TPM-backed auto-unlock of the GNOME login
# keyring, working for both password and fingerprint logins, without
# blanking the keyring password. See README.md for how/why this works.
#
# Safe by design at every step except one: the single line added to the
# fingerprint PAM stack is "optional" and cannot itself grant or block
# login - see README.md "How it works" before running this if you want to
# understand exactly what it touches.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/.local/share/tpm-keyring-unlock"
HELPER_DST="/usr/local/sbin/tpm-keyring-unseal"
PCR_BANK="sha256:7"

confirm() {
  local prompt="$1"
  local ans
  read -rp "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

echo "== tpm-keyring-unlock installer =="
echo

# --- 1. dependencies ---------------------------------------------------
missing=()
command -v tpm2_createprimary >/dev/null || missing+=(tpm2-tools)
command -v gcc >/dev/null || missing+=(gcc)
[ -f /usr/include/security/pam_modules.h ] || missing+=(pam-dev)

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing: ${missing[*]}"

  # Package names differ across distros; pam-dev is a placeholder above,
  # translated per package manager below. gcc's placeholder stays literal
  # everywhere except Arch, where it comes from the base-devel group.
  if command -v apt >/dev/null; then
    pkgs=(); for m in "${missing[@]}"; do [ "$m" = pam-dev ] && pkgs+=(libpam0g-dev) || pkgs+=("$m"); done
    if confirm "Install via apt now? (${pkgs[*]})"; then
      sudo apt update && sudo apt install -y "${pkgs[@]}"
    else
      echo "Install them manually and re-run this script." >&2; exit 1
    fi
  elif command -v dnf >/dev/null; then
    pkgs=(); for m in "${missing[@]}"; do [ "$m" = pam-dev ] && pkgs+=(pam-devel) || pkgs+=("$m"); done
    if confirm "Install via dnf now? (${pkgs[*]})"; then
      sudo dnf install -y "${pkgs[@]}"
    else
      echo "Install them manually and re-run this script." >&2; exit 1
    fi
  elif command -v pacman >/dev/null; then
    pkgs=(); for m in "${missing[@]}"; do case "$m" in gcc) pkgs+=(base-devel);; pam-dev) pkgs+=(pam);; *) pkgs+=("$m");; esac; done
    if confirm "Install via pacman now? (${pkgs[*]})"; then
      sudo pacman -Sy --needed "${pkgs[@]}"
    else
      echo "Install them manually and re-run this script." >&2; exit 1
    fi
  elif command -v zypper >/dev/null; then
    pkgs=(); for m in "${missing[@]}"; do [ "$m" = pam-dev ] && pkgs+=(pam-devel) || pkgs+=("$m"); done
    if confirm "Install via zypper now? (${pkgs[*]})"; then
      sudo zypper install -y "${pkgs[@]}"
    else
      echo "Install them manually and re-run this script." >&2; exit 1
    fi
  else
    echo "No supported package manager found (looked for apt/dnf/pacman/zypper)." >&2
    echo "Install these yourself, then re-run: tpm2-tools, a C compiler (gcc)," >&2
    echo "and PAM development headers (the package providing security/pam_modules.h)." >&2
    exit 1
  fi
fi

[ -e /dev/tpmrm0 ] || {
  echo "No /dev/tpmrm0 found. This machine doesn't expose a TPM 2.0 resource" >&2
  echo "manager device - is TPM 2.0 enabled in BIOS/UEFI?" >&2
  exit 1
}

# --- 2. tss group (passwordless TPM access) -----------------------------
if getent group tss >/dev/null && ! groups "$USER" | grep -qw tss; then
  echo "You're not in the 'tss' group (needed for passwordless TPM access)."
  if confirm "Add $USER to the tss group now?"; then
    sudo usermod -aG tss "$USER"
    echo "Added. You must log out and back in before continuing (group"
    echo "membership only applies to new sessions). Re-run this script after."
    exit 0
  fi
fi

if ! tpm2_pcrread "$PCR_BANK" >/dev/null 2>&1; then
  echo "Can't read TPM PCRs even though the tss group looks right." >&2
  echo "Try logging out and back in, then re-run this script." >&2
  exit 1
fi

# --- 3. compile + install the PAM module and its helper ----------------
echo
echo "-- Building PAM module --"
gcc -Wall -Wextra -fPIC -shared \
  -o "$REPO_DIR/pam/pam_tpm_keyring_authtok.so" \
  "$REPO_DIR/pam/pam_tpm_keyring_authtok.c" -lpam

PAM_MODULE_DIR=""
for candidate in /lib/x86_64-linux-gnu/security /usr/lib/x86_64-linux-gnu/security \
                 /lib/aarch64-linux-gnu/security /usr/lib/aarch64-linux-gnu/security \
                 /lib/security /usr/lib64/security /usr/lib/security; do
  if [ -d "$candidate" ] && [ -f "$candidate/pam_unix.so" ]; then
    PAM_MODULE_DIR="$candidate"
    break
  fi
done
if [ -z "$PAM_MODULE_DIR" ]; then
  echo "Couldn't auto-detect the PAM modules directory (looked for pam_unix.so" >&2
  echo "next to it). Find it yourself (dpkg -L libpam-modules | grep pam_unix.so)" >&2
  echo "and install pam/pam_tpm_keyring_authtok.so there manually." >&2
  exit 1
fi

echo "-- Installing helper + module (needs sudo) --"
sudo install -o root -g root -m 0700 \
  "$REPO_DIR/pam/tpm-keyring-unseal.sh" "$HELPER_DST"
sudo install -o root -g root -m 0644 \
  "$REPO_DIR/pam/pam_tpm_keyring_authtok.so" \
  "$PAM_MODULE_DIR/pam_tpm_keyring_authtok.so"

# --- 4. stop systemd from racing PAM to create the keyring daemon ------
echo
echo "-- Masking systemd's eager keyring daemon startup --"
if systemctl --user list-unit-files 'gnome-keyring-daemon.*' 2>/dev/null | grep -q gnome-keyring-daemon; then
  systemctl --user mask gnome-keyring-daemon.socket gnome-keyring-daemon.service
  echo "Masked. (undo any time: systemctl --user unmask gnome-keyring-daemon.socket gnome-keyring-daemon.service)"
else
  echo "No systemd user units named gnome-keyring-daemon.* found - skipping."
  echo "(This step only matters on systems where systemd pre-starts the keyring"
  echo "daemon before login; if yours doesn't, you may not need it at all.)"
fi

# --- 5. seal the real keyring password ----------------------------------
echo
if [ -f "$DATA_DIR/seal.priv" ]; then
  echo "A sealed secret already exists at $DATA_DIR."
  confirm "Re-seal (overwrite)?" && "$REPO_DIR/bin/seal.sh"
else
  echo "-- Sealing your keyring password into the TPM --"
  "$REPO_DIR/bin/seal.sh"
fi

# --- 6. wire the PAM module into every login stack that feeds the keyring -
echo
echo "-- Login PAM stacks that feed the keyring --"
echo "Looking for /etc/pam.d/ services with an auth-phase pam_gnome_keyring.so"
echo "line. Every one of them needs this module, not just a service literally"
echo "named '*fingerprint*': if you ever enable fingerprint auth system-wide"
echo "(e.g. 'sudo pam-auth-update --enable fprintd'), services like"
echo "gdm-password gain the ability to succeed via fingerprint too, which"
echo "reopens the exact same PAM_AUTHTOK gap on a service that has nothing"
echo "to do with fingerprints in its name."
echo

mapfile -t candidates < <(grep -lE '^\s*auth\s+\S+\s+pam_gnome_keyring\.so' /etc/pam.d/* 2>/dev/null)

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "No /etc/pam.d/ service has an auth-phase pam_gnome_keyring.so line."
  echo "Password logins are already fixed by the systemd mask above; skipping"
  echo "this step. Wire it in manually if you find the right file - see"
  echo "README.md 'How it works'."
  exit 0
fi

for TARGET in "${candidates[@]}"; do
  if grep -q pam_tpm_keyring_authtok.so "$TARGET"; then
    echo "$TARGET already has the module wired in - skipping."
    continue
  fi

  echo
  echo "About to make this change to $TARGET:"
  echo
  echo "+ auth optional   pam_tpm_keyring_authtok.so   <-- new line"
  echo "  auth optional   pam_gnome_keyring.so         <-- existing line, unchanged"
  echo
  echo "This line is 'optional': it can never grant or deny login by itself."
  echo "It only makes the TPM-unsealed password available to the"
  echo "pam_gnome_keyring.so line right after it, for whenever this service"
  echo "authenticates you via something other than a typed password (e.g."
  echo "fingerprint). A backup of the original file is kept alongside it."
  echo
  if confirm "Apply this change to $TARGET?"; then
    sudo cp "$TARGET" "$TARGET.bak-$(date +%Y%m%d%H%M%S)"
    sudo sed -i '/^\s*auth\s\+\S\+\s\+pam_gnome_keyring\.so/i auth    optional        pam_tpm_keyring_authtok.so' "$TARGET"
    echo "Done."
  else
    echo "Skipped $TARGET. It will keep showing the manual unlock prompt"
    echo "whenever it authenticates you via something other than a typed"
    echo "password, until you add that line yourself."
  fi
done

echo
echo "Log out and back in (however you normally authenticate) to test."

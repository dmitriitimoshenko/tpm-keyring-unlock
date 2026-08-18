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

# shellcheck source=bin/lib.sh
source "$REPO_DIR/bin/lib.sh"

confirm() {
  local prompt="$1"
  local ans
  read -rp "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

echo "== tpm-keyring-unlock installer =="
echo

# --- 0. hard requirements - checked before touching anything, including
# before installing dependencies, so a machine that can't use this tool
# finds out immediately instead of after a sudo package install -----------
[ -e /dev/tpmrm0 ] || {
  echo "No /dev/tpmrm0 found. This machine doesn't expose a TPM 2.0 resource" >&2
  echo "manager device - is TPM 2.0 enabled in BIOS/UEFI?" >&2
  exit 1
}
require_secure_boot

# --- 1. plan - figure out everything this run would need to do, without
# changing anything yet, so we can ask for approval exactly once instead of
# interrupting partway through with one y/N per step. ---------------------

# 1a. missing packages
missing=()
command -v tpm2_createprimary >/dev/null || missing+=(tpm2-tools)
command -v gcc >/dev/null || missing+=(gcc)
[ -f /usr/include/security/pam_modules.h ] || missing+=(pam-dev)

PKG_MGR=""
PKGS=()
if [ "${#missing[@]}" -gt 0 ]; then
  # Package names differ across distros; pam-dev is a placeholder above,
  # translated per package manager below. gcc's placeholder stays literal
  # everywhere except Arch, where it comes from the base-devel group.
  if command -v apt >/dev/null; then
    PKG_MGR=apt
    for m in "${missing[@]}"; do [ "$m" = pam-dev ] && PKGS+=(libpam0g-dev) || PKGS+=("$m"); done
  elif command -v dnf >/dev/null; then
    PKG_MGR=dnf
    for m in "${missing[@]}"; do [ "$m" = pam-dev ] && PKGS+=(pam-devel) || PKGS+=("$m"); done
  elif command -v pacman >/dev/null; then
    PKG_MGR=pacman
    for m in "${missing[@]}"; do case "$m" in gcc) PKGS+=(base-devel);; pam-dev) PKGS+=(pam);; *) PKGS+=("$m");; esac; done
  elif command -v zypper >/dev/null; then
    PKG_MGR=zypper
    for m in "${missing[@]}"; do case "$m" in pam-dev) PKGS+=(pam-devel);; tpm2-tools) PKGS+=(tpm2.0-tools);; *) PKGS+=("$m");; esac; done
  else
    echo "Missing: ${missing[*]}"
    echo "No supported package manager found (looked for apt/dnf/pacman/zypper)." >&2
    echo "Install these yourself, then re-run: tpm2-tools, a C compiler (gcc)," >&2
    echo "and PAM development headers (the package providing security/pam_modules.h)." >&2
    exit 1
  fi
fi

# 1b. tss group (passwordless TPM access)
TSS_GROUP_PRESENT=false
NEED_TSS_ADD=false
if getent group tss >/dev/null; then
  TSS_GROUP_PRESENT=true
  groups "$USER" | grep -qw tss || NEED_TSS_ADD=true
else
  echo "No 'tss' group on this system - skipping the group-membership check."
  echo "TPM access must be granted some other way here; if the PCR-read check"
  echo "below fails, that's where to look (your distro's tpm2-tools/tpm2-abrmd"
  echo "packaging docs should say how)."
  echo
fi

# 1c. seal vs. re-seal
RESEAL=false
[ -f "$DATA_DIR/seal.priv" ] && RESEAL=true

# 1d. login PAM stacks that need the helper wired in
mapfile -t candidates < <(grep -lE "$PAM_GNOME_KEYRING_AUTH_RE" /etc/pam.d/* 2>/dev/null)
targets=()
for c in "${candidates[@]}"; do
  grep -q pam_tpm_keyring_authtok.so "$c" || targets+=("$c")
done

# --- 2. print the full plan and ask for approval exactly once ------------
echo "This installer will make the following changes:"
echo
n=1
if [ "${#PKGS[@]}" -gt 0 ]; then
  echo "  $n. Install via $PKG_MGR (needs sudo): ${PKGS[*]}"
  n=$((n + 1))
fi
if [ "$NEED_TSS_ADD" = true ]; then
  echo "  $n. Add $USER to the 'tss' group (needs sudo), for passwordless TPM"
  echo "     access. This requires logging out and back in before the install"
  echo "     can continue - you'll need to re-run this script afterward."
  n=$((n + 1))
fi
if [ "$RESEAL" = true ]; then
  echo "  $n. Re-seal (overwrite) the existing sealed secret at $DATA_DIR."
else
  echo "  $n. Seal your keyring password into the TPM."
fi
n=$((n + 1))
echo "  $n. Compile the PAM helper module and install it + its helper script"
echo "     (needs sudo)."
n=$((n + 1))
echo "  $n. Mask systemd's eager gnome-keyring-daemon startup, if present."
n=$((n + 1))
if [ "${#targets[@]}" -gt 0 ]; then
  echo "  $n. Wire the TPM helper into these login PAM stacks (each backed up"
  echo "     first, as <file>.bak-<timestamp>):"
  for t in "${targets[@]}"; do
    echo
    echo "       $t"
    echo "         + auth    optional        pam_tpm_keyring_authtok.so   <-- new line"
    echo "           auth    optional        pam_gnome_keyring.so         <-- existing, unchanged"
  done
  echo
  echo "     This line is 'optional': it can never grant or deny login by"
  echo "     itself. It only makes the TPM-unsealed password available to the"
  echo "     pam_gnome_keyring.so line right after it, for whenever that"
  echo "     service authenticates you via something other than a typed"
  echo "     password (e.g. fingerprint)."
fi
echo

if ! confirm "Proceed with all of the above?"; then
  echo "Nothing was changed. Re-run when ready."
  exit 0
fi
echo

# --- 3. execute, in order, with no further prompts ------------------------

if [ "${#PKGS[@]}" -gt 0 ]; then
  echo "-- Installing packages --"
  case "$PKG_MGR" in
    apt) sudo apt update && sudo apt install -y "${PKGS[@]}" ;;
    dnf) sudo dnf install -y "${PKGS[@]}" ;;
    pacman) sudo pacman -Sy --needed "${PKGS[@]}" ;;
    zypper) sudo zypper install -y "${PKGS[@]}" ;;
  esac
  echo
fi

if [ "$NEED_TSS_ADD" = true ]; then
  sudo usermod -aG tss "$USER"
  echo "Added $USER to the 'tss' group. Log out and back in (group membership"
  echo "only applies to new sessions), then re-run this script to continue."
  exit 0
fi

if ! tpm2_pcrread "$PCR_BANK" >/dev/null 2>&1; then
  if [ "$TSS_GROUP_PRESENT" = true ]; then
    echo "Can't read TPM PCRs even though you're in the 'tss' group." >&2
    echo "Try logging out and back in (group membership needs a fresh" >&2
    echo "session), then re-run this script." >&2
  else
    echo "Can't read TPM PCRs, and there's no 'tss' group on this system to" >&2
    echo "add you to. Check how your distro grants /dev/tpmrm0 access." >&2
  fi
  exit 1
fi

echo "-- Building PAM module --"
gcc -Wall -Wextra -fPIC -shared \
  -o "$REPO_DIR/pam/pam_tpm_keyring_authtok.so" \
  "$REPO_DIR/pam/pam_tpm_keyring_authtok.c" -lpam

PAM_MODULE_DIR="$(find_pam_module_dir || true)"
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

echo
if [ "$RESEAL" = true ]; then
  echo "-- Re-sealing your keyring password into the TPM --"
else
  echo "-- Sealing your keyring password into the TPM --"
fi
"$REPO_DIR/bin/seal.sh"

echo
echo "-- Login PAM stacks that feed the keyring --"
if [ "${#candidates[@]}" -eq 0 ]; then
  echo "No /etc/pam.d/ service has an auth-phase pam_gnome_keyring.so line."
  echo "Password logins are already fixed by the systemd mask above. Wire it"
  echo "in manually if you find the right file - see README.md 'How it works'."
else
  for TARGET in "${candidates[@]}"; do
    if grep -q pam_tpm_keyring_authtok.so "$TARGET"; then
      echo "$TARGET already had the module wired in - left unchanged."
      continue
    fi
    sudo cp "$TARGET" "$TARGET.bak-$(date +%Y%m%d%H%M%S)"
    sudo sed -E -i "/${PAM_GNOME_KEYRING_AUTH_RE}/i auth    optional        pam_tpm_keyring_authtok.so" "$TARGET"
    echo "Wired: $TARGET"
  done
fi

echo
echo "Log out and back in (however you normally authenticate) to test."

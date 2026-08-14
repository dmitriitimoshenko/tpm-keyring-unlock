#!/usr/bin/env bash
# Seals your GNOME keyring password into the TPM, bound to a PCR7 (Secure Boot
# state) policy. Run this yourself, interactively, in your own terminal - it
# reads the password with 'read -s' so it never appears on screen, in shell
# history, or anywhere outside this process.
set -euo pipefail

DATA_DIR="$HOME/.local/share/tpm-keyring-unlock"
PCR_BANK="sha256:7"

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v tpm2_createprimary >/dev/null || {
  echo "tpm2-tools not found. Install it: sudo apt install tpm2-tools" >&2
  exit 1
}
[ -e /dev/tpmrm0 ] || {
  echo "No /dev/tpmrm0 found. Is TPM 2.0 enabled in BIOS?" >&2
  exit 1
}
tpm2_pcrread "$PCR_BANK" >/dev/null 2>&1 || {
  echo "Can't read TPM PCRs. Are you in the 'tss' group? (log out/in after usermod -aG tss \$USER)" >&2
  exit 1
}
require_secure_boot

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [ -f "$DATA_DIR/seal.priv" ]; then
  read -rp "A sealed secret already exists at $DATA_DIR. Overwrite? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0
  rm -f "$DATA_DIR/pcr.policy" "$DATA_DIR/seal.pub" "$DATA_DIR/seal.priv"
fi

read -rsp "Password to seal (should match your GNOME login keyring password): " PASSWORD
echo
read -rsp "Confirm: " PASSWORD2
echo

if [ "$PASSWORD" != "$PASSWORD2" ]; then
  echo "Passwords did not match." >&2
  unset PASSWORD PASSWORD2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Primary key context is not persisted to $DATA_DIR: a saved context for a
# transient object dies on every TPM reset (reboot). tpm2-keyring-unseal.sh
# recreates the same deterministic primary fresh on every call instead of
# relying on a saved context file - see JOURNAL.md.
tpm2_createprimary -C o -c "$WORKDIR/primary.ctx" >/dev/null

SESSION="$WORKDIR/session"
tpm2_startauthsession -S "$SESSION" --policy-session >/dev/null
tpm2_policypcr -S "$SESSION" -l "$PCR_BANK" -L "$DATA_DIR/pcr.policy" >/dev/null
tpm2_flushcontext "$SESSION" >/dev/null

printf '%s' "$PASSWORD" | tpm2_create -C "$WORKDIR/primary.ctx" \
  -u "$DATA_DIR/seal.pub" -r "$DATA_DIR/seal.priv" \
  -L "$DATA_DIR/pcr.policy" -i- >/dev/null

unset PASSWORD PASSWORD2

echo "Sealed. Bound to this TPM and the current PCR7 (Secure Boot) state."
echo "Log out and back in to test the actual auto-unlock (via install.sh's"
echo "PAM wiring), or check it directly with:"
echo "  sudo /usr/local/sbin/tpm-keyring-unseal \$USER >/dev/null; echo \$?"

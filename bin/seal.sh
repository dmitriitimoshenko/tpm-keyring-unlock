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

# The primary is persisted into the TPM's own NV storage at a fixed handle
# instead of being recreated on every login. NOT the same thing as the
# saved-context-file approach that broke across reboots (see JOURNAL.md,
# "Bug found on full reboot") - that bug was about a *transient* object's
# serialized context blob, which is tied to the TPM's reset counter and
# becomes unloadable after every reset. A persistent object lives inside the
# TPM's own NVRAM (the same mechanism systemd-cryptenroll uses for its
# TPM-bound LUKS SRK) and survives resets by design - only the
# *recomputation* of a fresh transient primary on every single login was
# ever the actual cost (~7s on this machine's fTPM, profiled in
# JOURNAL.md), never a correctness requirement. See JOURNAL.md, 2026-08-16.
tpm2_createprimary -C o -c "$WORKDIR/primary.ctx" >/dev/null
tpm2_readpublic -c "$WORKDIR/primary.ctx" -n "$WORKDIR/fresh.name" >/dev/null

PRIMARY_HANDLE_DEFAULT="0x81018000"
if [ -f "$DATA_DIR/primary.handle" ]; then
  PRIMARY_HANDLE="$(cat "$DATA_DIR/primary.handle")"
else
  PRIMARY_HANDLE="$PRIMARY_HANDLE_DEFAULT"
fi

if tpm2_readpublic -c "$PRIMARY_HANDLE" -n "$WORKDIR/existing.name" >/dev/null 2>&1; then
  if cmp -s "$WORKDIR/fresh.name" "$WORKDIR/existing.name"; then
    echo "Reusing already-persisted primary key at $PRIMARY_HANDLE."
  else
    # Deterministic primary (same hierarchy + template = same key, always) -
    # a name mismatch means something else persisted an unrelated object at
    # this exact handle. Refuse rather than silently reusing or clobbering
    # an object this tool doesn't own.
    echo "TPM persistent handle $PRIMARY_HANDLE is occupied by an object this" >&2
    echo "tool didn't create (its name doesn't match our deterministic" >&2
    echo "primary). Not touching it. Either free it yourself if you know" >&2
    echo "it's safe (tpm2_evictcontrol -C o -c $PRIMARY_HANDLE), or put a" >&2
    echo "different free handle in $DATA_DIR/primary.handle first." >&2
    exit 1
  fi
else
  echo "Persisting primary key into the TPM at $PRIMARY_HANDLE (one-time cost;"
  echo "avoids recomputing it on every future login - see JOURNAL.md)."
  tpm2_evictcontrol -C o -c "$WORKDIR/primary.ctx" "$PRIMARY_HANDLE" >/dev/null
fi
echo "$PRIMARY_HANDLE" >"$DATA_DIR/primary.handle"

SESSION="$WORKDIR/session"
tpm2_startauthsession -S "$SESSION" --policy-session >/dev/null
tpm2_policypcr -S "$SESSION" -l "$PCR_BANK" -L "$DATA_DIR/pcr.policy" >/dev/null
tpm2_flushcontext "$SESSION" >/dev/null

printf '%s' "$PASSWORD" | tpm2_create -C "$PRIMARY_HANDLE" \
  -u "$DATA_DIR/seal.pub" -r "$DATA_DIR/seal.priv" \
  -L "$DATA_DIR/pcr.policy" -i- >/dev/null

unset PASSWORD PASSWORD2

echo "Sealed. Bound to this TPM and the current PCR7 (Secure Boot) state."
echo "Log out and back in to test the actual auto-unlock (via install.sh's"
echo "PAM wiring), or check it directly with:"
echo "  sudo /usr/local/sbin/tpm-keyring-unseal \$USER >/dev/null; echo \$?"

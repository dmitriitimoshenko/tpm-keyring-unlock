#!/usr/bin/env bash
# Installed at /usr/local/sbin/tpm-keyring-unseal, root:root mode 0700.
# Invoked only by the pam_tpm_keyring_authtok PAM module (running as root
# during authentication) with the target username as $1. Prints the sealed
# password to stdout on success, nothing on failure. Never invoked directly
# by a user - the PAM module is the only intended caller.
set -euo pipefail

USERNAME="${1:?username required}"
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || exit 1

DATA_DIR="$HOME_DIR/.local/share/tpm-keyring-unlock"
PCR_BANK="sha256:7"

[ -f "$DATA_DIR/seal.priv" ] || exit 1

# GDM spawns parallel PAM conversations on one login screen (e.g.
# gdm-fingerprint and gdm-password at once), and this helper is wired into
# both. Two concurrent tpm2_* sequences against the same TPM have been
# observed to fail with "Esys_Unseal ... PCR have changed since checked" -
# one session's PCR-policy check gets invalidated by the other session's
# concurrent activity on the same device. See JOURNAL.md, 2026-08-14. Serialize
# so only one unseal talks to the TPM at a time; the loser just waits its turn
# instead of racing and failing.
exec 9>/run/lock/tpm-keyring-unseal.lock
flock -w 10 9 || exit 1

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# The primary key is recreated fresh every call instead of loaded from a
# saved context file. tpm2 primary keys are deterministic (same hierarchy +
# same template = same key every time), but a *saved context* for a
# transient object is tied to the TPM's reset count and becomes unloadable
# ("integrity check failed") after every reboot. Recreating sidesteps that
# entirely - see JOURNAL.md.
tpm2_createprimary -C o -c "$WORKDIR/primary.ctx" >/dev/null

tpm2_load -C "$WORKDIR/primary.ctx" \
  -u "$DATA_DIR/seal.pub" -r "$DATA_DIR/seal.priv" \
  -c "$WORKDIR/seal.ctx" >/dev/null

tpm2_startauthsession -S "$WORKDIR/session" --policy-session >/dev/null
tpm2_policypcr -S "$WORKDIR/session" -l "$PCR_BANK" >/dev/null

tpm2_unseal -c "$WORKDIR/seal.ctx" -p "session:$WORKDIR/session"

tpm2_flushcontext "$WORKDIR/session" >/dev/null

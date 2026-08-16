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

# Fast path: if bin/seal.sh has persisted the primary into the TPM's own NV
# storage (see JOURNAL.md, 2026-08-16), reference that handle directly - no
# recomputation needed. Cuts per-login cost from ~7.4s to well under 1s
# (createprimary alone profiled at ~6.9s on this machine's fTPM, 2026-08-14
# entry). Falls back to recreating the primary fresh, exactly as before,
# for sealed data from before this existed (an install that hasn't re-run
# bin/seal.sh since upgrading) - nothing breaks mid-migration, it's just
# slower until re-sealed. tpm2 primary keys are deterministic (same
# hierarchy + same template = same key every time); a *saved context file*
# for a transient object is tied to the TPM's reset count and becomes
# unloadable after every reboot, which is why this fallback recreates
# rather than loading a saved primary.ctx - see JOURNAL.md.
if [ -f "$DATA_DIR/primary.handle" ]; then
  PRIMARY_HANDLE="$(cat "$DATA_DIR/primary.handle")"
else
  tpm2_createprimary -C o -c "$WORKDIR/primary.ctx" >/dev/null
  PRIMARY_HANDLE="$WORKDIR/primary.ctx"
fi

tpm2_load -C "$PRIMARY_HANDLE" \
  -u "$DATA_DIR/seal.pub" -r "$DATA_DIR/seal.priv" \
  -c "$WORKDIR/seal.ctx" >/dev/null

# The policy-session-check-then-use step (startauthsession -> policypcr ->
# unseal) has been observed to fail with "Esys_Unseal ... PCR have changed
# since checked" even with the flock above held and no other concurrent
# caller of this script - the flock only rules out racing against a *second
# copy of this same script*, not whatever else on this machine's fTPM
# (AMD PSP firmware TPM, session-slot-constrained) can perturb a policy
# session in that window. createprimary/load above (on the pre-persisted-
# primary fallback path; a no-op load off the handle otherwise) are
# deterministic given the same sealed blob, so only the fast, cheap final
# step is retried here - not the whole sequence. See JOURNAL.md, 2026-08-14.
UNSEAL_MAX_ATTEMPTS=5
attempt=1
while :; do
  SESSION_CTX="$WORKDIR/session.$attempt"
  if tpm2_startauthsession -S "$SESSION_CTX" --policy-session >/dev/null \
     && tpm2_policypcr -S "$SESSION_CTX" -l "$PCR_BANK" >/dev/null \
     && tpm2_unseal -c "$WORKDIR/seal.ctx" -p "session:$SESSION_CTX"; then
    tpm2_flushcontext "$SESSION_CTX" >/dev/null 2>&1 || true
    break
  fi
  tpm2_flushcontext "$SESSION_CTX" >/dev/null 2>&1 || true
  if [ "$attempt" -ge "$UNSEAL_MAX_ATTEMPTS" ]; then
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.3
done

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

# This script runs as root and reaches $DATA_DIR purely by resolving $HOME
# out of getent - it has no other evidence that what it is about to unseal
# belongs to the user being authenticated. It has to check, because nothing
# else does: the sealed blob has no auth value and a PCR7-only policy, so it
# carries no notion of whose it is. Without this, one user could point their
# own data dir at another's (a symlink is enough; the path is entirely theirs
# to shape) and have root unseal the *other* user's keyring password into
# their login. See JOURNAL.md, 2026-09-15.
#
# Ownership of the resolved files, not "is this a symlink": a home directory
# legitimately living behind a symlink is somebody's real setup, and the
# thing that actually matters is who owns what we end up reading. Owned by
# the target user and not writable by group or other - a group-writable data
# dir would let somebody else swap the blob under root's nose.
TARGET_UID="$(getent passwd "$USERNAME" | cut -d: -f3)"
[ -n "$TARGET_UID" ] || exit 1
for f in "$DATA_DIR" "$DATA_DIR/seal.priv" "$DATA_DIR/seal.pub"; do
  owner="$(stat -Lc '%u' "$f" 2>/dev/null || true)"
  mode="$(stat -Lc '%a' "$f" 2>/dev/null || true)"
  if [ "$owner" != "$TARGET_UID" ]; then
    echo "tpm-keyring-unseal: $f is not owned by $USERNAME - refusing to unseal." >&2
    exit 1
  fi
  # 022 = group-write | other-write. The leading 0 makes bash read stat's
  # output as octal; a setuid/sticky prefix ("2755") stays harmless here
  # because the mask only looks at those two bits.
  if [ -z "$mode" ] || [ $(( 0$mode & 022 )) -ne 0 ]; then
    echo "tpm-keyring-unseal: $f is writable by group or other - refusing." >&2
    exit 1
  fi
done

# GDM spawns parallel PAM conversations on one login screen (e.g.
# gdm-fingerprint and gdm-password at once), and this helper is wired into
# both. Two concurrent tpm2_* sequences against the same TPM have been
# observed to fail with "Esys_Unseal ... PCR have changed since checked" -
# one session's PCR-policy check gets invalidated by the other session's
# concurrent activity on the same device. See JOURNAL.md, 2026-08-14. Serialize
# so only one unseal talks to the TPM at a time; the loser just waits its turn
# instead of racing and failing.
# NOT /run/lock: that directory is world-writable (drwxrwxrwt) on a normal
# system, so any local user could create this file first and simply hold the
# lock, stalling every login for the full flock timeout below and then making
# the unseal fail - an unprivileged denial of keyring auto-unlock, needing no
# symlink and no race. /run itself is root-owned and mode 755, so a directory
# created here can only have been created by root. See JOURNAL.md,
# 2026-09-15.
LOCK_DIR=/run/tpm-keyring-unlock
if [ -L "$LOCK_DIR" ] || { [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; }; then
  echo "tpm-keyring-unseal: $LOCK_DIR exists and is not a directory - refusing." >&2
  exit 1
fi
mkdir -p "$LOCK_DIR"
chmod 700 "$LOCK_DIR"
exec 9>"$LOCK_DIR/unseal.lock"
flock -w 10 9 || exit 1

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Fast path: if bin/seal.sh has persisted the primary into the TPM's own NV
# storage (see JOURNAL.md, 2026-08-16), reference that handle directly - no
# recomputation needed. Cuts per-login cost from ~7.4s to well under 1s
# (createprimary alone profiled at ~6.9s on this machine's fTPM, 2026-08-14
# entry). tpm2 primary keys are deterministic (same hierarchy + same
# template = same key every time); a *saved context file* for a transient
# object is tied to the TPM's reset count and becomes unloadable after every
# reboot, which is why the slow path below recreates the primary rather than
# loading a saved primary.ctx - see JOURNAL.md.
#
# The handle is read but never trusted. Two independent reasons, both real:
#
#  1. That persistent object is MACHINE-WIDE, not per-user. bin/seal.sh
#     persists it at one fixed handle shared by every user on the box (the
#     primary is deterministic, so the second user to seal reuses the first
#     user's object). So another user's uninstall.sh evicting it - or a TPM
#     clear, or anything else in the tss group calling tpm2_evictcontrol -
#     leaves this user's primary.handle pointing at an empty handle, with
#     the file itself perfectly intact. Keying the fallback off the file's
#     *absence* (which is what this did until 2026-09-15) never fires in
#     that case: tpm2_load just fails and the keyring silently stops
#     unlocking. See JOURNAL.md, 2026-09-15, and GitHub issue #7.
#  2. The file lives in an unprivileged user's home and this script runs as
#     root during authentication. tpm2_load's -C takes a handle *or a
#     context-file path* (it is spelled --parent-context), so unvalidated
#     file content here is a user steering a root-side open of an arbitrary
#     path. Hence the format check before it is ever passed to a tool.
#
# A failed load is the complete and authoritative test: seal.priv is
# cryptographically bound to its real parent's name, so a wrong or absent
# object at that handle cannot load it, and a foreign object squatting
# there gets ignored rather than used. Deliberately NOT done: verifying the
# handle up front with tpm2_readpublic and comparing names the way
# bin/seal.sh does. The helper has nothing to compare against without first
# deriving a fresh primary - i.e. paying the ~7s createprimary this whole
# fast path exists to avoid - so "verify first" would cost the optimization
# on every login to detect what the load already detects for free.
PRIMARY_HANDLE=""
if [ -f "$DATA_DIR/primary.handle" ]; then
  # `|| true` so an unreadable file (root-squashed NFS home, say) routes to
  # the slow path instead of killing the script under `set -e`. Whitespace
  # is stripped because a stray CR or newline would otherwise be passed to
  # -C verbatim.
  PRIMARY_HANDLE="$(tr -d '[:space:]' <"$DATA_DIR/primary.handle" 2>/dev/null || true)"
  # TPM 2.0 persistent objects live in 0x81000000-0x81ffffff; bin/seal.sh
  # never writes anything else. Anything else is treated as "no handle".
  # Spelled out here rather than sourced from bin/lib.sh's
  # TPM_PERSISTENT_HANDLE_RE on purpose: install.sh copies this script alone
  # to /usr/local/sbin, so the repo (and lib.sh with it) need not exist on
  # the machine at authentication time. Keep the two in step by hand - it is
  # the one place in this project where that duplication is deliberate.
  if ! [[ "$PRIMARY_HANDLE" =~ ^0x81[0-9a-fA-F]{6}$ ]]; then
    echo "tpm-keyring-unseal: $DATA_DIR/primary.handle is not a TPM persistent" >&2
    echo "handle; ignoring it and recreating the primary (slower login). Re-run" >&2
    echo "bin/seal.sh to restore the fast path." >&2
    PRIMARY_HANDLE=""
  fi
fi

# `if ! tpm2_load` rather than `tpm2_load || fallback`, and deliberately not
# wrapped in a function: `set -e` is suppressed for the whole body of a
# function invoked in a condition context, which would silently disarm error
# handling for every command inside it.
LOADED=0
if [ -n "$PRIMARY_HANDLE" ]; then
  if tpm2_load -C "$PRIMARY_HANDLE" \
       -u "$DATA_DIR/seal.pub" -r "$DATA_DIR/seal.priv" \
       -c "$WORKDIR/seal.ctx" >/dev/null 2>"$WORKDIR/load.err"; then
    LOADED=1
  else
    # stderr, never stdout: stdout is the secret channel, and the PAM module
    # copies it verbatim into PAM_AUTHTOK. The module leaves stderr inherited
    # from the login process, so this lands in the journal, where README's
    # troubleshooting section already sends people (`journalctl -b 0 | grep
    # -i tpm`). Says "tpm" on purpose, so that grep finds it.
    echo "tpm-keyring-unseal: the persisted TPM primary at $PRIMARY_HANDLE did not" >&2
    echo "load - it has been evicted (another user's uninstall.sh, or a TPM clear)." >&2
    echo "Recreating it for this login; this adds ~7s. Re-run bin/seal.sh to restore" >&2
    echo "the fast path." >&2
    sed 's/^/tpm-keyring-unseal: tpm2_load: /' "$WORKDIR/load.err" >&2 || true
    # A failed load can still have created a partial context file; the retry
    # below must not be able to succeed off leftovers.
    rm -f "$WORKDIR/seal.ctx"
  fi
fi

# Slow path, unchanged in behavior from before the persisted primary existed:
# recreate the deterministic primary and load under it. Left fatal under
# `set -e` on purpose - if this fails, there is nothing further to try.
# Exactly one retry, never a loop: tpm2_createprimary is deterministic, so a
# second attempt would recompute the identical key and fail identically,
# while costing another ~7s against the PAM module's 25s alarm (which a
# second attempt would blow - see the budget comment in
# pam/pam_tpm_keyring_authtok.c).
if [ "$LOADED" -eq 0 ]; then
  tpm2_createprimary -C o -c "$WORKDIR/primary.ctx" >/dev/null
  tpm2_load -C "$WORKDIR/primary.ctx" \
    -u "$DATA_DIR/seal.pub" -r "$DATA_DIR/seal.priv" \
    -c "$WORKDIR/seal.ctx" >/dev/null
fi

# Note for anyone tempted to "self-heal" here: this script must never write
# to $DATA_DIR. It runs as root during authentication against a path an
# unprivileged user fully controls, so rewriting or deleting primary.handle
# would be a root write through a symlink that user can plant. Re-persisting
# the primary would be worse still - an unattended machine-wide TPM write
# during one user's login, which is the exact class of thing issue #7 is
# about. bin/seal.sh, running as the user, is the only writer. The cost of
# not healing is a slow login plus the warning above, and that is the right
# trade. See JOURNAL.md, 2026-09-15.

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

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

if [ ! -t 0 ]; then
  echo "This script is interactive - it reads your keyring password from the" >&2
  echo "terminal, and must never take it from a pipe or a file. Run it" >&2
  echo "directly from a terminal." >&2
  exit 1
fi

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [ -f "$DATA_DIR/seal.priv" ]; then
  # Y/n like every other prompt in this tool, so install.sh stays a
  # press-Enter-through run; a failed read (no terminal) declines rather than
  # overwriting a working seal. Answering yes no longer deletes anything
  # here - the replacement is built in STAGE_DIR and only moved into place
  # once it has proved it unseals.
  #
  # What STAGE_DIR cannot catch is a typo: it proves the new object unseals to
  # what was typed, not that what was typed is the keyring password. Type the
  # same wrong password twice and a working enrollment is silently replaced by
  # a useless one, which only shows up as the keyring not opening at the next
  # login. Hence the warning - the recovery is just re-running this script
  # with the right password.
  echo "A sealed secret already exists at $DATA_DIR."
  echo "Overwriting replaces it with whatever you type next; nothing here can"
  echo "check that against your actual keyring password. If auto-unlock works"
  echo "today and you did not mean to re-seal, answer n."
  read -rp "Overwrite? [Y/n] " ans || exit 0
  [[ ! "$ans" =~ ^[Nn][Oo]?$ ]] || exit 0
fi

# IFS= on both reads, or the default IFS trims leading and trailing whitespace
# off the password and seals a different secret than the one typed. Nothing
# downstream catches that: both prompts trim identically, so the Confirm check
# passes, and the self-test below compares the unsealed value against the
# already-trimmed $PASSWORD, so it passes too. The only symptom would be the
# keyring silently refusing to open at login. The delivery path preserves
# whitespace (tpm2_unseal writes raw bytes; the PAM module strips at most one
# trailing newline, which `read` cannot produce), so sealing it verbatim is
# what makes the two ends agree.
IFS= read -rsp "Password to seal (should match your GNOME login keyring password): " PASSWORD
echo
IFS= read -rsp "Confirm: " PASSWORD2
echo

if [ "$PASSWORD" != "$PASSWORD2" ]; then
  echo "Passwords did not match." >&2
  unset PASSWORD PASSWORD2
  exit 1
fi

# A TPM seals at most MAX_SYM_DATA bytes (128 in the TPM 2.0 spec) into a
# keyedhash object's sensitive area. Past that, tpm2_create fails far below
# here with a raw TPM error code and no hint that length is the problem -
# after the primary has already been persisted, which looks like the tool
# broke rather than like the password being too long. Checked in bytes, not
# characters: the limit is on bytes, and ${#var} counts characters under a
# UTF-8 locale. The subshell only ever hands back the number - the password
# itself stays in this process, never reaching a pipe, a file or an argv.
MAX_SEALED_BYTES=128
PW_BYTES=$(LC_ALL=C; printf %s "${#PASSWORD}")
if [ "$PW_BYTES" -gt "$MAX_SEALED_BYTES" ]; then
  echo "That password is $PW_BYTES bytes; a TPM can seal at most $MAX_SEALED_BYTES." >&2
  echo "Shorten the keyring password (change it in Passwords and Keys first)," >&2
  echo "then re-run this script. Nothing was changed." >&2
  unset PASSWORD PASSWORD2
  exit 1
fi

WORKDIR=$(mktemp -d)
# Keep the candidate enrollment on the same filesystem as DATA_DIR. The old
# working files remain untouched until the new object has survived a complete
# seal/load/unseal round trip.
STAGE_DIR=$(mktemp -d "$DATA_DIR/.seal-stage.XXXXXX")
chmod 700 "$STAGE_DIR"

SESSION=""
TEST_SESSION=""
TEST_OBJECT=""
cleanup() {
  [ -z "$SESSION" ] || tpm2_flushcontext "$SESSION" >/dev/null 2>&1 || true
  [ -z "$TEST_SESSION" ] || tpm2_flushcontext "$TEST_SESSION" >/dev/null 2>&1 || true
  [ -z "$TEST_OBJECT" ] || tpm2_flushcontext "$TEST_OBJECT" >/dev/null 2>&1 || true
  rm -rf -- "$WORKDIR" "$STAGE_DIR"
}
trap cleanup EXIT

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

# This handle is MACHINE-WIDE, not per-account. Because the primary is
# deterministic, the second user on a machine to run this lands in the
# existing-object branch below, finds a byte-identical key, and reuses it
# rather than burning another of the TPM's scarce persistent-object NV slots
# on a copy. That sharing is deliberate and stays - but it means the object
# has no single owner, and the TPM offers no way to ask who still depends on
# it, which is why uninstall.sh has to look for other users' recorded handles
# on disk before evicting (bin/lib.sh's tpm_primary_handle_dependents) and
# why pam/tpm-keyring-unseal.sh treats a dead handle as recoverable rather
# than fatal. See JOURNAL.md, 2026-08-16 and 2026-09-15, and GitHub issue #7.
PRIMARY_HANDLE_DEFAULT="0x81018000"
if [ -f "$DATA_DIR/primary.handle" ]; then
  PRIMARY_HANDLE="$(tr -d '[:space:]' <"$DATA_DIR/primary.handle" 2>/dev/null || true)"
  # Validated before it can reach a tpm2_* tool: -C is --parent-context and
  # takes a context-FILE PATH as readily as a handle, so an unvalidated file
  # here would let its contents redirect what gets opened. A file that isn't
  # a persistent handle is treated as no record at all.
  if ! tpm_handle_is_wellformed "$PRIMARY_HANDLE"; then
    echo "$DATA_DIR/primary.handle doesn't contain a TPM persistent handle" >&2
    echo "(expected something like $PRIMARY_HANDLE_DEFAULT). Ignoring it and" >&2
    echo "using the default." >&2
    PRIMARY_HANDLE="$PRIMARY_HANDLE_DEFAULT"
  fi
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
printf '%s\n' "$PRIMARY_HANDLE" >"$STAGE_DIR/primary.handle"

SESSION="$WORKDIR/session"
tpm2_startauthsession -S "$SESSION" --policy-session >/dev/null
tpm2_policypcr -S "$SESSION" -l "$PCR_BANK" -L "$STAGE_DIR/pcr.policy" >/dev/null
tpm2_flushcontext "$SESSION" >/dev/null
SESSION=""

printf '%s' "$PASSWORD" | tpm2_create -C "$PRIMARY_HANDLE" \
  -u "$STAGE_DIR/seal.pub" -r "$STAGE_DIR/seal.priv" \
  -L "$STAGE_DIR/pcr.policy" -i- >/dev/null

# Prove the complete candidate is usable before replacing a known-good
# enrollment. This catches partial/corrupt tpm2_create output and policy or
# TPM failures while rollback is still just deleting STAGE_DIR.
TEST_OBJECT="$WORKDIR/test-seal.ctx"
tpm2_load -C "$PRIMARY_HANDLE" \
  -u "$STAGE_DIR/seal.pub" -r "$STAGE_DIR/seal.priv" \
  -c "$TEST_OBJECT" >/dev/null

TEST_SESSION="$WORKDIR/test-session"
tpm2_startauthsession -S "$TEST_SESSION" --policy-session >/dev/null
tpm2_policypcr -S "$TEST_SESSION" -l "$PCR_BANK" >/dev/null
# Into a shell variable, never a file. $WORKDIR is a mktemp -d under /tmp,
# which is tmpfs on most distros but tmpfs pages are swappable, and swap is
# not necessarily on an encrypted volume - so writing the unsealed keyring
# password there can land the one secret this whole tool exists to protect
# on disk in the clear. A command substitution keeps it in this process's
# memory, like $PASSWORD itself, and it is not a pipeline, so `set -e` still
# aborts the seal if tpm2_unseal genuinely fails instead of silently
# comparing against nothing. No trailing-newline hazard: $PASSWORD comes
# from `read`, so it cannot contain one for the stripping to matter.
UNSEALED="$(tpm2_unseal -c "$TEST_OBJECT" -p "session:$TEST_SESSION")"

# Best-effort, exactly like pam/tpm-keyring-unseal.sh does after its own
# unseal - NOT decoration. Once tpm2_unseal has consumed the session, the
# kernel resource manager behind /dev/tpmrm0 has already dropped both
# handles, so these saved context files no longer resolve and
# tpm2_flushcontext exits non-zero ("Could not load session context" /
# "Argument neither a session nor a transient"). Under `set -e` that aborted
# the whole seal *after* a successful self-test. Nothing leaks by tolerating
# it: the resource manager is what cleaned them up in the first place, and
# the EXIT trap re-tries the same flushes just as tolerantly.
tpm2_flushcontext "$TEST_SESSION" >/dev/null 2>&1 || true
TEST_SESSION=""
tpm2_flushcontext "$TEST_OBJECT" >/dev/null 2>&1 || true
TEST_OBJECT=""

if [ "$UNSEALED" != "$PASSWORD" ]; then
  echo "TPM self-test returned a different secret; keeping the previous enrollment." >&2
  unset PASSWORD PASSWORD2 UNSEALED
  exit 1
fi

# Explicit modes rather than whatever the umask happens to be: install.sh may
# run this inside `sg tss`, which makes tss the primary group, and none of
# these should be readable by that group even if $DATA_DIR's own 700 were ever
# loosened. Set here, before the mv below, so the files are never visible at
# their final names with any other mode.
chmod 600 "$STAGE_DIR/pcr.policy" "$STAGE_DIR/seal.pub" \
  "$STAGE_DIR/seal.priv" "$STAGE_DIR/primary.handle"

unset PASSWORD PASSWORD2 UNSEALED

# Each file is now complete, verified, and on the destination filesystem.
# No earlier failure path modifies the previous enrollment.
for name in pcr.policy seal.pub seal.priv primary.handle; do
  mv -f "$STAGE_DIR/$name" "$DATA_DIR/$name"
done

echo "Sealed and self-tested. Bound to this TPM and the current PCR7 (Secure Boot) state."
echo "Log out and back in to test the actual auto-unlock (via install.sh's"
echo "PAM wiring), or check it directly with:"
echo "  sudo /usr/local/sbin/tpm-keyring-unseal \$USER >/dev/null; echo \$?"

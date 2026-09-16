#!/usr/bin/env bash
# Installs tpm-keyring-unlock: TPM-backed auto-unlock of the GNOME login
# keyring, working for both password and fingerprint logins, without
# blanking the keyring password. See README.md for how/why this works.
#
# Safe by design at every step except the /etc/pam.d/ edits, of which there
# are two, both backed up first: the line it adds to the fingerprint PAM
# stack is "optional" and cannot itself grant or block login, and the one it
# can optionally make to pam_fprintd.so (an attempt stack, only ever on a
# fingerprint-only stack) changes how many times the sensor is re-armed
# before the prompt gives up, never who gets in. See README.md "How it works" before running this if you
# want to understand exactly what it touches.
set -euo pipefail

# readlink -f, because a packaged copy of this script is reached through a
# symlink in $PATH and dirname of the *link* would point at /usr/bin.
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DATA_DIR="$HOME/.local/share/tpm-keyring-unlock"
# Overridable so a distribution package can point at its own helper: /usr/local
# is off limits to packages, so `make install` puts it under libexec and the
# generated wrapper passes the path in. The hand-rolled install keeps the path
# it has always used, which is also the one compiled into the module by default.
HELPER_DST="${TPM_KEYRING_HELPER:-/usr/local/sbin/tpm-keyring-unseal}"
PCR_BANK="sha256:7"

# Two layouts to support: a git checkout (bin/lib.sh, bin/seal.sh) and an
# installed copy, where everything lands flat in one libexec directory.
LIB_SH="$REPO_DIR/bin/lib.sh"
[ -f "$LIB_SH" ] || LIB_SH="$REPO_DIR/lib.sh"
SEAL_SH="$REPO_DIR/bin/seal.sh"
[ -f "$SEAL_SH" ] || SEAL_SH="$REPO_DIR/seal.sh"

# shellcheck source=bin/lib.sh
source "$LIB_SH"

# --no-build: the PAM module and the helper are already on disk, put there by
# a distribution package, so this run must not compile or install them - it
# only does the parts a package is not allowed to do (sealing a secret, which
# needs the user's password, and editing /etc/pam.d, which needs consent).
DO_BUILD=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=false ;;
    -h | --help)
      echo "usage: ${0##*/} [--no-build]"
      echo "  --no-build  configure only; expects the module and helper to be installed"
      exit 0
      ;;
    *)
      echo "${0##*/}: unknown option '$1'" >&2
      exit 2
      ;;
  esac
  shift
done

confirm() {
  local prompt="$1"
  local ans
  # Defaults to yes: an empty answer accepts. A failed read (EOF, i.e. no
  # terminal) is a "no", so nothing here can be auto-approved by a pipe.
  read -rp "$prompt [Y/n] " ans || return 1
  [[ ! "$ans" =~ ^[Nn][Oo]?$ ]]
}

# One timestamp for the whole run, so a file touched by two different steps
# below gets exactly one backup, holding its pristine pre-run content -
# rather than a second backup of the already-half-edited file.
RUN_TS="$(date +%Y%m%d%H%M%S)"

# Backs a PAM file up before its first modification in this run.
backup_pam_file() {
  local f="$1" bak="$1.bak-$RUN_TS"
  [ -e "$bak" ] || sudo cp "$f" "$bak"
}

# Removes pam_fprintd from the shared auth stack, the only supported way.
# A function because it is called from two places: the planned step below, and
# the final check at the end of the run, which offers it again if the machine
# still has the conflict. Duplicating this guarded write would be a way for
# the two copies to drift, and it is the one write in this script that can
# lock the machine out.
disable_fprintd_profile() {
  local f RC
  local common_files=()
  echo "-- Fixing the lock screen --"
  # Re-checked here for the same reason the fprintd step above re-checks
  # eligibility: the plan was printed before the package install, and on this
  # family of distros that step can run pam-auth-update itself.
  if ! pam_fprintd_in_shared_stack; then
    echo "Already gone from $PAM_SHARED_AUTH_STACK - nothing to do."
  elif ! pam_auth_update_owns_fprintd; then
    echo "The pam_fprintd.so line in $PAM_SHARED_AUTH_STACK is no longer" >&2
    echo "pam-auth-update's - left untouched, so the extra tries get no sensor." >&2
  else
    # Derived from the shared stack's own location rather than hard-coded, so
    # the restore path below is reachable from the tests.
    for f in "$(dirname "$PAM_SHARED_AUTH_STACK")"/common-*; do
      [ -f "$f" ] || continue
      if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi
      common_files+=("$f")
      # pam-auth-update regenerates every common-* file, not just common-auth,
      # so every one of them gets the same pre-edit copy install.sh takes
      # before any other login-critical write.
      backup_pam_file "$f"
    done

    # DEBIAN_FRONTEND=noninteractive on purpose. pam-auth-update refuses to
    # rewrite common-* files carrying local modifications it cannot reconcile
    # against /var/lib/pam, and asks about overriding at debconf's *high*
    # priority - i.e. it would stop this script with a whiptail dialog. With
    # the noninteractive frontend that question takes its default, which is
    # "don't override", so the refusal is a printed no-op instead. Caught
    # below and reported. --force is deliberately not used: it discards local
    # modifications to all four common-* files, which is not this installer's
    # call to make.
    RC=0
    sudo env DEBIAN_FRONTEND=noninteractive pam-auth-update --disable fprintd || RC=$?
    [ "$RC" = 0 ] || echo "pam-auth-update exited $RC." >&2

    if pam_shared_stack_is_sane_without_fprintd; then
      mkdir -p "$DATA_DIR"
      # Records that *this tool* disabled a profile that was enabled before.
      # uninstall.sh re-enables only on the strength of this file, so a user
      # who had fprintd disabled themselves never gets it switched back on.
      {
        echo "# written by install.sh at $RUN_TS: the 'fprintd' pam-auth-update"
        echo "# profile was enabled before this run and was disabled here, so the"
        echo "# attempt stack could get the sensor. uninstall.sh offers to undo it."
      } >"$DATA_DIR/$PAM_FPRINTD_PROFILE_MARKER"
      chmod 0644 "$DATA_DIR/$PAM_FPRINTD_PROFILE_MARKER"
      echo "Done. Backup: <file>.bak-$RUN_TS. Undo: pam-auth-update --enable fprintd"
    elif pam_fprintd_in_shared_stack; then
      # Refused, nothing written: the line is still there and the file is
      # otherwise untouched. Nothing to restore, but say what to do next.
      echo "pam-auth-update refused (local modifications in common-*); nothing" >&2
      echo "changed. Run 'sudo pam-auth-update' and untick 'Fingerprint" >&2
      echo "authentication', or add --force to discard those local edits." >&2
    else
      # It wrote something, and what came out has no fingerprint line *and* no
      # primary auth module - i.e. a stack nobody can log in through. Put the
      # pre-run copies straight back; this is the one step in this script that
      # could lock the machine out.
      echo "pam-auth-update left $PAM_SHARED_AUTH_STACK with no usable auth" >&2
      echo "module - restoring the pre-run copies of every common-* file." >&2
      for f in "${common_files[@]}"; do
        [ -f "$f.bak-$RUN_TS" ] || continue
        sudo cp "$f.bak-$RUN_TS" "$f"
        echo "Restored $f" >&2
      done
      echo "Check $PAM_SHARED_AUTH_STACK before logging out." >&2
    fi
  fi
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

echo "== tpm-keyring-unlock installer =="
echo

# --- 0. hard requirements - checked before touching anything, including
# before installing dependencies, so a machine that can't use this tool
# finds out immediately instead of after a sudo package install -----------
[ -e /dev/tpmrm0 ] || {
  echo "No /dev/tpmrm0 - is TPM 2.0 enabled in BIOS/UEFI?" >&2
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
    echo "Missing: ${missing[*]}" >&2
    echo "No apt/dnf/pacman/zypper found - install tpm2-tools, gcc and the PAM" >&2
    echo "headers (security/pam_modules.h) yourself, then re-run." >&2
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
  echo "No 'tss' group here - TPM access must come from somewhere else."
  echo
fi

# 1c. seal vs. re-seal
RESEAL=false
[ -f "$DATA_DIR/seal.priv" ] && RESEAL=true

# 1d. login PAM stacks that need the helper wired in
mapfile -t candidates < <(grep -lE "$PAM_GNOME_KEYRING_AUTH_RE" /etc/pam.d/* 2>/dev/null \
  | grep -vE "$PAM_NON_SERVICE_RE")
targets=()
# Stacks where a password module runs BELOW the pam_gnome_keyring auth line.
# Our module sets PAM_AUTHTOK from the TPM before anyone has authenticated, so
# anything down there that takes its password from PAM_AUTHTOK instead of
# prompting would let a login through on a secret nobody typed. Collected
# separately and reported, never patched. See bin/lib.sh's
# pam_auth_insertion_point_is_safe and JOURNAL.md, 2026-09-15.
unsafe_targets=()
for c in "${candidates[@]}"; do
  if grep -q pam_tpm_keyring_authtok.so "$c"; then continue; fi
  if pam_auth_insertion_point_is_safe "$c"; then
    targets+=("$c")
  else
    unsafe_targets+=("$c")
  fi
done

# 1e. fingerprint stacks that drop the reader after one unlucky scan or one
# idle timeout. Both cases make pam_fprintd return PAM_AUTHINFO_UNAVAIL -
# "there is no such auth method here" rather than "that did not match" - and
# gnome-shell treats that as permanent: fingerprint is gone for the rest of
# the unlock prompt and only the password is left, with the sensor sitting
# right there working. pam_fprintd_harden() gives the stack extra attempts,
# each keeping the module's own idle deadline. Full chain, traced through
# gnome-shell's gdm/util.js and
# pam_fprintd's disassembly, in JOURNAL.md (2026-09-14).
UNLIMIT_FPRINTD=false
FPRINTD_STACK_PRESENT=false
fprintd_targets=()
if pam_fprintd_supports_attempt_options; then
  for f in /etc/pam.d/*; do
    [ -f "$f" ] || continue
    if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi
    if ! grep -qE "$PAM_FPRINTD_AUTH_RE" "$f"; then continue; fi
    # already in the target state - hardening it again would change nothing,
    # but it still means an attempt stack is in place, which is what decides
    # whether the shared-stack conflict in 1f below is worth raising at all
    if pam_fprintd_harden <"$f" | cmp -s - "$f"; then
      FPRINTD_STACK_PRESENT=true
      continue
    fi
    # the whole eligibility rule lives in bin/lib.sh, because step 3 below has
    # to apply the exact same one again just before it writes
    if ! pam_fprintd_stack_is_eligible "$f"; then continue; fi
    fprintd_targets+=("$f")
  done
fi

if [ "${#fprintd_targets[@]}" -gt 0 ]; then
  # The full account - why one bad scan kills the prompt, why max-tries=
  # doesn't cover it, why only fingerprint-only stacks qualify - is in
  # README.md and JOURNAL.md. Printing it here made every run a wall of text.
  echo "Optional: one bad scan or a 30s idle ends your fingerprint prompt for"
  echo "good. This gives it $PAM_FPRINTD_ATTEMPTS attempts, in ${fprintd_targets[*]##*/} (README.md)."
  if confirm "Let the reader try $PAM_FPRINTD_ATTEMPTS times per prompt instead of once?"; then
    UNLIMIT_FPRINTD=true
  else
    echo "Left as it is."
  fi
  echo
fi

# 1f. the shared auth stack racing the hardened one for the sensor. The
# attempt stack above is dead code while pam_fprintd is also in common-auth:
# gnome-shell opens gdm-password and gdm-fingerprint as two PAM conversations
# at once, both reach for the same reader, and gdm-password wins. Full
# measurement and reasoning in bin/lib.sh next to the predicates, and in
# JOURNAL.md, 2026-09-15.
FPRINTD_CONFLICT_FIX=false
conflict_losers=()
if { [ "$UNLIMIT_FPRINTD" = true ] || [ "$FPRINTD_STACK_PRESENT" = true ]; } \
  && pam_fprintd_in_shared_stack; then
  mapfile -t conflict_losers < <(pam_fprintd_services_losing_fingerprint)

  # Same trade as above: the greeter race, the D-Bus round trip that decides
  # it, and why fingerprint cannot live in the shared stack are all in
  # README.md, 'Fingerprint for sudo'. Two lines here, not twenty.
  echo "It only gets the sensor if pam_fprintd.so leaves $PAM_SHARED_AUTH_STACK -"
  echo "the shared stack wins that race at the greeter. Why: README.md."

  if pam_auth_update_owns_fprintd; then
    if [ "${#conflict_losers[@]}" -gt 0 ]; then
      # The reassurance stays ahead of the list: it is long, mostly services
      # that never prompt for a finger (cron, cups, ppp), and leading with it
      # makes the change look bigger than it is. See JOURNAL.md, 2026-09-15.
      echo "Cost: ${#conflict_losers[@]} services fall back to the password (polkit above all);"
      echo "sudo, GDM and the lock screen keep it: ${conflict_losers[*]##*/}"
    fi
    if confirm "Fix the lock screen? Fingerprint stops being offered in polkit prompts."; then
      FPRINTD_CONFLICT_FIX=true
    else
      echo "Left as it is - the extra tries will not reach the reader."
    fi
  else
    # Not pam-auth-update's line, so this tool has no supported way to remove
    # it and will not hand-edit a login-critical file it did not write.
    echo "Not a pam-auth-update line - remove it yourself, or the stack is inert."
  fi
  echo
fi

# --- 2. print the full plan and ask for approval exactly once ------------
# Every path listed below is in the same directory, so the lists print as bare
# service names with the directory named once.
pam_names() {
  local p out=""
  for p in "$@"; do out="$out ${p##*/}"; done
  printf '%s' "${out# }"
}
echo "This installer will make the following changes:"
echo
n=1
if [ "${#PKGS[@]}" -gt 0 ]; then
  echo "  $n. Install via $PKG_MGR (needs sudo): ${PKGS[*]}"
  n=$((n + 1))
fi
if [ "$NEED_TSS_ADD" = true ]; then
  echo "  $n. Add $USER to 'tss' for TPM access (sudo); the rest of the run"
  echo "     continues inside 'sg tss', so no logout is needed."
  n=$((n + 1))
fi
if [ "$DO_BUILD" = true ]; then
  echo "  $n. Compile + install the PAM module and helper, and mask systemd's"
  echo "     eager gnome-keyring-daemon startup (sudo)."
else
  echo "  $n. Mask systemd's eager gnome-keyring-daemon startup."
fi
n=$((n + 1))
if [ "$RESEAL" = true ]; then
  echo "  $n. Re-seal (overwrite) the existing sealed secret at $DATA_DIR."
else
  echo "  $n. Seal your keyring password into the TPM."
fi
n=$((n + 1))
if [ "$UNLIMIT_FPRINTD" = true ]; then
  echo "  $n. Rewrite pam_fprintd.so into $PAM_FPRINTD_ATTEMPTS attempts (backed up) in"
  echo "     /etc/pam.d/$(pam_names "${fprintd_targets[@]}"), as:"
  pam_fprintd_harden <"${fprintd_targets[0]}" | grep -E "$PAM_FPRINTD_AUTH_RE" \
    | sed -E 's/\[success=([0-9]+).*default=die\]/[success=\1 ...die]/; s/\t/ /g; s/^/       /' 
  n=$((n + 1))
fi
if [ "$FPRINTD_CONFLICT_FIX" = true ]; then
  echo "  $n. Disable the 'fprintd' pam-auth-update profile, taking"
  echo "     pam_fprintd.so out of $PAM_SHARED_AUTH_STACK (common-* backed up)."
  n=$((n + 1))
fi
if [ "${#targets[@]}" -gt 0 ]; then
  # One 'optional' line above the existing keyring line, in each stack. The
  # diff is printed once rather than per file: it is the same two lines every
  # time, and repeating them per target was most of this plan's length.
  echo "  $n. Wire the TPM helper into these, in /etc/pam.d (all backed up):"
  echo "       $(pam_names "${targets[@]}")"
  echo "     + auth  optional  pam_tpm_keyring_authtok.so  <-- new, above the"
  echo "       auth  optional  pam_gnome_keyring.so         existing line"
fi
# Reported whether or not anything is being wired up: a refused stack is the
# one case where the tool declines to do what the user asked, so it must not
# be silent about it.
if [ "${#unsafe_targets[@]}" -gt 0 ]; then
  echo
  echo "  !! NOT wiring $(pam_names "${unsafe_targets[@]}"):"
  echo "     a password module sits below their keyring auth line, which"
  echo "     try_first_pass could turn into a login on a secret nobody typed."
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
  echo "Added $USER to 'tss'."
  echo
fi

# A new group only applies to new sessions, so the TPM steps below would fail
# in this one - that's what used to make this script stop here and ask for a
# logout and a second run. `sg` starts a shell that reads the group database
# fresh, so the run can simply continue inside it. Verified: it keeps the
# terminal (seal.sh still reads the password from the tty, never a pipe) and
# every supplementary group (so the sudo calls further down still work); only
# the primary group differs, which is why seal.sh sets explicit modes on the
# files it writes rather than trusting the umask.
USE_SG=false
if ! tpm2_pcrread "$PCR_BANK" >/dev/null 2>&1 \
  && command -v sg >/dev/null 2>&1 \
  && id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx tss; then
  USE_SG=true
fi

tpm_run() {
  if [ "$USE_SG" = true ]; then
    sg tss -c "$(printf '%q ' "$@")"
  else
    "$@"
  fi
}

if ! tpm_run tpm2_pcrread "$PCR_BANK" >/dev/null 2>&1; then
  if [ "$NEED_TSS_ADD" = true ]; then
    echo "Added you to 'tss', but still can't read TPM PCRs and 'sg' didn't" >&2
    echo "work either. Log out, back in, and re-run - nothing else was done." >&2
  elif [ "$TSS_GROUP_PRESENT" = true ]; then
    echo "Can't read TPM PCRs though you're in 'tss' - log out, back in," >&2
    echo "then re-run." >&2
  else
    echo "Can't read TPM PCRs and there's no 'tss' group - check how your" >&2
    echo "distro grants /dev/tpmrm0 access." >&2
  fi
  exit 1
fi

if [ "$USE_SG" = true ]; then
  echo "Running the TPM steps inside 'sg tss'."
  echo
fi

PAM_MODULE_DIR="$(find_pam_module_dir || true)"
if [ -z "$PAM_MODULE_DIR" ]; then
  echo "Couldn't find the PAM module directory (no pam_unix.so). Locate it" >&2
  echo "(dpkg -L libpam-modules | grep pam_unix.so) and install" >&2
  echo "pam/pam_tpm_keyring_authtok.so there by hand." >&2
  exit 1
fi

if [ "$DO_BUILD" = true ]; then
  echo "-- Build + install --"
  gcc -Wall -Wextra -fPIC -shared \
    -o "$REPO_DIR/pam/pam_tpm_keyring_authtok.so" \
    "$REPO_DIR/pam/pam_tpm_keyring_authtok.c" -lpam

  sudo install -o root -g root -m 0700 \
    "$REPO_DIR/pam/tpm-keyring-unseal.sh" "$HELPER_DST"
  sudo install -o root -g root -m 0644 \
    "$REPO_DIR/pam/pam_tpm_keyring_authtok.so" \
    "$PAM_MODULE_DIR/pam_tpm_keyring_authtok.so"
else
  # Checked, not assumed: wiring a PAM stack to a module that is not there
  # would leave every login logging "module not found" on a file that cannot
  # be fixed without a working shell.
  missing_parts=()
  [ -f "$PAM_MODULE_DIR/pam_tpm_keyring_authtok.so" ] \
    || missing_parts+=("$PAM_MODULE_DIR/pam_tpm_keyring_authtok.so")
  [ -e "$HELPER_DST" ] || missing_parts+=("$HELPER_DST")
  if [ "${#missing_parts[@]}" -gt 0 ]; then
    echo "--no-build was given, but this is missing: ${missing_parts[*]}" >&2
    echo "Install the package properly, or run without --no-build." >&2
    exit 1
  fi
fi

echo
echo "-- Mask the eager keyring daemon units --"
if systemctl --user list-unit-files 'gnome-keyring-daemon.*' 2>/dev/null | grep -q gnome-keyring-daemon; then
  systemctl --user mask gnome-keyring-daemon.socket gnome-keyring-daemon.service
  echo "Masked. Undo: systemctl --user unmask gnome-keyring-daemon.{socket,service}"
else
  echo "No gnome-keyring-daemon.* user units - nothing to mask."
fi

echo
if [ "$RESEAL" = true ]; then
  echo "-- Re-seal into the TPM --"
else
  echo "-- Seal into the TPM --"
fi
tpm_run "$SEAL_SH"

echo
if [ "$UNLIMIT_FPRINTD" = true ]; then
  echo "-- Fingerprint attempts --"
  rewritten_stacks=()
  for TARGET in "${fprintd_targets[@]}"; do
    # The plan was made before the package install above, and on some distros
    # that step regenerates /etc/pam.d files on its own (pam-auth-update out of
    # libpam-runtime's postinst, a gdm upgrade shipping its own
    # gdm-fingerprint). So prove eligibility again against what is on disk
    # right now: the invariant check below only proves the rewrite is faithful
    # to the current content, never that the current content is still a file
    # this tool may touch. A stack that has gained an `auth required
    # pam_unix.so` since passes every one of those checks, and writing it
    # would put an attempt stack into a shared stack. See JOURNAL.md,
    # 2026-09-15.
    if pam_fprintd_harden <"$TARGET" | cmp -s - "$TARGET"; then
      echo "${TARGET##*/}: already in the target state."
      continue
    fi
    if ! pam_fprintd_stack_is_eligible "$TARGET"; then
      echo "$TARGET changed since the plan was printed and no longer" >&2
      echo "qualifies - left untouched. Re-run to reconsider it." >&2
      continue
    fi
    REWRITTEN="$(mktemp)"
    pam_fprintd_harden <"$TARGET" >"$REWRITTEN"
    # Login-critical file, so refuse anything that isn't recognisably the same
    # file with only the fprintd auth lines changed: every other line byte for
    # byte identical, and exactly the expected number of attempt lines.
    if ! diff -q <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$TARGET") \
        <(grep -vE "$PAM_FPRINTD_AUTH_RE" "$REWRITTEN") >/dev/null \
      || [ "$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$REWRITTEN")" != "$PAM_FPRINTD_ATTEMPTS" ] \
      || [ "$(grep -cE "$PAM_FPRINTD_RETRY_LINE_RE" "$REWRITTEN")" != "$((PAM_FPRINTD_ATTEMPTS - 1))" ]; then
      echo "Unexpected result rewriting $TARGET - left it untouched." >&2
      rm -f "$REWRITTEN"
      continue
    fi
    backup_pam_file "$TARGET"
    # cp *onto* the existing file rather than replacing it, so its mode and
    # ownership stay exactly as the distro shipped them.
    sudo cp "$REWRITTEN" "$TARGET"
    rm -f "$REWRITTEN"
    rewritten_stacks+=("$TARGET")
  done
  [ "${#rewritten_stacks[@]}" -eq 0 ] || echo "Rewritten: ${rewritten_stacks[*]##*/}"
  echo
fi

if [ "$FPRINTD_CONFLICT_FIX" = true ]; then
  disable_fprintd_profile
  echo
fi

echo "-- Login PAM stacks --"
wired_stacks=()
if [ "${#candidates[@]}" -eq 0 ]; then
  echo "No service has an auth-phase pam_gnome_keyring.so line - password"
  echo "logins are already fixed by the mask above. See README.md."
else
  for TARGET in "${candidates[@]}"; do
    # Same race the fprintd step above guards against: this list was built
    # before the package install, which can remove, rename or regenerate a
    # file under /etc/pam.d. Without the re-check a vanished target falls
    # straight through to backup_pam_file -> sudo cp on a missing path, which
    # under `set -e` aborts the run with nothing but cp's error, after the
    # fprintd edits are already written. See JOURNAL.md, 2026-09-15.
    if [ ! -f "$TARGET" ] || ! grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" "$TARGET"; then
      echo "$TARGET changed since the plan above was printed (gone, or no" >&2
      echo "auth-phase pam_gnome_keyring.so line any more) - left untouched." >&2
      continue
    fi
    if grep -q pam_tpm_keyring_authtok.so "$TARGET"; then
      echo "${TARGET##*/}: already wired in."
      continue
    fi
    # Re-checked here, not just when the plan was built, for the same reason
    # the existence check above is: the package install between the two can
    # rewrite a file under /etc/pam.d. This is the check that must not be
    # skipped on a stale plan - getting it wrong writes a login bypass.
    if ! pam_auth_insertion_point_is_safe "$TARGET"; then
      echo "$TARGET has a password module below its pam_gnome_keyring.so auth" >&2
      echo "line - left untouched (see the note printed above)." >&2
      continue
    fi
    backup_pam_file "$TARGET"
    sudo sed -E -i "/${PAM_GNOME_KEYRING_AUTH_RE}/i auth    optional        pam_tpm_keyring_authtok.so" "$TARGET"
    wired_stacks+=("$TARGET")
  done
  [ "${#wired_stacks[@]}" -eq 0 ] || echo "Wired: ${wired_stacks[*]##*/}"
fi

echo
echo "Log out and back in to test."

# --- 4. did the fingerprint side actually end up able to work? -----------
# The attempt stack fails silently when it loses the sensor: it returns
# "reader unavailable" in under a second, GNOME falls back to the password,
# and what the user sees is indistinguishable from the bug it was installed to
# fix. That happened on the reporting machine - the installer asked, the answer
# was no, and the run still ended with "log out and back in to test", which
# reads as success. So the state on disk is checked here and said plainly. See
# JOURNAL.md, 2026-09-15.
fprintd_stack_installed=false
for f in /etc/pam.d/*; do
  [ -f "$f" ] || continue
  if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi
  if grep -qE "$PAM_FPRINTD_RETRY_LINE_RE" "$f"; then
    fprintd_stack_installed=true
    break
  fi
done

if [ "$fprintd_stack_installed" = true ] && pam_fprintd_in_shared_stack; then
  echo
  echo "!! The attempt stack is inert: pam_fprintd.so is still in"
  echo "   $PAM_SHARED_AUTH_STACK and wins the race for the sensor."
  if [ "$FPRINTD_CONFLICT_FIX" = true ]; then
    # Already attempted this run and the line is still there, so the step
    # above printed why. Repeating the offer would just repeat the failure.
    echo "   The step earlier in this run could not remove it - see above."
  elif pam_auth_update_owns_fprintd; then
    echo "   Fix: sudo pam-auth-update --disable fprintd (undo: --enable)."
    if confirm "Fix the lock screen? Fingerprint stops being offered in polkit prompts."; then
      disable_fprintd_profile
      pam_fprintd_in_shared_stack && echo "Still there - see above." || true
    else
      echo "Left alone."
    fi
  else
    echo "   Not a pam-auth-update line - remove it yourself."
  fi

  # Re-checked, because the offer above may have just fixed it. Everything
  # else this installer does succeeded, but if the line is still there the
  # fingerprint stack it wrote provably cannot get the sensor - so say that
  # in the exit status too, not only in a paragraph somebody may scroll past.
  # "install.sh finished 0" must not mean "and the thing it installed does
  # nothing". Checked first that nothing keys off the status: no test, no
  # Makefile target and no CI job runs install.sh. See JOURNAL.md, 2026-09-15.
  if pam_fprintd_in_shared_stack; then
    echo "(exit 2: everything else is installed; the attempt stack stays inert)"
    exit 2
  fi
fi

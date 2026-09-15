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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/.local/share/tpm-keyring-unlock"
HELPER_DST="/usr/local/sbin/tpm-keyring-unseal"
PCR_BANK="sha256:7"

# shellcheck source=bin/lib.sh
source "$REPO_DIR/bin/lib.sh"

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
    echo "The pam_fprintd.so line in $PAM_SHARED_AUTH_STACK is no longer one" >&2
    echo "pam-auth-update manages - left untouched. The extra tries will not" >&2
    echo "reach the reader at the lock screen while that line is there." >&2
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
        echo "# written by install.sh at $RUN_TS"
        echo "# The 'fprintd' pam-auth-update profile was enabled before this"
        echo "# run and was disabled so the fingerprint attempt stack could"
        echo "# actually get the sensor. uninstall.sh offers to re-enable it."
      } >"$DATA_DIR/$PAM_FPRINTD_PROFILE_MARKER"
      chmod 0644 "$DATA_DIR/$PAM_FPRINTD_PROFILE_MARKER"
      echo "Done. Nothing else reaches for the reader first now, so the"
      echo "login and lock screen get it and the extra tries work."
      echo "Previous content backed up as <file>.bak-$RUN_TS."
      echo "(undo any time: sudo pam-auth-update --enable fprintd)"
    elif pam_fprintd_in_shared_stack; then
      # Refused, nothing written: the line is still there and the file is
      # otherwise untouched. Nothing to restore, but say what to do next.
      echo "pam-auth-update left the line in place - it will not rewrite" >&2
      echo "common-* files that carry local modifications it can't reconcile." >&2
      echo "Nothing was changed. Run 'sudo pam-auth-update' yourself and" >&2
      echo "untick 'Fingerprint authentication', or re-run it with --force if" >&2
      echo "you are happy to lose local edits to the common-* files." >&2
    else
      # It wrote something, and what came out has no fingerprint line *and* no
      # primary auth module - i.e. a stack nobody can log in through. Put the
      # pre-run copies straight back; this is the one step in this script that
      # could lock the machine out.
      echo "pam-auth-update produced a $PAM_SHARED_AUTH_STACK with no usable" >&2
      echo "auth module - restoring the pre-run copies of every common-* file." >&2
      for f in "${common_files[@]}"; do
        [ -f "$f.bak-$RUN_TS" ] || continue
        sudo cp "$f.bak-$RUN_TS" "$f"
        echo "Restored $f" >&2
      done
      echo "Nothing else was changed. Please check $PAM_SHARED_AUTH_STACK" >&2
      echo "before logging out." >&2
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
mapfile -t candidates < <(grep -lE "$PAM_GNOME_KEYRING_AUTH_RE" /etc/pam.d/* 2>/dev/null \
  | grep -vE "$PAM_NON_SERVICE_RE")
targets=()
for c in "${candidates[@]}"; do
  grep -q pam_tpm_keyring_authtok.so "$c" || targets+=("$c")
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
  echo "Optional extra, independent of the TPM part of this tool:"
  echo
  echo "Your fingerprint PAM stack gives up for the rest of the lock screen -"
  echo "password only, until you dismiss the prompt and bring it back - after"
  echo "either a 30s idle timeout or a single badly angled scan. Both make the"
  echo "module report the reader as *unavailable* rather than as a failed"
  echo "attempt, and GNOME stops offering fingerprint for good. max-tries="
  echo "does not cover the bad-scan case; only a mismatch decrements it."
  echo
  echo "This installer can give the reader $PAM_FPRINTD_ATTEMPTS attempts per prompt, by"
  echo "rewriting that one pam_fprintd.so line into a short stack. Each attempt"
  echo "keeps the module's own idle deadline, so the prompt still ends and"
  echo "falls back to the password. Only fingerprint-only stacks are eligible,"
  echo "never a shared one like common-auth: PAM is serialised, so $PAM_FPRINTD_ATTEMPTS waits on"
  echo "the sensor there would delay sudo's password prompt that much longer."
  echo "Eligible on this machine:"
  echo
  for f in "${fprintd_targets[@]}"; do
    echo "  $f"
  done
  echo
  if confirm "Let the reader try $PAM_FPRINTD_ATTEMPTS times per prompt instead of once?"; then
    UNLIMIT_FPRINTD=true
  else
    echo "Leaving the fingerprint stack as it is."
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

  echo "One more thing - without it the attempt stack above does nothing:"
  echo
  echo "pam_fprintd.so is also in $PAM_SHARED_AUTH_STACK, which other"
  echo "services @include. At the GDM greeter and at the lock screen"
  echo "gnome-shell runs two PAM conversations at once (gdm-password and"
  echo "gdm-fingerprint), so both stacks reach for the one sensor. Only one"
  echo "can claim it; the loser is told the reader is *unavailable*, which is"
  echo "exactly what makes GNOME drop fingerprint for the rest of the prompt."
  echo
  echo "gdm-password wins that race every time - it starts first, while the"
  echo "fingerprint service waits on a D-Bus round trip to fprintd. So the"
  echo "scan you actually get is the shared stack's single attempt on its own"
  echo "short timeout, never the $PAM_FPRINTD_ATTEMPTS attempts above."
  echo
  echo "Fingerprint has to live in exactly one of the two stacks, and it"
  echo "cannot be the shared one: that stack is serialised ahead of"
  echo "pam_unix.so, so extra waits there delay sudo's password prompt just"
  echo "as long."
  echo

  if pam_auth_update_owns_fprintd; then
    echo "This installer can disable the 'fprintd' pam-auth-update profile,"
    echo "which takes that line out the supported way - reversible with"
    echo "'sudo pam-auth-update --enable fprintd', and offered by uninstall.sh."
    echo
    if [ "${#conflict_losers[@]}" -gt 0 ]; then
      # The reassurance goes *before* the list on purpose. The list is long
      # and mostly made of services that never prompt for a finger anyway
      # (cron, cups, ppp), so leading with it makes the change look far
      # bigger than it is - which is how a machine ends up declining and then
      # still timing out at ten seconds. See JOURNAL.md, 2026-09-15.
      echo "Nothing stops working. Every service below still authenticates"
      echo "with the password it already accepts - they just stop offering"
      echo "the finger as a shortcut, and most of them never prompted for"
      echo "one in the first place. The one people actually notice is polkit"
      echo "(the \"Authentication required\" dialogs)."
      echo
      echo "Affected (${#conflict_losers[@]}):"
      for s in "${conflict_losers[@]}"; do
        echo "  $s"
      done
      echo
      echo "Not affected: sudo, which has its own pam_fprintd.so line; and"
      echo "GDM login plus the lock screen, which keep fingerprint through"
      echo "the hardened stack - gdm-password appearing above is the fix"
      echo "itself, not a loss."
      echo
    fi
    if confirm "Fix the lock screen? Fingerprint stops being offered in polkit prompts."; then
      FPRINTD_CONFLICT_FIX=true
    else
      echo "Left as it is. The extra tries above will not reach the reader at"
      echo "the lock screen while that line stays where it is."
    fi
  else
    # Not pam-auth-update's line, so this tool has no supported way to remove
    # it and will not hand-edit a login-critical file it did not write. Say so
    # plainly rather than hardening a stack that then silently does nothing.
    echo "That line is not one pam-auth-update manages here, so this installer"
    echo "will not touch it - editing $PAM_SHARED_AUTH_STACK by hand is not"
    echo "something it does. Remove the pam_fprintd.so auth line there"
    echo "yourself if you want the attempt stack above to take effect."
  fi
  echo
fi

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
  echo "     access. The rest of the run continues inside 'sg tss', which"
  echo "     picks the new group up without a logout."
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
if [ "$UNLIMIT_FPRINTD" = true ]; then
  echo "  $n. Rewrite the pam_fprintd.so auth line into $PAM_FPRINTD_ATTEMPTS attempts, each"
  echo "     keeping the module's own idle deadline (every file backed up"
  echo "     first, as <file>.bak-<timestamp>):"
  for t in "${fprintd_targets[@]}"; do
    echo
    echo "       $t"
    pam_fprintd_harden <"$t" | grep -E "$PAM_FPRINTD_AUTH_RE" \
      | sed 's/^/         /'
  done
  echo
  echo "     One line is one scan: whatever goes wrong - a mismatch, a bad"
  echo "     scan, a timeout - costs exactly one of the three attempts. The"
  echo "     jumps only skip the remaining attempts, so a match still falls"
  echo "     through to the keyring lines below. Three failures and the stack"
  echo "     fails, same as one failure does today."
  n=$((n + 1))
fi
if [ "$FPRINTD_CONFLICT_FIX" = true ]; then
  echo "  $n. Disable the 'fprintd' pam-auth-update profile, which removes the"
  echo "     pam_fprintd.so auth line from $PAM_SHARED_AUTH_STACK (every"
  echo "     common-* file backed up first, as <file>.bak-<timestamp>)."
  echo "     Without this the attempt stack never gets the sensor - see the"
  echo "     explanation printed above."
  n=$((n + 1))
fi
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
  echo "Added $USER to the 'tss' group."
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
    echo "Added you to the 'tss' group, but still can't read TPM PCRs in this" >&2
    echo "session, and couldn't borrow the group with 'sg' either. Log out and" >&2
    echo "back in (group membership only applies to new sessions), then re-run" >&2
    echo "this script - everything else it would have done is still pending." >&2
  elif [ "$TSS_GROUP_PRESENT" = true ]; then
    echo "Can't read TPM PCRs even though you're in the 'tss' group." >&2
    echo "Try logging out and back in (group membership needs a fresh" >&2
    echo "session), then re-run this script." >&2
  else
    echo "Can't read TPM PCRs, and there's no 'tss' group on this system to" >&2
    echo "add you to. Check how your distro grants /dev/tpmrm0 access." >&2
  fi
  exit 1
fi

if [ "$USE_SG" = true ]; then
  echo "Running the TPM steps inside 'sg tss' (no logout needed)."
  echo
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
tpm_run "$REPO_DIR/bin/seal.sh"

echo
if [ "$UNLIMIT_FPRINTD" = true ]; then
  echo "-- Fingerprint attempts + idle timeout --"
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
      echo "$TARGET is already in the target state - left unchanged."
      continue
    fi
    if ! pam_fprintd_stack_is_eligible "$TARGET"; then
      echo "$TARGET has changed since the plan above was printed and no" >&2
      echo "longer qualifies (it has to offer fingerprint and nothing else," >&2
      echo "on a single fall-through pam_fprintd.so line with no relative" >&2
      echo "jump above it). Left untouched - re-run this script to reconsider" >&2
      echo "it against the file as it stands now." >&2
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
    echo "Rewritten: $TARGET"
  done
  echo
fi

if [ "$FPRINTD_CONFLICT_FIX" = true ]; then
  disable_fprintd_profile
  echo
fi

echo "-- Login PAM stacks that feed the keyring --"
if [ "${#candidates[@]}" -eq 0 ]; then
  echo "No /etc/pam.d/ service has an auth-phase pam_gnome_keyring.so line."
  echo "Password logins are already fixed by the systemd mask above. Wire it"
  echo "in manually if you find the right file - see README.md 'How it works'."
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
      echo "$TARGET already had the module wired in - left unchanged."
      continue
    fi
    backup_pam_file "$TARGET"
    sudo sed -E -i "/${PAM_GNOME_KEYRING_AUTH_RE}/i auth    optional        pam_tpm_keyring_authtok.so" "$TARGET"
    echo "Wired: $TARGET"
  done
fi

echo
echo "Log out and back in (however you normally authenticate) to test."

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
  echo "=============================================================="
  echo "The fingerprint attempt stack is installed but CANNOT take effect."
  echo "=============================================================="
  echo
  echo "pam_fprintd.so is still in $PAM_SHARED_AUTH_STACK, so"
  echo "gdm-password still races gdm-fingerprint for the sensor at the lock"
  echo "screen - and still wins. What you will see is exactly the old"
  echo "behaviour: one prompt, a timeout message after about ten seconds,"
  echo "then password only. The three attempts never get the reader."
  echo
  if [ "$FPRINTD_CONFLICT_FIX" = true ]; then
    # Already attempted this run and the line is still there, so the step
    # above printed why. Repeating the offer would just repeat the failure.
    echo "The step earlier in this run tried to remove it and could not -"
    echo "see the message it printed above for what to do."
  elif pam_auth_update_owns_fprintd; then
    echo "It is one command, and it is reversible:"
    echo
    echo "    sudo pam-auth-update --disable fprintd"
    echo
    echo "Cost: services that reach fingerprint only through the shared stack"
    echo "- polkit prompts above all - fall back to the password they already"
    echo "accept. sudo keeps fingerprint; it has its own pam_fprintd.so line."
    echo "GDM login and the lock screen keep it through the stack just"
    echo "installed. Undo any time with 'sudo pam-auth-update --enable fprintd',"
    echo "and uninstall.sh offers to undo it too."
    echo
    if confirm "Fix the lock screen? Fingerprint stops being offered in polkit prompts."; then
      echo
      disable_fprintd_profile
      echo
      if pam_fprintd_in_shared_stack; then
        echo "Still there - see the message above. The lock screen will keep"
        echo "timing out after ten seconds until it is gone."
      else
        echo "Fixed. Lock the screen and try a deliberately bad scan: you"
        echo "should get another prompt rather than password-only."
      fi
    else
      echo "Left alone. The lock screen will keep dropping fingerprint after"
      echo "about ten seconds until that line is gone - run the command above"
      echo "whenever you want it fixed."
    fi
  else
    echo "That line is not one pam-auth-update manages here, so this installer"
    echo "will not touch it. Remove the auth-phase pam_fprintd.so line from"
    echo "$PAM_SHARED_AUTH_STACK yourself for the stack to take effect."
  fi

  # Re-checked, because the offer above may have just fixed it. Everything
  # else this installer does succeeded, but if the line is still there the
  # fingerprint stack it wrote provably cannot get the sensor - so say that
  # in the exit status too, not only in a paragraph somebody may scroll past.
  # "install.sh finished 0" must not mean "and the thing it installed does
  # nothing". Checked first that nothing keys off the status: no test, no
  # Makefile target and no CI job runs install.sh. See JOURNAL.md, 2026-09-15.
  if pam_fprintd_in_shared_stack; then
    echo
    echo "(exiting 2: everything else is installed and done; the fingerprint"
    echo "stack stays inert until that line is gone)"
    exit 2
  fi
fi

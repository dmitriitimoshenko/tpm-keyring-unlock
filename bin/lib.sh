#!/usr/bin/env bash
# Shared helpers sourced by install.sh, uninstall.sh, bin/seal.sh, and the
# test suite under test/. Not meant to be run directly - has no
# shebang-executable purpose of its own. Kept here rather than duplicated
# so install.sh/uninstall.sh/tests can't silently drift out of sync with
# each other on the logic that actually matters (which PAM lines get
# touched, which directory the module gets installed to).

# Candidate directories for the PAM modules directory (wherever pam_unix.so
# lives) across distros and architectures.
PAM_MODULE_DIR_CANDIDATES=(
  /lib/x86_64-linux-gnu/security
  /usr/lib/x86_64-linux-gnu/security
  /lib/aarch64-linux-gnu/security
  /usr/lib/aarch64-linux-gnu/security
  /lib/security
  /usr/lib64/security
  /usr/lib/security
)

# Prints the first candidate directory that actually contains pam_unix.so,
# and returns success. Prints nothing and returns failure if none match.
find_pam_module_dir() {
  local candidate
  for candidate in "${PAM_MODULE_DIR_CANDIDATES[@]}"; do
    if [ -d "$candidate" ] && [ -f "$candidate/pam_unix.so" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Matches an auth-phase line invoking pam_gnome_keyring.so, with either a
# plain single-token control field (optional, required, ...) or a bracketed
# control expression ([success=ok default=ignore]) - the latter contains
# spaces, which a plain \S+ stops at and fails to match.
PAM_GNOME_KEYRING_AUTH_RE='^\s*auth\s+(\S+|\[[^]]*\])\s+pam_gnome_keyring\.so'

# Exits with an explanatory message unless Secure Boot is verifiably on.
# This tool's entire security model rests on PCR7 (the Secure Boot state) -
# a seal made while Secure Boot is off is not a meaningful lock, so this
# check runs on both the install path and the standalone re-seal path
# (bin/seal.sh can be run on its own, without install.sh).
require_secure_boot() {
  if [ ! -d /sys/firmware/efi ]; then
    echo "This machine appears to have booted via legacy BIOS, not UEFI -" >&2
    echo "Secure Boot isn't available at all here, so PCR7 can't be a" >&2
    echo "meaningful lock. This tool needs UEFI with Secure Boot enabled." >&2
    exit 1
  fi

  local sb_var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  local state=""

  if command -v mokutil >/dev/null 2>&1; then
    local out
    out="$(mokutil --sb-state 2>/dev/null || true)"
    if echo "$out" | grep -qi "SecureBoot enabled"; then
      state=on
    elif echo "$out" | grep -qi "SecureBoot disabled"; then
      state=off
    fi
  fi

  if [ -z "$state" ] && [ -r "$sb_var" ]; then
    local byte
    byte="$(od -An -tu1 -j4 -N1 "$sb_var" 2>/dev/null | tr -d ' ')"
    case "$byte" in
      1) state=on ;;
      0) state=off ;;
    esac
  fi

  case "$state" in
    on) return 0 ;;
    off)
      echo "Secure Boot is disabled. This tool seals your password against" >&2
      echo "PCR7 (the Secure Boot state) - with it off, the seal isn't a" >&2
      echo "meaningful lock. Enable Secure Boot in firmware/BIOS setup, then" >&2
      echo "re-run." >&2
      exit 1
      ;;
    *)
      echo "Couldn't determine Secure Boot state (no mokutil, and $sb_var" >&2
      echo "isn't readable). Install mokutil, or check your firmware/BIOS" >&2
      echo "setup directly, and confirm Secure Boot is on before continuing" >&2
      echo "- this tool can't verify it for you on this machine." >&2
      exit 1
      ;;
  esac
}

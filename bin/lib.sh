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

# install.sh's own backups sit right next to the files they back up, so a
# /etc/pam.d/* glob picks them up like any other file. They are not services
# - PAM only ever reads the file whose name matches the service being
# authenticated - but they carry the same auth lines, so every detection loop
# here has to skip them. Without this, install.sh wires the module into its
# own backups and then backs *those* up on the next run
# (gdm-password.bak-1.bak-2), which is exactly how this was spotted. See
# JOURNAL.md, 2026-09-14.
PAM_BACKUP_RE='\.bak-[0-9]+$'

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

# Matches an auth-phase line invoking pam_fprintd.so, with the same two
# control-field syntaxes PAM_GNOME_KEYRING_AUTH_RE handles. Anchored to the
# auth phase on purpose: gdm-fingerprint also carries a *password*-phase
# pam_fprintd.so line (that one is fingerprint enrollment, not verification),
# and a verification timeout on it would mean nothing.
PAM_FPRINTD_AUTH_RE='^\s*auth\s+(\S+|\[[^]]*\])\s+pam_fprintd\.so'

# Auth-phase modules that can never, by themselves, let anyone in: pure
# gating/bookkeeping (nologin, succeed_if, faillock), secret-stashing that
# only ever runs behind a successful auth (gnome_keyring, kwallet, our own
# module), and fprintd itself. Used as a whitelist by
# pam_auth_is_fingerprint_only() - anything in an auth phase that is NOT on
# this list counts as another way into the account.
PAM_AUTH_PASSIVE_MODULE_RE='^pam_(fprintd|nologin|succeed_if|faillock|tally2?|deny|warn|cap|keyinit|env|localuser|debug|gnome_keyring|kwallet5?|tpm_keyring_authtok)\.so$'

# The only /etc/pam.d/ files that can be @include'd without dragging an
# auth-phase line in with them. Anything else included from an auth-carrying
# file is unknown territory, and pam_auth_is_fingerprint_only() refuses it
# rather than trying to follow the include.
PAM_AUTHLESS_INCLUDE_RE='^common-(account|session|session-noninteractive|password)$'

# Succeeds if $1 is a PAM service whose auth phase offers fingerprint and no
# other way in - i.e. a stack where making pam_fprintd wait forever cannot
# stall some other, non-fingerprint path to a login prompt.
#
# This distinction is the entire safety argument for the timeout=-1 edit.
# GDM runs gdm-fingerprint and gdm-password as two separate PAM conversations
# in parallel, so a fingerprint-only stack that waits indefinitely costs
# nothing: the password prompt is a different stack, still sitting right
# there. A *shared* stack is the exact opposite - Debian's common-auth puts
# pam_fprintd first and pam_unix immediately after it, and PAM is strictly
# serialised (see "LIMITATIONS" in pam_fprintd(8)), so an unlimited wait
# there would mean `sudo` blocks on the sensor forever and never reaches the
# password prompt at all. Hence a whitelist, and a refusal on anything not
# provably fingerprint-only.
pam_auth_is_fingerprint_only() {
  local f="$1" line module
  [ -f "$f" ] || return 1
  grep -qE "$PAM_FPRINTD_AUTH_RE" "$f" || return 1

  # `|| [ -n "$line" ]`: a file whose last line has no trailing newline
  # still gets that line checked. Missing it in a *safety* predicate would
  # mean overlooking a trailing pam_unix.so and calling a shared stack
  # fingerprint-only.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [[ "$line" =~ [^[:space:]] ]] || continue

    if [[ "$line" =~ ^[[:space:]]*@include[[:space:]]+([^[:space:]]+) ]]; then
      [[ "${BASH_REMATCH[1]}" =~ $PAM_AUTHLESS_INCLUDE_RE ]] || return 1
      continue
    fi

    # Two tokens after "auth": the control field (one word, or a bracketed
    # expression containing spaces) and the module. An `auth include
    # system-auth` / `auth substack ...` line lands here too, with
    # "system-auth" as the module - which is not on the passive whitelist, so
    # it gets refused, which is what we want for a stack we can't see into.
    if [[ "$line" =~ ^[[:space:]]*auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
      module="${BASH_REMATCH[2]}"
      [[ "$module" =~ $PAM_AUTH_PASSIVE_MODULE_RE ]] || return 1
    fi
  done <"$f"

  return 0
}

# Succeeds if the pam_fprintd.so installed on this machine actually
# understands the timeout= option (fprintd >= 1.94). Probes the module binary
# for the option string rather than asking a version: pam_fprintd has no
# --version, and distro version strings don't map cleanly onto when the
# option landed. An older module would simply log the argument as unknown and
# carry on, so a false negative here costs nothing but a skipped step.
pam_fprintd_supports_timeout_option() {
  local dir module
  dir="$(find_pam_module_dir || true)"
  [ -n "$dir" ] || return 1
  module="$dir/pam_fprintd.so"
  [ -f "$module" ] || return 1
  grep -qa 'timeout=' "$module"
}

# How many times the reader gets re-armed inside one PAM conversation before
# the stack gives up: the service's own pam_fprintd.so line plus
# PAM_FPRINTD_ATTEMPTS-1 lines prepended above it.
#
# Why this is needed at all, and why max-tries= is not enough: max-tries only
# counts *clean mismatches*. In pam_fprintd 1.94.5 the tries counter is
# decremented solely in the "verify-no-match" branch; "verify-unknown-error"
# and "verify-disconnected" - which is what a badly angled or partial scan
# turns into on some readers - jump straight to returning
# PAM_AUTHINFO_UNAVAIL, the same "there is no such auth method here" answer a
# timeout gives. GDM relays that as service-unavailable and gnome-shell then
# drops fingerprint for the rest of the prompt. So one bad scan ends the
# session's fingerprint option entirely, and no pam_fprintd option can change
# that. Verified in the disassembly; see JOURNAL.md, 2026-09-14.
#
# PAM has no loop construct, so the only fix at this level is to invoke the
# module again: each fresh pam_sm_authenticate() re-claims the device and
# re-arms it.
PAM_FPRINTD_ATTEMPTS=3

# Matches an attempt line generated by pam_fprintd_harden(). The
# "authinfo_unavail=ignore" control is the marker - deliberately a real part
# of the line's meaning rather than a trailing comment, so nothing here has to
# depend on whether libpam strips trailing comments.
PAM_FPRINTD_RETRY_LINE_RE='^\s*auth\s+\[[^]]*authinfo_unavail=ignore[^]]*\]\s+pam_fprintd\.so'

# Filters for stdin -> stdout.
#
#   pam_fprintd_harden    prepend the extra attempt lines, set timeout=-1 and
#                         max-tries=1 on every attempt
#   pam_fprintd_unharden  drop the attempt lines and both of those options
#
# The generated stack looks like:
#
#   auth  [success=2 <fallthrough>]  pam_fprintd.so max-tries=1 timeout=-1
#   auth  [success=1 <fallthrough>]  pam_fprintd.so max-tries=1 timeout=-1
#   auth  required                   pam_fprintd.so max-tries=1 timeout=-1
#
# where <fallthrough> is "authinfo_unavail=ignore auth_err=ignore
# maxtries=ignore default=die".
#
# One line = one scan = one attempt, whatever went wrong:
#
# - max-tries=1 moves the module's own retry counter out of the way. Left at
#   its default of 3, a mismatch would be retried *inside* one module call
#   while a bad scan consumed a whole stack line, so the two failure kinds
#   counted differently and a mixed run could cost up to nine finger
#   placements. With max-tries=1 the module returns after a single scan and
#   the stack does all the counting.
# - authinfo_unavail=ignore covers a bad scan or a timeout, auth_err=ignore a
#   mismatch or an unrecognised verify result, maxtries=ignore the single
#   no-match that max-tries=1 turns into PAM_MAXTRIES. All three fall through
#   to the next attempt.
# - default=die still stops immediately on anything genuinely broken (an
#   aborted conversation, a system error, no enrolled prints), which should
#   not be silently retried three times.
# - success=N is a *relative jump* over the remaining attempts, not "done", so
#   a match still falls through to the keyring lines below. Verified against
#   real libpam in test/runtime-test.sh - a jump that failed to record success
#   would break fingerprint login outright.
# - The service's own line stays as the last attempt with its original control
#   field, so the distro keeps the final verdict.
#
# Three attempts total is also what the module's own default allowed before
# any of this (max-tries=3), so the number of tries per prompt is unchanged -
# only which failures count toward it.
#
# Both directions are idempotent: harden drops any attempt lines it finds
# before generating fresh ones, so re-running cannot stack them up.
#
# unharden removes exactly the options harden sets (timeout=-1, max-tries=1).
# That restores the module defaults, which is the original state for the bare
# line gdm ships, but not for a stack that had its own explicit values -
# install.sh's .bak-<timestamp> copy is the exact-restore path for that case.
pam_fprintd_harden() {
  _pam_fprintd_rewrite_stack "$PAM_FPRINTD_ATTEMPTS"
}

pam_fprintd_unharden() {
  _pam_fprintd_rewrite_stack 1
}

# The awk patterns below are the POSIX-class equivalents of
# PAM_FPRINTD_AUTH_RE / PAM_FPRINTD_RETRY_LINE_RE above (awk has no \s) - keep
# them in sync with those.
_pam_fprintd_rewrite_stack() {
  awk -v attempts="$1" '
    function set_opt(code, name, value,   re) {
      re = name "=-?[0-9]+"
      if (code ~ re) {
        sub(re, name "=" value, code)
      } else {
        sub(/[[:space:]]+$/, "", code)
        code = code " " name "=" value
      }
      return code
    }

    function clear_opt(code, name, value,   re) {
      code = code " "
      re = "[[:space:]]+" name "=" value "[[:space:]]"
      sub(re, " ", code)
      sub(/[[:space:]]+$/, "", code)
      return code
    }

    BEGIN {
      auth_re  = "^[[:space:]]*auth[[:space:]]+(\\[[^]]*\\]|[^[:space:]]+)[[:space:]]+pam_fprintd\\.so"
      retry_re = "^[[:space:]]*auth[[:space:]]+\\[[^]]*authinfo_unavail=ignore[^]]*\\][[:space:]]+pam_fprintd\\.so"
      fallthrough = "authinfo_unavail=ignore auth_err=ignore maxtries=ignore default=die"
    }

    # previously generated attempt lines: drop, they are regenerated below
    $0 ~ retry_re { next }

    $0 ~ auth_re {
      code = $0; comment = ""
      h = index($0, "#")
      if (h > 0) { code = substr($0, 1, h - 1); comment = substr($0, h) }

      if (attempts > 1) {
        code = set_opt(code, "timeout", "-1")
        code = set_opt(code, "max-tries", "1")
      } else {
        code = clear_opt(code, "timeout", "-1")
        code = clear_opt(code, "max-tries", "1")
      }
      sub(/[[:space:]]+$/, "", code)

      # generated copies carry the same module + options, minus any comment
      if (!emitted) {
        tail = code
        sub(/^.*pam_fprintd\.so/, "", tail)
        for (i = attempts - 1; i >= 1; i--)
          printf "auth\t[success=%d %s]\tpam_fprintd.so%s\n", i, fallthrough, tail
        emitted = 1
      }

      print (comment == "" ? code : code " " comment)
      next
    }

    { print }
  '
}

# Succeeds if $1 has exactly one auth-phase pam_fprintd.so line that
# pam_fprintd_harden() did not generate itself - i.e. exactly one real line to
# build the attempt stack around. Anything stranger than that is left alone
# rather than guessed at.
pam_fprintd_has_single_auth_line() {
  local total generated
  total="$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$1" || true)"
  generated="$(grep -cE "$PAM_FPRINTD_RETRY_LINE_RE" "$1" || true)"
  [ "$total" = "$((generated + 1))" ]
}

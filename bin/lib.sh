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
#
# The leading '-' is the pam.conf(5) "don't log if this module is missing"
# prefix, written as part of the type field: '-auth optional
# pam_gnome_keyring.so'. Debian-family display-manager stacks use it
# routinely (Ubuntu/Mint ship it in /etc/pam.d/lightdm and lightdm-greeter),
# and without allowing it here those files silently fail detection - the
# installer then patches whatever *other* service happens to match (e.g.
# cinnamon-screensaver) and reports success while the actual login stack
# stays unwired. It stays optional in the pattern, not mandatory, because
# GDM-based stacks write the same line without it.
PAM_GNOME_KEYRING_AUTH_RE='^\s*-?auth\s+(\S+|\[[^]]*\])\s+pam_gnome_keyring\.so'

# /etc/pam.d/ holds more than services, and a /etc/pam.d/* glob picks all of
# it up like any other file: this tool's own .bak-<timestamp> copies sit right
# next to the files they back up, and the package managers leave .pacnew
# (Arch, routinely), .rpmnew/.rpmsave (Fedora, openSUSE) and
# .dpkg-old/.dpkg-dist/.ucf-old (Debian, Ubuntu) behind. None of them is a
# service - PAM only ever reads the file whose name matches the service being
# authenticated - but they all carry the same auth lines, so every detection
# loop here has to skip them. Without this, install.sh wires the module into
# its own backups and then backs *those* up on the next run
# (gdm-password.bak-1.bak-2), which is exactly how this was spotted. See
# JOURNAL.md, 2026-09-14 and 2026-09-15.
#
# Matched on "the basename contains a dot" rather than on a list of known
# suffixes: a real PAM service name has no dot in it - true for every service
# shipped by gdm, systemd, sudo, util-linux, shadow and the pam-configs
# machinery on all five distros the test suite covers - so this is both the
# simpler rule and the one that doesn't need extending for the next package
# manager's suffix. Anchored to the last path segment so the "pam.d" in the
# directory part can't match.
PAM_NON_SERVICE_RE='(^|/)[^/]*\.[^/]*$'

# Where libpam looks for a service file or an included one, in its own order:
# /etc/pam.d first, then /usr/lib/pam.d, where distributions ship defaults. A
# file in /etc/pam.d replaces the one of the same name below it outright - an
# override, not a merge. Ubuntu 26.04 ships polkit's service file only in
# /usr/lib/pam.d, so anything reading /etc/pam.d alone misses it, silently.
# See GitHub issue #19 and JOURNAL.md, 2026-09-25.
#
# Measured with pamtester in throwaway containers, not read off a manual:
# service files come from both directories on every libpam tried, and
# *includes* reach /usr/lib/pam.d on libpam 1.5.3 and later (Ubuntu 24.04 and
# 26.04, Fedora 44) but not on Debian 12's 1.5.2. Searching both is exact on
# the newer libpam and merely generous on the older one: a file it would not
# load gets inspected anyway.
#
# Colon-separated like PATH, so the tests can hand every predicate a fixture
# tree through the directory argument they already took - which is also why
# no directory on it can contain a colon. Not modelled: a libpam built with an
# extra vendor directory (openSUSE's /usr/etc/pam.d). A name that exists only
# there resolves to nothing here, and each caller says what it makes of that.
PAM_CONFIG_PATH="/etc/pam.d:/usr/lib/pam.d"

# Prints the file libpam would read for the service or include name $1: an
# absolute name as it stands, anything else from the first directory in $2
# (default PAM_CONFIG_PATH) that has it. Prints nothing and fails when none
# does.
pam_config_file() {
  local name="$1" path="${2:-$PAM_CONFIG_PATH}" dir dirs=()
  if [[ "$name" == /* ]]; then
    [ -e "$name" ] || return 1
    printf '%s\n' "$name"
    return 0
  fi
  IFS=: read -r -a dirs <<<"$path"
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done
  return 1
}

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
PAM_FPRINTD_AUTH_RE='^\s*-?auth\s+(\S+|\[[^]]*\])\s+pam_fprintd\.so'

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

# Prints $1 the way libpam reads it, one logical config line per output line.
# Every predicate below reads through this rather than the file directly.
#
# Without it a second auth-phase module split across two physical lines is
# invisible to them - `auth \` on one line has no module token to look at, and
# the `    required  pam_unix.so` that follows does not start with "auth", so
# both are skipped and a shared stack reads as fingerprint-only. Exactly the
# hole the leading-dash form had. See JOURNAL.md, 2026-09-15.
#
# libpam's rules, each one measured with pamtester (JOURNAL.md, 2026-09-26) -
# a predicate that reads a line differently from libpam can call a stack safe
# in which libpam runs a password module:
#
# - A comment starts at the first `#` on a physical line, and is cut *before*
#   continuations are looked at: a backslash inside a comment, or in front of
#   one, continues nothing.
# - A backslash that ends a line, trailing blanks allowed, joins the next line
#   and stands for a space.
# - Blank and comment-only lines are skipped. One *inside* a continuation is
#   where libpam versions part ways: 1.5 carries the continuation on past it,
#   1.7 ends the logical line there. This prints the 1.7 reading and returns
#   2, so a safety check can refuse such a file rather than bet on either.
# - The type (auth, -auth, @include) and a plain control word (required,
#   include, substack, ...) are case-insensitive, so they come out in lower
#   case. A bracketed control stays as written: its values are case-sensitive,
#   and [SUCCESS=DONE] is not [success=done] to libpam.
#
# Returns 1, having printed nothing, when the file cannot be read to the end,
# so a caller that captures the output can tell "no lines" from "could not
# read". Returns 2, having printed the 1.7 reading, when the file has a
# continuation whose meaning depends on the libpam version: one that runs into
# a blank or comment line, or into the end of the file. No distro ships
# either. One pass decides both, so the rules cannot drift apart between two
# readers (review of PR #20).
#
# NEVER put this on the left of a pipe feeding `grep -q` (or anything else
# that exits early): this is a shell function writing one line at a time, so
# when the reader leaves first the writer dies of SIGPIPE, the pipeline's
# status becomes 141, and `set -o pipefail` - which install.sh sets - turns
# that into a failed predicate. The failure is a race against how much the
# writer got through before the reader matched, so the same file gets
# different verdicts on different calls, and the printed plan stops matching
# what gets wired. Feed the reader with `< <(_pam_logical_lines "$f")`
# instead: the process substitution's exit status is nobody's business but
# its own. See JOURNAL.md, 2026-09-16, and mtriam/tpm-keyring-unlock#1.
_pam_logical_lines() {
  # LC_ALL=C for the case fold: in a Turkish locale bash folds `I` to a
  # dotless `ı`, and `INCLUDE` would no longer read as `include` - libpam's
  # strcasecmp runs in the C locale (review of PR #20).
  local LC_ALL=C
  local f="$1" content raw="" line acc="" cont=0 ambiguous=0
  # read in one go, so that a read error (EIO, a file that vanishes) is a
  # failure here rather than an early, silent end of the loop below
  content="$(cat -- "$f" 2>/dev/null)" || return 1
  # Globs and expansions rather than regexes on the common path: this runs on
  # every line of every file each predicate reads, and a regex apiece made the
  # pipefail stability checks alone take over a minute.
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[![:space:]]*}"}"
    if [ -z "$line" ] || [ "${line:0:1}" = "#" ]; then
      if [ "$cont" = 1 ]; then
        _pam_print_logical_line "$acc"
        acc="" cont=0 ambiguous=1
      fi
      continue
    fi
    case "$raw" in
      *"#"*)
        line="$acc${raw%%#*}"
        ;;
      *\\*)
        if [[ "$raw" =~ ^(.*)\\[[:space:]]*$ ]]; then
          acc="$acc${BASH_REMATCH[1]} "
          cont=1
          continue
        fi
        line="$acc$raw"
        ;;
      *)
        line="$acc$raw"
        ;;
    esac
    acc="" cont=0
    # the fold is only needed where there is upper case to fold
    case "$line" in
      *[[:upper:]]*) _pam_print_logical_line "$line" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<<"$content"
  if [ -n "$acc" ]; then
    _pam_print_logical_line "$acc"
    ambiguous=1
  fi
  [ "$ambiguous" = 0 ] || return 2
}

# Prints one logical line with its type and a plain control word folded to
# lower case - the parts libpam compares with strcasecmp. Nothing else is
# touched: file and module names are case-sensitive, and so are the values of
# a bracketed control.
_pam_print_logical_line() {
  local l="$1"
  # nothing to fold on a line with no upper case in it, which is nearly all
  case "$l" in
    *[[:upper:]]*) ;;
    *)
      printf '%s\n' "$l"
      return 0
      ;;
  esac
  if [[ "$l" =~ ^([[:space:]]*)(@[^[:space:]]*)(.*)$ ]]; then
    l="${BASH_REMATCH[1]}${BASH_REMATCH[2],,}${BASH_REMATCH[3]}"
  elif [[ "$l" =~ ^([[:space:]]*)([^[:space:]]+)([[:space:]]+)([^[:space:][]+)(.*)$ ]]; then
    l="${BASH_REMATCH[1]}${BASH_REMATCH[2],,}${BASH_REMATCH[3]}${BASH_REMATCH[4],,}${BASH_REMATCH[5]}"
  elif [[ "$l" =~ ^([[:space:]]*)([^[:space:]]+)(.*)$ ]]; then
    l="${BASH_REMATCH[1]}${BASH_REMATCH[2],,}${BASH_REMATCH[3]}"
  fi
  printf '%s\n' "$l"
}

# Succeeds if no line in $1 ends in a backslash continuation.
#
# The rewriter in _pam_fprintd_rewrite_stack() works on physical lines: it
# appends "timeout=-1 max-tries=1" to the end of the pam_fprintd.so line,
# which on a continued line lands *after* the trailing backslash - turning the
# continuation into a module argument and orphaning the line below it. The
# write-time invariant does not catch it either (the orphan is a non-fprintd
# line, identical on both sides). Rather than teach the awk to fold and unfold
# continuations, refuse the file: no distro ships one, and this is a login
# path. See JOURNAL.md, 2026-09-15.
pam_config_has_no_line_continuations() {
  local f="$1"
  [ -f "$f" ] || return 1
  ! grep -qE '\\$' "$f"
}

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
  local f="$1" line module lines
  [ -f "$f" ] || return 1
  grep -qE "$PAM_FPRINTD_AUTH_RE" "$f" || return 1
  # Captured rather than read through `< <(...)`, so that a read that fails
  # half-way is a refusal instead of a shorter file (review of PR #20).
  lines="$(_pam_logical_lines "$f")" || return 1

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
    #
    # `-?auth`: PAM also accepts a leading dash ("skip silently if the module
    # isn't installed"), used in the wild for pam_systemd_home.so and
    # pam_fscrypt.so. Those are real auth-phase modules, and missing them here
    # would mean calling a stack that has a second way in fingerprint-only -
    # exactly the misclassification this predicate exists to prevent. See
    # JOURNAL.md, 2026-09-15.
    if [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
      module="${BASH_REMATCH[2]}"
      [[ "$module" =~ $PAM_AUTH_PASSIVE_MODULE_RE ]] || return 1
    fi
  done <<<"$lines"

  return 0
}

# Succeeds if the pam_fprintd.so installed on this machine actually
# understands max-tries= (fprintd >= 1.94), the one option the attempt stack
# sets. Probes the module binary for the option string rather than asking a
# version: pam_fprintd has no --version, and distro version strings don't map
# cleanly onto when the option landed. An older module would simply log the
# argument as unknown and carry on, so a false negative here costs nothing but
# a skipped step.
#
# Probed on max-tries= rather than timeout= since 2026-09-15: the stack no
# longer writes timeout= at all, and a probe should test the thing actually
# being written. Both options landed together, so this changes nothing about
# which modules pass.
pam_fprintd_supports_attempt_options() {
  local dir module
  dir="$(find_pam_module_dir || true)"
  [ -n "$dir" ] || return 1
  module="$dir/pam_fprintd.so"
  [ -f "$module" ] || return 1
  grep -qa 'max-tries=' "$module"
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
# re-arms it. Verified directly rather than assumed - driving this exact stack
# through libpam from an unprivileged process (pam_start_confdir(3)) prompts
# for a finger three times and logs no claim conflict, and three claim/release
# cycles against fprintd from one process all succeed. An earlier reading of
# the login journal blamed "Device was already claimed" on these stacked
# invocations; that was wrong, and the measurement is what settled it. See
# JOURNAL.md, 2026-09-15.
PAM_FPRINTD_ATTEMPTS=3

# Matches an attempt line generated by pam_fprintd_harden(). The
# "authinfo_unavail=ignore" control is the marker - deliberately a real part
# of the line's meaning rather than a trailing comment, so nothing here has to
# depend on whether libpam strips trailing comments.
PAM_FPRINTD_RETRY_LINE_RE='^\s*-?auth\s+\[[^]]*authinfo_unavail=ignore[^]]*\]\s+pam_fprintd\.so'

# Filters for stdin -> stdout.
#
#   pam_fprintd_harden    prepend the extra attempt lines and set max-tries=1
#                         on every attempt
#   pam_fprintd_unharden  drop the attempt lines and the options harden sets
#
# The generated stack looks like:
#
#   auth  [success=2 <fallthrough>]  pam_fprintd.so max-tries=1
#   auth  [success=1 <fallthrough>]  pam_fprintd.so max-tries=1
#   auth  required                   pam_fprintd.so max-tries=1
#
# NO timeout= is set, and harden actively strips a timeout=-1 an older version
# of this tool left behind. timeout=-1 and the attempt stack are mutually
# exclusive by construction: an attempt only ends when the module returns, and
# with no deadline the *first* attempt never returns on its own - the stack can
# never reach attempts two and three, and the whole PAM conversation hangs
# instead of failing over to the password. Measured, not reasoned about: the
# real three-line stack with timeout=-1 prompts once and never returns, while
# the same stack with a finite timeout runs all three attempts and exits. The
# stack is also what timeout=-1 was originally for - N attempts at the module's
# own 30s deadline give N*30s at the sensor and still terminate. See
# JOURNAL.md, 2026-09-15.
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
# unharden removes exactly the options harden sets (max-tries=1), and the
# timeout=-1 older versions set.
# That restores the module defaults, which is the original state for the bare
# line gdm ships, but not for a stack that had its own explicit values. For
# those, uninstall.sh restores install.sh's .bak-<timestamp> copy instead -
# see pam_fprintd_exact_original() at the bottom of this file, which is what
# decides whether such a copy can be trusted.
pam_fprintd_harden() {
  _pam_fprintd_rewrite_stack "$PAM_FPRINTD_ATTEMPTS"
}

# The stack this tool wrote before timeout=-1 was dropped: identical except
# every attempt also carried timeout=-1. Never written any more - it exists so
# the recognisers below still identify a stack an older version installed, and
# so uninstall.sh can still take one apart. See JOURNAL.md, 2026-09-15.
pam_fprintd_harden_legacy() {
  _pam_fprintd_rewrite_stack "$PAM_FPRINTD_ATTEMPTS" legacy
}

pam_fprintd_unharden() {
  _pam_fprintd_rewrite_stack 1
}

# The awk patterns below are the POSIX-class equivalents of
# PAM_FPRINTD_AUTH_RE / PAM_FPRINTD_RETRY_LINE_RE above (awk has no \s) - keep
# them in sync with those.
_pam_fprintd_rewrite_stack() {
  awk -v attempts="$1" -v legacy="${2:-}" '
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
      auth_re  = "^[[:space:]]*-?auth[[:space:]]+(\\[[^]]*\\]|[^[:space:]]+)[[:space:]]+pam_fprintd\\.so"
      retry_re = "^[[:space:]]*-?auth[[:space:]]+\\[[^]]*authinfo_unavail=ignore[^]]*\\][[:space:]]+pam_fprintd\\.so"
      fallthrough = "authinfo_unavail=ignore auth_err=ignore maxtries=ignore default=die"
    }

    # previously generated attempt lines: drop, they are regenerated below
    $0 ~ retry_re { next }

    $0 ~ auth_re {
      code = $0; comment = ""
      h = index($0, "#")
      if (h > 0) { code = substr($0, 1, h - 1); comment = substr($0, h) }

      if (attempts > 1) {
        # timeout= is deliberately NOT set: see the header comment. legacy
        # reproduces the stack this tool wrote before that change, and is only
        # ever asked for by the recognisers below, never by harden.
        if (legacy != "") code = set_opt(code, "timeout", "-1")
        else              code = clear_opt(code, "timeout", "-1")
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
        # a leading "-" means "skip silently if the module is not installed";
        # the generated attempts have to carry that too, or a missing
        # pam_fprintd.so would start erroring where the original was quiet
        phase = (code ~ /^[[:space:]]*-/) ? "-auth" : "auth"
        for (i = attempts - 1; i >= 1; i--)
          printf "%s\t[success=%d %s]\tpam_fprintd.so%s\n", phase, i, fallthrough, tail
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

# Succeeds if the service's own pam_fprintd.so auth line - the one that isn't
# a generated attempt line - hands control on to the next module when the
# finger matches, rather than ending the stack there.
#
# The generated attempt lines use `success=N`, a *relative jump* that records
# success and carries on. That is the same thing the original line did only
# when the original was a fall-through control. Two shapes where it isn't:
#
#   auth sufficient pam_fprintd.so      <- success=done: return, stack over
#   auth required   pam_deny.so
#
# Rewritten, a match on attempt 1 jumps over attempts 2 and 3 and lands on
# pam_deny.so, so a *correct* finger now fails the login - and both modules
# are on PAM_AUTH_PASSIVE_MODULE_RE, so nothing else here would have caught
# it. A bracketed `success=<number>` is the other shape: its jump distance was
# measured from where that line sits, and there is no way to reproduce it on
# three lines in three different places.
#
# Refused rather than translated, on purpose: gdm-fingerprint (the service
# this feature exists for) ships `auth required`, so the shapes this turns
# away cost nothing, and guessing at someone else's control field on a login
# path is not worth the little it would buy. See JOURNAL.md, 2026-09-15.
pam_fprintd_control_falls_through() {
  local f="$1" line control inner found=false lines
  [ -f "$f" ] || return 1
  # Captured rather than read through `< <(...)`, so that a read that fails
  # half-way is a refusal instead of a shorter file (review of PR #20).
  lines="$(_pam_logical_lines "$f")" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+pam_fprintd\.so ]] || continue
    control="${BASH_REMATCH[1]}"
    # lines pam_fprintd_harden() generated are ours, and known to fall through
    if [[ "$control" =~ authinfo_unavail=ignore ]]; then continue; fi
    found=true
    case "$control" in
      required | requisite | optional) ;;
      \[*\])
        inner="${control:1:${#control}-2}"
        inner="${inner//$'\t'/ }"
        [[ " $inner " == *" success=ok "* ]] || return 1
        ;;
      *) return 1 ;;
    esac
  done <<<"$lines"
  [ "$found" = true ]
}

# Succeeds if no auth-phase line *above* the pam_fprintd.so line uses a
# numeric jump in its control field.
#
# A jump counts modules from where the line sits, so inserting the attempt
# lines above pam_fprintd.so silently re-aims every jump that was meant to
# land past it - `auth [success=1 default=ignore] pam_succeed_if.so user
# ingroup nopasswdlogin`, the standard "this group skips the reader" idiom,
# ends up landing on attempt 2 instead of past the reader entirely.
#
# install.sh's write invariant (every non-fprintd line byte-for-byte
# identical) reads like it rules this out and does not: a jump's meaning is
# positional, so identical bytes are not identical semantics. Lines *below*
# pam_fprintd.so are fine - nothing is inserted between them and whatever
# they aim at - which is why this stops at the fprintd line. See JOURNAL.md,
# 2026-09-15.
pam_auth_has_no_relative_jumps() {
  local f="$1" line control lines
  [ -f "$f" ] || return 1
  # Captured rather than read through `< <(...)`, so that a read that fails
  # half-way is a refusal instead of a shorter file (review of PR #20).
  lines="$(_pam_logical_lines "$f")" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    if [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+pam_fprintd\.so ]]; then
      return 0
    fi
    if [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+\[([^]]*)\] ]]; then
      control="${BASH_REMATCH[1]}"
      if [[ "$control" =~ =[0-9]+ ]]; then return 1; fi
    fi
  done <<<"$lines"
  return 0
}

# Succeeds if $1's fingerprint stack is one pam_fprintd_harden() wrote and
# nothing has edited since - proved by round trip: strip it back down, build
# it up again, and require the result to be the file byte for byte.
#
# This is what uninstall.sh keys off, and it has to be this strict. Keying off
# "unharden would change something" instead reaches far too wide: unharden
# strips max-tries=1, and Debian's own pam-auth-update writes exactly that
# into common-auth ("auth [success=3 default=ignore] pam_fprintd.so
# max-tries=1 timeout=10"), so uninstall.sh would offer to "restore" - and
# silently rewrite - a shared stack install.sh refuses to touch by design.
# The same wide net deletes a hand-written retry line that happens to carry
# authinfo_unavail=ignore, because unharden reads it as one of ours.
#
# The attempt count is read off the file rather than taken from
# PAM_FPRINTD_ATTEMPTS, so a stack written by a version of this tool with a
# different count still round-trips and can still be uninstalled.
# See JOURNAL.md, 2026-09-15.
pam_fprintd_stack_is_generated() {
  local f="$1" n
  [ -f "$f" ] || return 1
  grep -qE "$PAM_FPRINTD_RETRY_LINE_RE" "$f" || return 1
  n="$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$f" 2>/dev/null || true)"
  [ -n "$n" ] && [ "$n" -gt 1 ] || return 1
  pam_fprintd_unharden <"$f" | _pam_fprintd_rewrite_stack "$n" | cmp -s - "$f" && return 0
  # ... or the pre-timeout=-1-removal shape, so an older install is still
  # recognised as ours rather than reported as somebody's hand-rolled stack.
  pam_fprintd_unharden <"$f" | _pam_fprintd_rewrite_stack "$n" legacy | cmp -s - "$f"
}

# Prints the newest .bak-<timestamp> copy of $1 that is provably the file
# install.sh hardened into what's on disk now, if there is one. This is the
# only path that brings back an explicit timeout=/max-tries= the distro had
# set on its pam_fprintd.so line: pam_fprintd_unharden() removes exactly the
# options this tool adds, and has no way to know what was there before.
#
# "Provably" is two conditions. The backup holds a single, un-hardened
# pam_fprintd.so auth line - so it is a pre-edit original, not another
# hardened copy. And hardening it reproduces the current file byte for byte -
# which can only happen if every other line in the backup is already identical
# to what's on disk, so a stale backup (a gdm upgrade since, someone's own
# edit to an unrelated line) can never be restored over newer content. That is
# what makes copying the whole backup back safe, rather than having to splice
# single lines out of it.
#
# Newest first, because a re-run of install.sh on an already-hardened file
# takes no new backup: every copy that satisfies both conditions holds the
# same original line, and the newest is the one closest to the current file.
# See JOURNAL.md, 2026-09-15.
pam_fprintd_exact_original() {
  local f="$1" bak baks=()
  mapfile -t baks < <(printf '%s\n' "$f".bak-* | sort -r)
  for bak in "${baks[@]}"; do
    [ -f "$bak" ] || continue
    if [ "$(grep -cE "$PAM_FPRINTD_AUTH_RE" "$bak" 2>/dev/null || true)" != 1 ]; then continue; fi
    if grep -qE "$PAM_FPRINTD_RETRY_LINE_RE" "$bak"; then continue; fi
    if ! pam_fprintd_harden <"$bak" | cmp -s - "$f" \
       && ! pam_fprintd_harden_legacy <"$bak" | cmp -s - "$f"; then continue; fi
    echo "$bak"
    return 0
  done
  return 1
}

# Succeeds if $1 is a PAM service install.sh may rewrite into an attempt
# stack. The whole eligibility rule in one place, because it has to be applied
# twice: once when the plan is printed, and again immediately before the file
# is written.
#
# Those two moments are not the same moment. Between them install.sh installs
# packages, and on a Debian/Ubuntu machine that can regenerate files under
# /etc/pam.d on its own - pam-auth-update runs from libpam-runtime's postinst,
# a gdm upgrade ships its own gdm-fingerprint. The invariant install.sh checks
# before writing ("every non-fprintd line byte for byte identical, exactly N
# attempt lines") only proves the rewrite is faithful to whatever is on disk
# now; it says nothing about whether that content is still something this tool
# may touch. A file that was fingerprint-only at plan time and has since
# gained an `auth required pam_unix.so` passes every one of those checks -
# and writing it would put timeout=-1 into a shared, serialised stack, which
# is the one outcome all of this exists to prevent. See JOURNAL.md,
# 2026-09-15.
#
# Deliberately does NOT include "hardening would change something": that is a
# separate question (is a rewrite needed at all), answered separately at both
# call sites, so that "already in the target state" can be reported
# differently from "not eligible".
pam_fprintd_stack_is_eligible() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -qE "$PAM_FPRINTD_AUTH_RE" "$f" || return 1
  pam_config_has_no_line_continuations "$f" || return 1
  pam_fprintd_has_single_auth_line "$f" || return 1
  # Attempt lines that carry our marker but are not, byte for byte, a stack
  # this tool wrote are somebody else's hand-rolled retry stack:
  # pam_fprintd_has_single_auth_line() counts any authinfo_unavail=ignore line
  # as one of ours, which is right for our own output and wrong for a config
  # that predates the tool. uninstall.sh already refuses to claim those; the
  # install side has to agree, or it silently rewrites a stranger's fingerprint
  # config. See JOURNAL.md, 2026-09-15.
  if grep -qE "$PAM_FPRINTD_RETRY_LINE_RE" "$f"; then
    pam_fprintd_stack_is_generated "$f" || return 1
  fi
  pam_auth_is_fingerprint_only "$f" || return 1
  pam_fprintd_control_falls_through "$f" || return 1
  pam_auth_has_no_relative_jumps "$f" || return 1
  return 0
}

# --- the competing fingerprint stack ------------------------------------
#
# Hardening a fingerprint-only service only helps if that service is the one
# that actually gets the sensor. On a Debian-family desktop it usually is not.
#
# At the greeter and at the lock screen gnome-shell's ShellUserVerifier opens
# *two* PAM conversations at once - gdm-password and gdm-fingerprint - and
# once fingerprint is enabled in Settings, pam-auth-update has put
# pam_fprintd into common-auth, which gdm-password @include's. Both stacks
# therefore begin with pam_fprintd, only one of them can Claim() the reader,
# and the loser gets "Device was already claimed", which pam_fprintd turns
# into PAM_AUTHINFO_UNAVAIL - the same "no such auth method here" that makes
# gnome-shell drop fingerprint for the rest of the prompt.
#
# gdm-password wins that race, because gnome-shell starts the password service
# immediately and the fingerprint one only after a D-Bus round trip to fprintd
# asking whether any prints are enrolled. Measured, not reasoned about: two
# unprivileged pam_start_confdir(3) drivers running the two real stacks 0.2s
# apart give
#
#   common-auth first:  prompts once, times out at its own timeout=10  (10.71s)
#                       attempt stack returns AUTHINFO_UNAVAIL, no prompt (0.49s)
#   attempt stack first: three prompts, 30s each                       (90.92s)
#                       common-auth side returns immediately            (0.16s)
#
# See JOURNAL.md, 2026-09-15.
#
# So while pam_fprintd sits in the shared stack, the attempt stack is dead
# code. Fingerprint has to live in exactly one of the two, and the shared one
# is the one that has to go: it cannot be given extra attempts instead,
# because it is serialised ahead of pam_unix, so N waits on the sensor delay
# sudo's password prompt N times over. That is precisely why
# pam_fprintd_stack_is_eligible() refuses it, and that refusal stands.

# The pam-auth-update-managed shared auth stack. A variable so the tests can
# point the predicates below at a fixture instead of the real thing.
PAM_SHARED_AUTH_STACK="${PAM_SHARED_AUTH_STACK:-/etc/pam.d/common-auth}"

# Basename of the marker install.sh drops in $DATA_DIR when it disables the
# fprintd pam-auth-update profile. Shared so uninstall.sh looks for exactly
# the file install.sh writes; its presence is the *only* thing that lets
# uninstall.sh switch the profile back on, so that a machine where fingerprint
# was already disabled by hand is never silently re-enabled by this tool.
PAM_FPRINTD_PROFILE_MARKER="fprintd-pam-config-disabled"

# Succeeds if the shared auth stack carries an auth-phase pam_fprintd line -
# i.e. any service that @include's it will race the hardened stack for the
# reader, and win.
pam_fprintd_in_shared_stack() {
  local shared="${1:-$PAM_SHARED_AUTH_STACK}"
  [ -f "$shared" ] || return 1
  grep -qE "$PAM_FPRINTD_AUTH_RE" < <(_pam_logical_lines "$shared")
}

# Prints the file the logical line $1 includes into the auth phase - `@include
# X`, `auth include X` or `auth substack X`, spelled any way libpam accepts
# them: keywords in any case, a leading dash on auth, a comment or extra words
# after the name (measured with pamtester; JOURNAL.md, 2026-09-26) - and fails
# when the line includes nothing into the auth phase.
_pam_include_target() {
  # C locale for the case fold, as in _pam_logical_lines()
  local LC_ALL=C
  local t1="" t2="" t3=""
  read -r t1 t2 t3 _ <<<"${1%%#*}"
  if [ "${t1,,}" = "@include" ]; then
    [ -n "$t2" ] || return 1
    printf '%s\n' "$t2"
    return 0
  fi
  case "${t1,,}" in auth | -auth) ;; *) return 1 ;; esac
  case "${t2,,}" in include | substack) ;; *) return 1 ;; esac
  [ -n "$t3" ] || return 1
  printf '%s\n' "$t3"
}

# Walks the auth phase of $1 with every include followed (resolved on $3, the
# shared stack $2 itself not entered) and sets three flags, which the caller
# declares local:
#
#   _pam_fp_reaches  the shared stack is included somewhere on the way
#   _pam_fp_own      a pam_fprintd auth line outside the shared stack runs
#                    *before* it, so the service keeps fingerprint regardless.
#                    One below it does not count: pam-auth-update's
#                    common-auth ends in `requisite pam_deny.so`, so a wrong
#                    password stops the stack before such a line is reached
#                    (measured with pamtester; JOURNAL.md, 2026-09-26)
#   _pam_fp_auth     there is an auth-phase line at all; libpam gives a
#                    service with none the auth phase of "other" instead
#
# All three include forms count, transitively: on Ubuntu su-l reaches
# common-auth only through `auth include su`, and gdm's smartcard stacks
# through `auth substack common-auth`. Reading `@include common-auth` alone
# left five services out of the cost on this machine (review of PR #20).
#
# A file that cannot be read counts as reaching the shared stack with no line
# of its own. For a cost stated in a question that defaults to yes,
# overstating it is the safe mistake.
_pam_fprintd_walk() {
  local f="$1" shared="$2" path="$3" depth="${4:-0}"
  local line inc inc_file lines rc=0
  [ "$depth" -lt 8 ] || return 0
  # unreadable, or failing half-way through: counted as a loss, as promised.
  # The -f test comes first so that nothing ever reads from a FIFO or device.
  if [ -f "$f" ] && [ -r "$f" ]; then
    lines="$(_pam_logical_lines "$f")" || rc=$?
  else
    rc=1
  fi
  if [ "$rc" = 1 ]; then
    _pam_fp_reaches=1
    _pam_fp_auth=1
    return 0
  fi
  # _pam_logical_lines() hands over lines the way libpam reads them: comments
  # cut, type and control in lower case. Nothing to normalise here any more.
  while IFS= read -r line; do
    # Only a line that says "include" or "substack" can be an include, and
    # only those are worth the subshell _pam_include_target() costs. Asking it
    # about every line made the cost take 2.8 s to work out on a real
    # /etc/pam.d, twice per question.
    case "$line" in
      *include* | *substack*)
        if inc="$(_pam_include_target "$line")"; then
          inc_file="$(pam_config_file "$inc" "$path")" || continue
          if [ "$inc_file" = "$shared" ]; then
            _pam_fp_reaches=1
            _pam_fp_auth=1
          else
            _pam_fprintd_walk "$inc_file" "$shared" "$path" "$((depth + 1))"
          fi
          continue
        fi
        ;;
    esac
    [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]] ]] || continue
    _pam_fp_auth=1
    # the walk runs in libpam's order, so "reached yet" is simply the flag
    if [ "$_pam_fp_reaches" = 0 ] && [[ "$line" =~ $PAM_FPRINTD_AUTH_RE ]]; then
      _pam_fp_own=1
    fi
  done <<<"$lines"
  return 0
}

# Prints the files, across every directory in $3 (default PAM_CONFIG_PATH),
# for which _pam_fprintd_walk() answers what $1 asks:
#
#   loses  reaches the shared stack $2 and has no fingerprint line of its own
#   twice  reaches it *and* has one that runs before it - with fingerprint
#          back in the shared stack, such a service tries the reader twice
#          before the password
#
# Only files with an auth phase of their own are listed, and only the copy
# libpam actually reads: /usr/lib/pam.d/polkit-1 counts when /etc/pam.d has no
# polkit-1, and never when it does. Reading /etc/pam.d alone is how polkit
# went missing from the cost on Ubuntu 26.04 (GitHub issue #19).
_pam_fprintd_scan() {
  local mode="$1" shared="$2" path="$3"
  local dir f dirs=() _pam_fp_reaches _pam_fp_own _pam_fp_auth
  IFS=: read -r -a dirs <<<"$path"
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      if [ "$f" = "$shared" ]; then continue; fi
      if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi
      # shadowed by a copy of the same name earlier in the path: libpam never
      # reads this one, whatever it says
      [ "$(pam_config_file "${f##*/}" "$path")" = "$f" ] || continue
      _pam_fp_reaches=0 _pam_fp_own=0 _pam_fp_auth=0
      _pam_fprintd_walk "$f" "$shared" "$path"
      [ "$_pam_fp_auth" = 1 ] && [ "$_pam_fp_reaches" = 1 ] || continue
      case "$mode" in
        loses) [ "$_pam_fp_own" = 0 ] || continue ;;
        twice) [ "$_pam_fp_own" = 1 ] || continue ;;
      esac
      echo "$f"
    done
  done
  return 0
}

# Prints the services that would stop offering fingerprint if it were removed
# from the shared stack $1: the ones whose auth phase reaches it, with no
# pam_fprintd line of their own anywhere on the way. A service with its own
# line keeps fingerprint and is deliberately left out, so the cost quoted to
# the user is the real one rather than "everything that includes common-auth".
#
# Printed rather than summarised because the list is the whole point.
# pam_fprintd_shared_stack_prompts() below names the part of it people meet.
pam_fprintd_services_losing_fingerprint() {
  _pam_fprintd_scan loses "${1:-$PAM_SHARED_AUTH_STACK}" "${2:-$PAM_CONFIG_PATH}"
}

# Prints the services that reach the shared stack $1 *and* carry a pam_fprintd
# line of their own above it - what README's per-service recipe produces. With
# fingerprint back in the shared stack, they try the reader twice before the
# password; uninstall.sh says so before it re-enables the profile.
pam_fprintd_services_asking_twice() {
  _pam_fprintd_scan twice "${1:-$PAM_SHARED_AUTH_STACK}" "${2:-$PAM_CONFIG_PATH}"
}

# Succeeds if the service whose file is $1 loses fingerprint with the shared
# stack's line gone. A file with no auth-phase line at all - empty,
# session-only - is answered for "other", whose auth phase libpam uses for it.
_pam_fprintd_service_loses() {
  local f="$1" shared="$2" path="$3" other
  local _pam_fp_reaches=0 _pam_fp_own=0 _pam_fp_auth=0
  _pam_fprintd_walk "$f" "$shared" "$path"
  if [ "$_pam_fp_auth" = 0 ]; then
    other="$(pam_config_file other "$path")" || return 1
    [ "$other" != "$f" ] || return 1
    _pam_fprintd_walk "$other" "$shared" "$path"
  fi
  [ "$_pam_fp_reaches" = 1 ] && [ "$_pam_fp_own" = 0 ]
}

# Prints, as one phrase ("sudo and polkit"), the everyday prompts whose
# fingerprint comes from the shared stack on this machine: the part of the
# cost a person actually meets. Prints nothing when none of them depends on
# it.
#
# Worked out from the files, never assumed. Until GitHub issue #19 the
# installer said "sudo keeps it" unconditionally, which was true only where
# /etc/pam.d/sudo had been given its own pam_fprintd.so line by hand - the
# file Ubuntu ships has none. Disabling the fprintd profile there takes
# fingerprint from sudo as well as from polkit, and the question that
# disables it defaults to yes, so its text is where the cost has to be right.
#
# A prompt is named only when its service has a file, found the way libpam
# finds it - a missing file says nothing about whether the program is even
# installed, and its cost is carried by "other" in the full list. `sudo -i` is
# a service of its own on Debian-family systems (sudo-i, checked with sudo-rs),
# and is named only when plain sudo keeps fingerprint; otherwise "sudo" says
# it.
pam_fprintd_shared_stack_prompts() {
  local shared="${1:-$PAM_SHARED_AUTH_STACK}" path="${2:-$PAM_CONFIG_PATH}"
  local names=() svc cfg sudo_lost=false
  for svc in sudo sudo-i polkit-1; do
    cfg="$(pam_config_file "$svc" "$path")" || continue
    _pam_fprintd_service_loses "$cfg" "$shared" "$path" || continue
    case "$svc" in
      sudo) names+=(sudo); sudo_lost=true ;;
      sudo-i) [ "$sudo_lost" = true ] || names+=("sudo -i") ;;
      polkit-1) names+=(polkit) ;;
    esac
  done
  case "${#names[@]}" in
    0) ;;
    1) printf '%s\n' "${names[0]}" ;;
    *) printf '%s and %s\n' "${names[0]}" "${names[1]}" ;;
  esac
  return 0
}

# The question that leads to disabling the fprintd profile. It names the
# prompts in $1 (from pam_fprintd_shared_stack_prompts) when there are any,
# and otherwise the number of services in $2, whose list install.sh prints
# right above it. Every prompt there defaults to yes, so the cost has to be in
# the question itself - a bare "Fix the lock screen?" is what the review of
# PR #20 found the end-of-run check asking.
pam_fprintd_conflict_question() {
  local prompts="$1" count="${2:-0}"
  if [ -n "$prompts" ]; then
    printf 'Fix the lock screen? Fingerprint stops being offered in %s prompts.' "$prompts"
  elif [ "$count" -eq 1 ]; then
    printf 'Fix the lock screen? The service above falls back to the password.'
  elif [ "$count" -gt 1 ]; then
    printf 'Fix the lock screen? The %s services above fall back to the password.' "$count"
  else
    printf 'Fix the lock screen?'
  fi
}

# Succeeds if the pam_fprintd line in the shared stack is one pam-auth-update
# put there and can take back out again.
#
# This is the "is this actually yours to touch" check, and it gates the only
# mechanism this tool will use. The alternative - deleting the line from
# common-auth directly - is rejected on purpose: that file is generated, the
# next pam-auth-update run (any libpam-runtime upgrade) regenerates it from
# /var/lib/pam and the line comes straight back, silently, on a login path.
# Editing it by hand is also the exact bug this repo's own uninstall.sh had
# (see JOURNAL.md, the branch review). If this returns false, the conflict is
# reported and left alone rather than guessed at.
pam_auth_update_owns_fprintd() {
  local profile="${1:-/usr/share/pam-configs/fprintd}" state="${2:-/var/lib/pam/auth}"
  command -v pam-auth-update >/dev/null 2>&1 || return 1
  [ -f "$profile" ] || return 1
  [ -f "$state" ] || return 1
  grep -qE '^Module:[[:space:]]+fprintd[[:space:]]*$' "$state"
}

# Succeeds if $1 still looks like a shared auth stack that can log somebody in:
# no fingerprint line left, and at least one real primary auth module.
#
# Checked *after* pam-auth-update rewrites common-auth, because that write is
# the one step here that could lock the machine out. pam-auth-update
# regenerates the whole managed block and renumbers every success=N jump, so
# there is nothing to diff against; the post-condition is the only thing that
# can be asserted, and a file that fails it gets the backup put straight back.
pam_shared_stack_is_sane_without_fprintd() {
  local shared="${1:-$PAM_SHARED_AUTH_STACK}"
  [ -f "$shared" ] || return 1
  ! grep -qE "$PAM_FPRINTD_AUTH_RE" < <(_pam_logical_lines "$shared") || return 1
  grep -qE '^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+pam_(unix|sss|ldap|krb5|winbind|sssd)\.so' \
    < <(_pam_logical_lines "$shared")
}

# --- the machine-wide TPM primary handle ---------------------------------
#
# bin/seal.sh persists the TPM primary key at ONE fixed handle shared by
# every user of this tool on the machine. That is deliberate and correct -
# the primary is deterministic, so the second user to seal finds the first
# user's object, compares names, matches, and reuses it rather than burning
# a second persistent-object NV slot on a byte-identical key.
#
# The sharp edge is lifecycle: a persistent TPM object has no owner and no
# refcount, and there is no TPM API that answers "who is still using this?".
# So `uninstall.sh` evicting "its" handle is a machine-wide act that used to
# be taken on one user's say-so, breaking every other user's keyring unlock
# with no warning (GitHub issue #7, JOURNAL.md 2026-09-15). The only place
# the dependency is recorded at all is the filesystem: each user's own
# $DATA_DIR/primary.handle.

# TPM 2.0 persistent objects live in the 0x81000000-0x81ffffff range, and
# bin/seal.sh never records anything outside it. Used to reject a garbled or
# hostile primary.handle before its contents reach a tpm2_* tool, where -C
# would otherwise accept it as a *context-file path* rather than a handle.
# NOTE: pam/tpm-keyring-unseal.sh carries this same pattern inline. It has
# to: install.sh copies that script by itself to /usr/local/sbin, where this
# file isn't reachable. If you change the pattern, change it there too.
TPM_PERSISTENT_HANDLE_RE='^0x81[0-9a-fA-F]{6}$'

tpm_handle_is_wellformed() {
  [[ "$1" =~ $TPM_PERSISTENT_HANDLE_RE ]]
}

# Prints, one per line, the names of OTHER users who have recorded $1 as
# their persisted primary handle and still have a sealed blob next to it.
#
#   $1  the handle about to be evicted (e.g. 0x81018000)
#   $2  username to skip (the one running uninstall.sh)
#   $3  optional passwd-format file to read instead of `getent passwd` -
#       used ONLY by test/unit-regex-test.sh, so this predicate can be
#       driven against a fixture home tree with no TPM, no container and
#       no root. Never passed in production.
#
# Needs to run as root in production: the data dirs are 0700. A user whose
# home is unreadable, unmounted, or not enumerated (LDAP/SSSD with the
# default enumerate=false) simply does not appear here - this can produce a
# false "nobody depends on it", never a false positive, which is why the
# caller must still warn rather than treat an empty result as proof.
#
# Requires seal.priv beside the handle file on purpose: a leftover
# primary.handle with no blob next to it is not a live dependency.
tpm_primary_handle_dependents() {
  local handle="$1" skip_user="$2" passwd_file="${3:-}"
  local user home_dir data_dir recorded

  while IFS=: read -r user _ _ _ _ home_dir _; do
    [ -n "$user" ] || continue
    [ -n "$home_dir" ] || continue
    [ "$user" != "$skip_user" ] || continue
    data_dir="$home_dir/.local/share/tpm-keyring-unlock"
    [ -f "$data_dir/primary.handle" ] || continue
    [ -f "$data_dir/seal.priv" ] || continue
    recorded="$(tr -d '[:space:]' <"$data_dir/primary.handle" 2>/dev/null || true)"
    [ "$recorded" = "$handle" ] || continue
    printf '%s\n' "$user"
  done < <(if [ -n "$passwd_file" ]; then cat "$passwd_file"; else getent passwd; fi)

  # Explicit: finding nobody is a successful scan, not a failure. The caller
  # distinguishes "none found" from "couldn't check" by this exit status and
  # fails closed on the latter, so it must not be left to whatever the last
  # command in the loop body happened to return.
  return 0
}

# --- is our insertion point actually safe? --------------------------------
#
# install.sh inserts `auth optional pam_tpm_keyring_authtok.so` immediately
# above the auth-phase pam_gnome_keyring.so line. That module unseals the
# keyring password and calls pam_set_item(PAM_AUTHTOK) - unconditionally,
# before anyone has authenticated (a failed fingerprint already triggers it;
# see README's threat model section).
#
# The module itself can never grant a login: pam_sm_authenticate returns
# PAM_IGNORE on every path, success included, so it never votes. The hazard
# is a module BELOW it that authenticates using PAM_AUTHTOK instead of
# prompting - pam_unix.so with try_first_pass is the ordinary example. On
# such a stack our module hands it a valid password nobody typed, and since
# the keyring password is usually the login password (that is this tool's
# whole premise), that is a login and screen-unlock bypass.
#
# So the question is what runs BELOW the insertion point, not above it. That
# distinction matters and the first version of this check got it wrong: it
# asked whether something above already authenticated, which reads as the
# same thing and is not. On gdm-fingerprint nothing above is a password
# module - pam_fprintd only answers yes/no - yet nothing below it can consume
# PAM_AUTHTOK either, so it is perfectly safe, and refusing it would have
# disabled the single scenario this tool exists for. See JOURNAL.md,
# 2026-09-15.
#
# How that is decided, since 2026-09-26: a list of the harmless, not of the
# dangerous. Every auth-phase line that runs after our module - below the
# keyring line, in everything included from there, and after the include in
# every file that includes this one - has to read cleanly and name a module
# known to leave PAM_AUTHTOK alone. Anything else is a refusal: a module this
# tool has not vetted, a way of writing a line it does not model, an include
# it cannot find or read. Two reviews in a row found lines libpam runs and the
# old "known password modules" rule could not see - comments, case, absolute
# paths, bracketed tokens, `-@include`, a Turkish locale - and each one was a
# login bypass. Under this rule each is a stack left unwired, with the reason
# printed. The repo owner chose this knowing it refuses stacks that work
# today, such as one with pam_ecryptfs or pam_mount below the keyring line.
# See JOURNAL.md, 2026-09-26.

# Modules allowed to run after pam_tpm_keyring_authtok in the auth phase. Each
# one either never looks at PAM_AUTHTOK or only reads it to unlock something,
# and none can turn it into a successful authentication:
#
#   permit deny                   fixed answers (autologin stacks end in permit)
#   nologin succeed_if localuser  account attributes
#   shells
#   faildelay faillock            delays and failure counting
#   echo warn env keyinit cap     messages, logging, environment, credentials
#   group
#   fprintd                       yes or no from the finger
#   gnome_keyring kwallet         read the token to unlock a keyring or a
#   kwallet5                      wallet, which is what it is for
#   tpm_keyring_authtok           this tool's own module
#
# None of them imports pam_get_authtok; pam_unix does (checked with nm on
# Ubuntu 26.04). That test alone could not replace this list: pam_extrausers,
# pam_userdb and pam_exec take the token through the general pam_get_item. A
# module that belongs here is added once someone has read what it does with
# the token, never by default.
PAM_AFTER_TOKEN_MODULE_RE='^pam_(permit|deny|nologin|succeed_if|localuser|shells|faildelay|faillock|echo|warn|env|keyinit|cap|group|fprintd|gnome_keyring|kwallet|kwallet5|tpm_keyring_authtok)\.so$'

# Why the last pam_auth_insertion_point_is_safe() said no, in words install.sh
# prints next to the stack it did not wire.
PAM_INSERTION_REFUSAL=""

# Succeeds if every logical line in $1 may run after our module has set
# PAM_AUTHTOK. $2 is the search path includes are resolved against, $3 the
# include depth. Sets PAM_INSERTION_REFUSAL when it fails.
#
# The lines come from _pam_logical_lines(): comments cut, continuations
# joined, the type and a plain control in lower case. From there the grammar
# is strict on purpose. The type is one of the four phases (with or without
# libpam's leading dash) or `@include`. The control is one plain word, or one
# bracket expression that closes before a blank and holds no `[` or `\`. The
# module is a bare name. libpam accepts more than that - a bracketed type or
# module, `]` glued to the module, `\]` inside a bracket, `-@include` - and
# each of those let a password module through the old check. Here they are
# simply refused.
_pam_lines_are_harmless() {
  local lines="$1" path="$2" depth="$3" line type rest ctl mod inc
  while IFS= read -r line; do
    type="" rest=""
    read -r type rest <<<"$line"
    case "$type" in
      "") continue ;;
      account | -account | session | -session | password | -password) continue ;;
      @include)
        inc=""
        read -r inc _ <<<"$rest"
        _pam_include_is_harmless "$inc" "$path" "$depth" || return 1
        continue
        ;;
      auth | -auth) ;;
      *)
        PAM_INSERTION_REFUSAL="a line this tool does not read: $line"
        return 1
        ;;
    esac
    if [ "${rest:0:1}" = "[" ]; then
      ctl="${rest%%]*}]"
      rest="${rest#"$ctl"}"
      if [[ "$ctl" == *\\* || "${ctl:1}" == *"["* || ! "$rest" =~ ^[[:space:]] ]]; then
        PAM_INSERTION_REFUSAL="a control this tool does not read: $line"
        return 1
      fi
    else
      ctl=""
      read -r ctl rest <<<"$rest"
      case "$ctl" in
        include | substack)
          inc=""
          read -r inc _ <<<"$rest"
          _pam_include_is_harmless "$inc" "$path" "$depth" || return 1
          continue
          ;;
        required | requisite | sufficient | optional) ;;
        *)
          PAM_INSERTION_REFUSAL="a control this tool does not read: $line"
          return 1
          ;;
      esac
    fi
    mod=""
    read -r mod _ <<<"$rest"
    if [[ ! "$mod" =~ $PAM_AFTER_TOKEN_MODULE_RE ]]; then
      PAM_INSERTION_REFUSAL="${mod:-a line with no module} runs after the keyring line, and is not on the list of modules known to leave PAM_AUTHTOK alone"
      return 1
    fi
  done <<<"$lines"
  return 0
}

# Succeeds if the file included as $1 - found on $2 the way libpam finds it -
# may run in full after our module. An include that cannot be found or read
# is a refusal: libpam fails a service over a missing @include and a missing
# `auth include` at its own line (measured; JOURNAL.md, 2026-09-26), so a
# refusal costs at most a stack that works without the file.
_pam_include_is_harmless() {
  local name="$1" path="$2" depth="$3" inc_file
  if [ -z "$name" ]; then
    PAM_INSERTION_REFUSAL="an include that names no file"
    return 1
  fi
  if ! inc_file="$(pam_config_file "$name" "$path")"; then
    PAM_INSERTION_REFUSAL="it includes $name, which is in none of ${path//:/, }"
    return 1
  fi
  _pam_file_is_harmless "$inc_file" "$path" "$((depth + 1))"
}

# Succeeds if every line of the file $1 may run after our module.
_pam_file_is_harmless() {
  local f="$1" path="$2" depth="$3" lines rc=0
  # Include loops are legal to write, and libpam caps them; so does this.
  # Real stacks are one or two levels deep.
  if [ "$depth" -ge 8 ]; then
    PAM_INSERTION_REFUSAL="includes nest more than 8 deep at $f"
    return 1
  fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    PAM_INSERTION_REFUSAL="$f cannot be read"
    return 1
  fi
  lines="$(_pam_logical_lines "$f")" || rc=$?
  case "$rc" in
    0) ;;
    2)
      PAM_INSERTION_REFUSAL="$f continues a line past a comment or blank line, which libpam 1.5 and 1.7 read differently"
      return 1
      ;;
    *)
      PAM_INSERTION_REFUSAL="$f could not be read to the end"
      return 1
      ;;
  esac
  _pam_lines_are_harmless "$lines" "$path" "$depth"
}

# Prints the logical lines in $1 that follow its first auth-phase
# pam_gnome_keyring.so line, and fails if there is no such line.
_pam_lines_below_keyring() {
  local line seen=0
  while IFS= read -r line; do
    if [ "$seen" = 1 ]; then
      printf '%s\n' "$line"
      continue
    fi
    case "$line" in
      *pam_gnome_keyring*) [[ ! "$line" =~ $PAM_GNOME_KEYRING_AUTH_RE ]] || seen=1 ;;
    esac
  done <<<"$1"
  [ "$seen" = 1 ]
}

# Prints the logical lines in $1 that follow the first line naming the file
# $2 (resolved on $3). Returns 1 if no line names it, and 2 if the first one
# that does is not an include this tool reads - `-@include`, a bracketed
# token - since whatever follows it may then run after the file's lines
# without a check ever seeing it. A word "names" the file when it is the file's
# name, its absolute path, or either one in brackets.
_pam_lines_after_include_of() {
  local lines="$1" target="$2" path="$3" line inc type name="${2##*/}" seen=0
  while IFS= read -r line; do
    if [ "$seen" = 1 ]; then
      printf '%s\n' "$line"
      continue
    fi
    [[ " $line " == *[[:space:]/[]"$name"[][:space:]]* ]] || continue
    # the other phases never run our auth-phase line, whatever they include
    type=""
    read -r type _ <<<"$line"
    case "$type" in
      account | -account | session | -session | password | -password) continue ;;
    esac
    inc="$(_pam_include_target "$line")" || return 2
    [ "$(pam_config_file "$inc" "$path")" = "$target" ] || return 2
    seen=1
  done <<<"$lines"
  [ "$seen" = 1 ]
}

# Succeeds if no file that includes $1 runs anything after the include that
# our module's token could reach. libpam builds one stack out of a file and
# what it includes, so a `pam_unix.so try_first_pass` after `auth include
# gdm-password` in some other service would take the token as surely as one
# in gdm-password itself - and the old check only ever looked downwards
# (review of PR #20). Includers of includers are followed too.
#
# Every file on the search path counts, backups and all: a file with a dot in
# its name is no service, but libpam reads it when something includes it, so
# skipping it could skip a real link in the chain. That can refuse a stack
# over a stale copy that includes it, which no stock layout has.
_pam_includers_are_harmless() {
  local target="$1" path="$2" depth="${3:-0}" name dir f dirs=() lines rc below
  if [ "$depth" -ge 8 ]; then
    PAM_INSERTION_REFUSAL="files that include $target nest more than 8 deep"
    return 1
  fi
  name="${target##*/}"
  IFS=: read -r -a dirs <<<"$path"
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    # one grep per directory picks out the only files worth parsing: an
    # includer has to name the file it includes
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$f" != "$target" ] || continue
      [ "$(pam_config_file "${f##*/}" "$path")" = "$f" ] || continue
      rc=0
      lines="$(_pam_logical_lines "$f")" || rc=$?
      if [ "$rc" != 0 ]; then
        PAM_INSERTION_REFUSAL="${f##*/} names ${name}, and cannot be read cleanly to find out how"
        return 1
      fi
      rc=0
      below="$(_pam_lines_after_include_of "$lines" "$target" "$path")" || rc=$?
      [ "$rc" != 1 ] || continue
      if [ "$rc" = 2 ]; then
        PAM_INSERTION_REFUSAL="${f##*/} names ${name} in a line this tool does not read as an include"
        return 1
      fi
      if ! _pam_lines_are_harmless "$below" "$path" 0; then
        PAM_INSERTION_REFUSAL="${f##*/} includes ${name}, and after that: $PAM_INSERTION_REFUSAL"
        return 1
      fi
      _pam_includers_are_harmless "$f" "$path" "$((depth + 1))" || return 1
    done < <(grep -lF -- "$name" "$dir"/* 2>/dev/null)
  done
  return 0
}

# Succeeds if install.sh's writer and this check agree on where our line
# goes. The writer, `sed /PAM_GNOME_KEYRING_AUTH_RE/i`, inserts above every
# *physical* line that matches; this check looks below the first *logical*
# one. They are the same single line only if exactly one physical line
# matches, it carries no comment, and it is not part of a continuation.
# Otherwise our line could land above something no check looked at - `auth
# optional#x pam_gnome_keyring.so` above a pam_unix.so, say, which libpam
# ignores and sed does not (review of PR #20). $2 is the file's logical lines.
_pam_keyring_anchor_is_single() {
  local f="$1" lines="$2" n raw prev="" logical
  n="$(grep -cE "$PAM_GNOME_KEYRING_AUTH_RE" "$f" 2>/dev/null || true)"
  logical="$(grep -cE "$PAM_GNOME_KEYRING_AUTH_RE" <<<"$lines" || true)"
  if [ "$n" != 1 ] || [ "$logical" != 1 ]; then
    PAM_INSERTION_REFUSAL="it needs exactly one auth-phase pam_gnome_keyring.so line, and has ${n:-0}"
    return 1
  fi
  while IFS= read -r raw || [ -n "$raw" ]; do
    if [[ "$raw" =~ $PAM_GNOME_KEYRING_AUTH_RE ]]; then
      if [[ "$raw" == *"#"* || "$raw" =~ \\[[:space:]]*$ || "$prev" =~ \\[[:space:]]*$ ]]; then
        PAM_INSERTION_REFUSAL="its pam_gnome_keyring.so line carries a comment or sits in a continued line"
        return 1
      fi
      return 0
    fi
    prev="$raw"
  done <"$f"
  return 1
}

# Succeeds if it is safe to insert our module immediately above the
# auth-phase pam_gnome_keyring.so line in $1: nothing that runs after that
# point, in this file or in any file that includes it, could authenticate
# somebody with the PAM_AUTHTOK we are about to set. Sets
# PAM_INSERTION_REFUSAL to the reason when it says no.
#
# No keyring line means no insertion point, which is not the same as a safe
# one. The check does not reason about control flags or jumps: a module off
# the list below the keyring line is a refusal wherever the jumps would take
# the stack, because `optional` ordering is not worth splitting hairs over on
# a login path.
#
# A stack that already carries our line gets the same answer as without it:
# the line sits above the keyring line, where nothing is looked at.
# install.sh relies on that to re-check what it wired before.
#
# $2 is the search path includes are resolved against (PAM_CONFIG_PATH).
pam_auth_insertion_point_is_safe() {
  local f="$1" path="${2:-$PAM_CONFIG_PATH}" lines below rc=0
  PAM_INSERTION_REFUSAL=""
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    PAM_INSERTION_REFUSAL="it cannot be read"
    return 1
  fi
  lines="$(_pam_logical_lines "$f")" || rc=$?
  case "$rc" in
    0) ;;
    2)
      PAM_INSERTION_REFUSAL="it continues a line past a comment or blank line, which libpam 1.5 and 1.7 read differently"
      return 1
      ;;
    *)
      PAM_INSERTION_REFUSAL="it could not be read to the end"
      return 1
      ;;
  esac
  # Everything up to and including the keyring line runs before our module
  # does, so it cannot consume what we have not set yet.
  if ! below="$(_pam_lines_below_keyring "$lines")"; then
    PAM_INSERTION_REFUSAL="it has no auth-phase pam_gnome_keyring.so line"
    return 1
  fi
  _pam_keyring_anchor_is_single "$f" "$lines" || return 1
  _pam_lines_are_harmless "$below" "$path" 0 || return 1
  _pam_includers_are_harmless "$f" "$path" 0
}

# The sed expression that takes this tool's line back out of a PAM file.
# Shared so that install.sh (un-wiring a stack that no longer passes the
# check) and uninstall.sh remove exactly the same lines.
PAM_TPM_LINE_DELETE_SED='/pam_tpm_keyring_authtok\.so/d'

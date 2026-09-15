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

# Prints $1 with PAM's backslash line continuations joined, so every output
# line is one logical config line. Every predicate below reads through this
# rather than the file directly.
#
# Without it a second auth-phase module split across two physical lines is
# invisible to them - `auth \` on one line has no module token to look at, and
# the `    required  pam_unix.so` that follows does not start with "auth", so
# both are skipped and a shared stack reads as fingerprint-only. Exactly the
# hole the leading-dash form had. See JOURNAL.md, 2026-09-15.
#
# The trailing backslash is dropped and the next physical line appended as-is,
# which is what libpam's own parser does.
_pam_logical_lines() {
  local f="$1" line acc=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^(.*)\\$ ]]; then
      acc="$acc${BASH_REMATCH[1]}"
      continue
    fi
    printf '%s%s\n' "$acc" "$line"
    acc=""
  done <"$f"
  [ -z "$acc" ] || printf '%s\n' "$acc"
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
  done < <(_pam_logical_lines "$f")

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
  local f="$1" line control inner found=false
  [ -f "$f" ] || return 1
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
  done < <(_pam_logical_lines "$f")
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
  local f="$1" line control
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    if [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+pam_fprintd\.so ]]; then
      return 0
    fi
    if [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+\[([^]]*)\] ]]; then
      control="${BASH_REMATCH[1]}"
      if [[ "$control" =~ =[0-9]+ ]]; then return 1; fi
    fi
  done < <(_pam_logical_lines "$f")
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
  _pam_logical_lines "$shared" | grep -qE "$PAM_FPRINTD_AUTH_RE"
}

# Prints the /etc/pam.d/ services that @include $1 and have no pam_fprintd
# auth line of their own - i.e. exactly the services that would stop offering
# fingerprint if it were removed from the shared stack. A service with its own
# explicit line (Ubuntu ships one in /etc/pam.d/sudo) keeps fingerprint and is
# deliberately left out, so the cost quoted to the user is the real one rather
# than "everything that includes common-auth".
#
# Printed rather than summarised because the list is the whole point: on a
# machine with no /etc/pam.d/polkit-1 the entry that matters is "other", and
# no generic wording would tell anyone that polkit dialogs are what changes.
pam_fprintd_services_losing_fingerprint() {
  local shared="${1:-$PAM_SHARED_AUTH_STACK}" dir="${2:-/etc/pam.d}"
  local base f
  base="$(basename "$shared")"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    if [ "$f" = "$shared" ]; then continue; fi
    if [[ "$f" =~ $PAM_NON_SERVICE_RE ]]; then continue; fi
    if ! _pam_logical_lines "$f" | grep -qE "^[[:space:]]*@include[[:space:]]+${base}[[:space:]]*$"; then
      continue
    fi
    if _pam_logical_lines "$f" | grep -qE "$PAM_FPRINTD_AUTH_RE"; then continue; fi
    echo "$f"
  done
  return 0
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
  ! _pam_logical_lines "$shared" | grep -qE "$PAM_FPRINTD_AUTH_RE" || return 1
  _pam_logical_lines "$shared" \
    | grep -qE '^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+pam_(unix|sss|ldap|krb5|winbind|sssd)\.so'
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
# Modules that can authenticate with a password, and so could consume a
# PAM_AUTHTOK they did not prompt for. Same list as
# pam_shared_stack_is_sane_without_fprintd deliberately: one notion of "this
# module can log somebody in" for the whole tool. pam_gnome_keyring is not in
# it - it is the intended consumer of PAM_AUTHTOK and unlocks a keyring
# rather than granting a session.
PAM_PRIMARY_AUTH_RE='^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+pam_(unix|sss|sssd|ldap|krb5|winbind)\.so'

# Succeeds if the auth phase of $1 contains a primary auth module anywhere,
# following @include / `auth include` / `auth substack`.
#
# Used to look inside an include that sits below the insertion point: a stack
# whose keyring line comes before `@include common-auth` puts the whole of
# common-auth - pam_unix.so with try_first_pass and all - underneath our
# module.
_pam_stack_authenticates() {
  local f="$1" dir="${2:-/etc/pam.d}" depth="${3:-0}"
  local line inc
  [ -f "$f" ] || return 1
  # Include loops are legal to write and would otherwise hang an installer on
  # a login path; libpam caps recursion, so cap it here too. Hitting the cap
  # reports "yes, this authenticates" on purpose - the honest answer is "could
  # not tell", and the only caller treats that as a reason to refuse. Failing
  # open here would mean an include chain we gave up on reads as safe. Real
  # stacks are one or two levels deep, so nothing legitimate reaches this.
  [ "$depth" -lt 8 ] || return 0
  while IFS= read -r line; do
    [[ ! "$line" =~ $PAM_PRIMARY_AUTH_RE ]] || return 0
    if [[ "$line" =~ ^[[:space:]]*@include[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
      inc="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+(include|substack)[[:space:]]+([^[:space:]]+) ]]; then
      inc="${BASH_REMATCH[2]}"
    else
      continue
    fi
    ! _pam_stack_authenticates "$dir/$inc" "$dir" "$((depth + 1))" || return 0
  done < <(_pam_logical_lines "$f")
  return 1
}

# Succeeds if it is safe to insert our module immediately above the
# auth-phase pam_gnome_keyring.so line in $1 - i.e. nothing below that point
# could authenticate somebody using the PAM_AUTHTOK we are about to set.
#
# Returns failure when there is no pam_gnome_keyring auth line at all: no
# insertion point is not a safe insertion point, and a predicate that answers
# "safe" to a question nobody asked gets reused somewhere it shouldn't be.
#
# What this proves and what it does not: it proves no password module runs
# after ours in this service's auth phase. It is not a complete model of
# libpam - it does not reason about control flags or jumps, and it treats any
# primary auth module below as disqualifying whether or not it actually
# carries try_first_pass, because `optional` ordering is not worth splitting
# hairs over on a login path.
pam_auth_insertion_point_is_safe() {
  local f="$1" dir="${2:-/etc/pam.d}"
  local line inc seen_keyring=0
  [ -f "$f" ] || return 1
  _pam_logical_lines "$f" | grep -qE "$PAM_GNOME_KEYRING_AUTH_RE" || return 1
  while IFS= read -r line; do
    if [ "$seen_keyring" -eq 0 ]; then
      # Everything up to and including the keyring line runs before our
      # module does, so it cannot consume what we have not set yet.
      [[ ! "$line" =~ $PAM_GNOME_KEYRING_AUTH_RE ]] || seen_keyring=1
      continue
    fi
    [[ ! "$line" =~ $PAM_PRIMARY_AUTH_RE ]] || return 1
    if [[ "$line" =~ ^[[:space:]]*@include[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
      inc="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*-?auth[[:space:]]+(include|substack)[[:space:]]+([^[:space:]]+) ]]; then
      inc="${BASH_REMATCH[2]}"
    else
      continue
    fi
    ! _pam_stack_authenticates "$dir/$inc" "$dir" 1 || return 1
  done < <(_pam_logical_lines "$f")
  return 0
}

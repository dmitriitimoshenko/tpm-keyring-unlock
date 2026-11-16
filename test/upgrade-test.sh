#!/usr/bin/env bash
# Tests the part of `install.sh --upgrade` that moves a git checkout to the
# newest release (bin/lib.sh: upgrade_checkout_is_git, version_is_newer,
# latest_release_tag, upgrade_checkout_movable, upgrade_checkout_move).
# No network, no root: a bare repository under a temp directory plays the
# GitHub remote, with release tags pushed to it after the clone, the way a new
# release reaches a user's checkout. The rest of an upgrade - every install
# step again, keeping a sealed secret that still unseals - needs a TPM, and
# test/vm/run-vm-test.sh runs it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bin/lib.sh
source "$REPO_DIR/bin/lib.sh"

T="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT

# Nothing from this account's git setup - hooks, signing, a default branch
# name - may change what the test sees.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (got: $got, want: $want)"
    fail=1
  fi
}

# --- version_is_newer ----------------------------------------------------------
vn() { if version_is_newer "$1" "$2"; then echo newer; else echo not; fi; }
check "1.10.0 is newer than 1.9.0 (numbers, not text)" "$(vn 1.10.0 1.9.0)" newer
check "1.7.0 is newer than 1.6.0" "$(vn 1.7.0 1.6.0)" newer
check "2.0.0 is newer than 1.99.99" "$(vn 2.0.0 1.99.99)" newer
check "1.6.0 is not newer than itself" "$(vn 1.6.0 1.6.0)" not
check "1.6.0 is not newer than 1.10.0" "$(vn 1.6.0 1.10.0)" not
check "anything is newer than no version at all" "$(vn 1.6.0 '')" newer

# --- a remote, a user's clone, then a release ------------------------------------
g() { git -C "$@"; }
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/upstream"
echo 1.0.0 >"$T/upstream/VERSION"
g "$T/upstream" add VERSION
g "$T/upstream" commit -q -m "release: 1.0.0"
g "$T/upstream" tag v1.0.0
g "$T/upstream" remote add origin "$T/origin.git"
g "$T/upstream" push -q origin main --tags
git clone -q "$T/origin.git" "$T/work"

# The release after the clone, plus tags that are not releases.
echo 1.1.0 >"$T/upstream/VERSION"
g "$T/upstream" commit -q -am "feat: blink the power button"
g "$T/upstream" tag v1.1.0
echo 1.2.0 >"$T/upstream/VERSION"
g "$T/upstream" commit -q -am "wip"
g "$T/upstream" tag v1.2.0-rc1
g "$T/upstream" tag nightly
g "$T/upstream" push -q origin main --tags

if upgrade_checkout_is_git "$T/work"; then got=yes; else got=no; fi
check "a clone is a checkout of its own" "$got" yes
mkdir -p "$T/work/sub" "$T/plain"
if upgrade_checkout_is_git "$T/work/sub"; then got=yes; else got=no; fi
check "a directory inside one is not (a copy inside another repository)" "$got" no
if upgrade_checkout_is_git "$T/plain"; then got=yes; else got=no; fi
check "a plain directory is not (a package's libexec)" "$got" no

check "before fetching, the newest release known is the clone's" "$(latest_release_tag "$T/work")" v1.0.0
g "$T/work" fetch -q --tags origin
check "after fetching: the newest vX.Y.Z, not the rc or another tag" "$(latest_release_tag "$T/work")" v1.1.0

# A release-looking tag on a commit that is not on main is no release.
g "$T/upstream" switch -q -c side
echo 9.0.0 >"$T/upstream/VERSION"
g "$T/upstream" commit -q -am "not a release"
g "$T/upstream" tag v9.0.0
g "$T/upstream" switch -q main
g "$T/upstream" push -q origin v9.0.0
g "$T/work" fetch -q --tags origin
check "a vX.Y.Z tag off main (v9.0.0 on a side commit) is no release" "$(latest_release_tag "$T/work")" v1.1.0

mv_rc() { local rc=0; upgrade_checkout_movable "$T/work" "$1" "$2" || rc=$?; echo "$rc"; }
check "on main at 1.0.0: can move to v1.1.0" "$(mv_rc 1.0.0 v1.1.0)" 0
check "no release tag at all: nothing to move to" "$(mv_rc 1.0.0 '')" 1
check "a release that is not newer: nothing to do" "$(mv_rc 1.1.0 v1.1.0)" 1

# Untracked files - build output, a scratch note - are no reason to stay.
touch "$T/work/untracked-note"
check "untracked files do not block it" "$(mv_rc 1.0.0 v1.1.0)" 0
echo local >>"$T/work/VERSION"
check "a local change to a tracked file blocks it" "$(mv_rc 1.0.0 v1.1.0)" 3
g "$T/work" checkout -q -- VERSION

upgrade_checkout_move "$T/work" v1.1.0
check "moved: the files are the release's" "$(cat "$T/work/VERSION")" 1.1.0
check "moved: still on main, fast-forwarded" "$(g "$T/work" symbolic-ref --short HEAD)" main
check "moved: main is at the release commit" "$(g "$T/work" rev-parse HEAD)" "$(g "$T/work" rev-parse 'v1.1.0^{commit}')"
check "moved: the untracked file is still there" "$([ -e "$T/work/untracked-note" ] && echo kept || echo lost)" kept
check "after moving, nothing newer to move to" "$(mv_rc 1.1.0 v1.1.0)" 1

# A branch with commits of its own cannot be fast-forwarded; it is not reset.
g "$T/work" reset -q --hard v1.0.0
echo mine >"$T/work/mine"
g "$T/work" add mine
g "$T/work" commit -q -m "my own change"
mine="$(g "$T/work" rev-parse HEAD)"
check "a branch with its own commits: not moved" "$(mv_rc 1.0.0 v1.1.0)" 4
check "and left exactly where it was" "$(g "$T/work" rev-parse HEAD)" "$mine"

# Commits made on no branch would be left to the reflog: not moved either.
g "$T/work" -c advice.detachedHead=false checkout -q v1.0.0
echo detached >"$T/work/detached-work"
g "$T/work" add detached-work
g "$T/work" commit -q -m "work on a detached HEAD"
check "detached, with commits of its own: not moved" "$(mv_rc 1.0.0 v1.1.0)" 4

# A checkout at an older tag, on no branch, moves to the new tag.
g "$T/work" -c advice.detachedHead=false checkout -q v1.0.0
check "detached at v1.0.0: can move" "$(mv_rc 1.0.0 v1.1.0)" 0
upgrade_checkout_move "$T/work" v1.1.0
check "detached: now at v1.1.0" "$(g "$T/work" describe --tags --exact-match HEAD)" v1.1.0
check "detached: the files are the release's" "$(cat "$T/work/VERSION")" 1.1.0

# A developer's checkout ahead of the release (main after it) is left alone.
g "$T/work" checkout -q main
g "$T/work" reset -q --hard origin/main
check "a checkout already past the release: nothing to do" "$(mv_rc 1.2.0 v1.1.0)" 1

# --- upgrade_checkout(), the whole first step of install.sh --upgrade ---------
# Run for real, in a subshell each time, since on a switch it execs the new
# installer and does not come back. The releases carry a stand-in install.sh
# that only says how it was started. confirm() answers as $ANSWER says.
cat >"$T/upstream/install.sh" <<'STUB'
#!/usr/bin/env bash
echo "new installer: args=[$*] reexec=${TPM_KEYRING_UPGRADE_REEXEC:-} version=$(cat "$(dirname "$0")/VERSION")"
STUB
chmod +x "$T/upstream/install.sh"
echo 1.3.0 >"$T/upstream/VERSION"
g "$T/upstream" add install.sh VERSION
g "$T/upstream" commit -q -m "feat: an upgrade path"
g "$T/upstream" tag v1.3.0
g "$T/upstream" push -q origin main --tags

confirm() { echo "asked: $1" >&2; [ "${ANSWER:-y}" = y ]; }
# run_upgrade DIR VERSION ANSWER [DO_BUILD]: upgrade_checkout's output and
# stderr, both.
run_upgrade() {
  ( REPO_DIR="$1" TOOL_VERSION="$2" ANSWER="$3" DO_BUILD="${4:-true}"
    ORIG_ARGS=(--upgrade --no-build-not-really)
    upgrade_checkout ) 2>&1
}
g "$T/work" reset -q --hard v1.0.0
out="$(run_upgrade "$T/work" 1.0.0 n)"
check "declined: says it carries on with what it has" "$(grep -c 'Carrying on with 1.0.0' <<<"$out")" 1
check "declined: lists what the release brings first" "$(grep -c '  feat: an upgrade path' <<<"$out")" 1
check "declined: asks before switching" "$(grep -c "asked: Switch $T/work to v1.3.0" <<<"$out")" 1
check "declined: the checkout has not moved" "$(cat "$T/work/VERSION")" 1.0.0
out="$(run_upgrade "$T/work" 1.0.0 y)"
check "accepted: starts over with the new installer, same options, marked" \
  "$(tail -n1 <<<"$out")" "new installer: args=[--upgrade --no-build-not-really] reexec=1 version=1.3.0"
check "accepted: the checkout is at the release, still on main" \
  "$(cat "$T/work/VERSION"):$(g "$T/work" symbolic-ref --short HEAD)" "1.3.0:main"
out="$(run_upgrade "$T/work" 1.3.0 y)"
check "at the newest release: says so, asks nothing" \
  "$(grep -c 'Already at the newest release (1.3.0)' <<<"$out"):$(grep -c 'asked:' <<<"$out")" "1:0"
g "$T/work" reset -q --hard v1.0.0
echo local >>"$T/work/VERSION"
out="$(run_upgrade "$T/work" 1.0.0 y)"
check "local changes: not switched, and says why" \
  "$(grep -c 'has local changes - not switching' <<<"$out"):$(grep -c 'new installer' <<<"$out")" "1:0"
g "$T/work" checkout -q -- VERSION
out="$(run_upgrade "$T/plain" 1.0.0 y)"
check "not a git checkout: carries on with these files" "$(grep -c 'is not a git checkout' <<<"$out")" 1
out="$(run_upgrade "$T/work" 1.0.0 y false)"
check "packaged (--no-build): leaves the files to the package manager" \
  "$(grep -c 'Packaged install' <<<"$out"):$(cat "$T/work/VERSION")" "1:1.0.0"
g "$T/work" remote set-url origin "$T/nowhere.git"
out="$(run_upgrade "$T/work" 1.0.0 y)"
check "origin unreachable: carries on, says so" \
  "$(grep -c 'Could not fetch from origin' <<<"$out"):$(cat "$T/work/VERSION")" "1:1.0.0"

check "install.sh --help documents --upgrade" "$("$REPO_DIR/install.sh" --help | grep -c -- '--upgrade')" 2

# No main line to tell releases by: nothing counts as one.
git clone -q "$T/origin.git" "$T/nomain"
g "$T/nomain" remote set-head origin -d
g "$T/nomain" update-ref -d refs/remotes/origin/main
check "no origin/main or origin/HEAD: no release known" "$(latest_release_tag "$T/nomain")" ""

# install.sh refuses an upgrade with nothing installed before it touches the
# checkout: run in a pty (it insists on one), with a HOME that has no sealed
# secret. It must stop before its first step, which would fetch.
if command -v script >/dev/null 2>&1; then
  mkdir -p "$T/home"
  out="$(HOME="$T/home" script -qec "$REPO_DIR/install.sh --upgrade" /dev/null 2>&1 </dev/null || true)"
  check "--upgrade with nothing installed: refused" "$(grep -c 'Nothing to upgrade' <<<"$out")" 1
  check "--upgrade with nothing installed: refused before the checkout step" \
    "$(grep -c 'Newest release' <<<"$out" || true)" 0
else
  echo "note - no 'script' here: the refusal order is not checked"
fi

exit "$fail"

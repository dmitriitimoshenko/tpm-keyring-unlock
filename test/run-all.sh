#!/usr/bin/env bash
# Runs the full test suite: the no-container regex test, the runtime
# behavior test (pamtester + fake helper, in a container), and the
# packaging/detection test across four distros (+ an arm64 cross-build of
# the Ubuntu one, if buildx/qemu-user-static are set up). See test/README.md
# for what this does and doesn't cover.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

RESULTS=()
record() {
  RESULTS+=("$1: $2")
}

# `docker buildx version` only proves the buildx CLI plugin exists - it says
# nothing about whether foreign-arch containers can actually *run* (cached
# layers can make `buildx build` itself succeed with no emulation at all, see
# JOURNAL.md). Check the kernel's binfmt_misc table directly instead, the
# same way this was diagnosed by hand originally, so a host with buildx but
# no registered qemu handler gets a clean SKIPPED instead of a false FAIL.
arm64_emulation_available() {
  docker buildx version >/dev/null 2>&1 \
    && ls /proc/sys/fs/binfmt_misc 2>/dev/null | grep -qiE 'aarch64|arm64'
}

echo "########################################"
echo "# 1/3 - regex/detection logic (no container)"
echo "########################################"
if test/unit-regex-test.sh; then
  record "regex/detection" PASS
else
  record "regex/detection" FAIL
fi

if ! command -v docker >/dev/null 2>&1; then
  echo
  echo "docker not found - skipping the container-based tests (runtime" >&2
  echo "behavior + per-distro packaging). Install docker to run those." >&2
  record "runtime (pamtester + fake helper)" SKIPPED
  for d in ubuntu debian fedora arch opensuse; do
    record "packaging: $d" SKIPPED
  done
  record "packaging: ubuntu (arm64, cross-build)" SKIPPED
else
  echo
  echo "########################################"
  echo "# 2/3 - PAM module runtime behavior (container)"
  echo "########################################"
  if docker build -q -f test/distro/Dockerfile.runtime -t tpm-keyring-unlock-test-runtime . \
       && docker run --rm tpm-keyring-unlock-test-runtime; then
    record "runtime (pamtester + fake helper)" PASS
  else
    record "runtime (pamtester + fake helper)" FAIL
  fi

  echo
  echo "########################################"
  echo "# 3/3 - packaging + PAM-dir detection per distro (container)"
  echo "########################################"
  for d in ubuntu debian fedora arch opensuse; do
    echo
    echo "--- $d ---"
    if docker build -q -f "test/distro/Dockerfile.$d" -t "tpm-keyring-unlock-test-$d" . \
         && docker run --rm "tpm-keyring-unlock-test-$d"; then
      record "packaging: $d" PASS
    else
      record "packaging: $d" FAIL
    fi
  done

  echo
  echo "--- ubuntu (arm64, cross-build via buildx + qemu-user-static) ---"
  if arm64_emulation_available; then
    if docker buildx build --platform linux/arm64 -f test/distro/Dockerfile.ubuntu \
         -t tpm-keyring-unlock-test-ubuntu-arm64 --load . \
         && docker run --rm --platform linux/arm64 tpm-keyring-unlock-test-ubuntu-arm64; then
      record "packaging: ubuntu (arm64, cross-build)" PASS
    else
      record "packaging: ubuntu (arm64, cross-build)" FAIL
    fi
  else
    echo "docker buildx and/or a registered qemu binfmt handler not" >&2
    echo "available - skipping the arm64 cross-build. (needs: docker" >&2
    echo "buildx install, and qemu-user-static / binfmt support registered" >&2
    echo "on the host, e.g. 'docker run --privileged --rm tonistiigi/binfmt" >&2
    echo "--install all' - see test/README.md)" >&2
    record "packaging: ubuntu (arm64, cross-build)" SKIPPED
  fi
fi

echo
echo "########################################"
echo "# Summary"
echo "########################################"
overall=0
for r in "${RESULTS[@]}"; do
  echo "$r"
  case "$r" in *FAIL*) overall=1 ;; esac
done
exit "$overall"

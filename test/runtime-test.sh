#!/usr/bin/env bash
# Exercises the compiled PAM module's actual runtime behavior - the part
# that has nothing to do with TPM hardware and everything to do with
# fork/exec/pipe/timeout/PAM_AUTHTOK plumbing. Runs inside a container as
# root (see test/distro/Dockerfile.runtime), never on a real machine: it
# installs a module into the system PAM directory and creates throwaway
# system users, neither of which should ever happen outside a disposable
# container.
#
# What this can't cover: the TPM/PCR7 sealing itself, since there's no TPM
# in a container. That's why HELPER_PATH is overridden at compile time to
# point at a fake helper script instead of the real
# /usr/local/sbin/tpm-keyring-unseal - this test is entirely about whether
# the module correctly bridges *whatever the helper prints* into
# PAM_AUTHTOK, not about whether the real helper's TPM calls are correct
# (bin/lib.sh's require_secure_boot and the seal/unseal round trip are
# tested separately, on real hardware or a VM with a virtual TPM - see
# README.md's testing section).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_HELPER=/usr/local/sbin/fake-tpm-keyring-unseal
FAKE_PASSWORD="unit-test-fake-password-do-not-use"
CAPTURE_FILE=/tmp/spy-authtok

# shellcheck source=../bin/lib.sh
source "$REPO_DIR/bin/lib.sh"

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

echo "-- building module against fake helper (2s timeout instead of 25s) --"
gcc -Wall -Wextra -fPIC -shared \
  -DHELPER_PATH="\"$FAKE_HELPER\"" -DHELPER_TIMEOUT_SECS=2 \
  -o /tmp/pam_tpm_keyring_authtok.so \
  "$REPO_DIR/pam/pam_tpm_keyring_authtok.c" -lpam

PAM_MODULE_DIR="$(find_pam_module_dir)"
install -o root -g root -m 0644 /tmp/pam_tpm_keyring_authtok.so \
  "$PAM_MODULE_DIR/pam_tpm_keyring_authtok.so"
echo "installed to $PAM_MODULE_DIR"

echo "-- building the spy module (reads back PAM_AUTHTOK via pam_get_item," \
     "the same call pam_gnome_keyring.so makes in production) --"
gcc -Wall -Wextra -fPIC -shared \
  -o /tmp/pam_spy_authtok.so \
  "$REPO_DIR/test/fixtures/pam_spy_authtok.c" -lpam
install -o root -g root -m 0644 /tmp/pam_spy_authtok.so \
  "$PAM_MODULE_DIR/pam_spy_authtok.so"

echo "-- fake helper: branches on username, mimicking three real outcomes --"
cat > "$FAKE_HELPER" <<EOF
#!/bin/sh
# Not the real tpm-keyring-unseal - stands in for it in this test only.
case "\$1" in
  testsuccess) echo "$FAKE_PASSWORD" ;;
  testfail) exit 1 ;;
  testtimeout) sleep 10 ;;
esac
EOF
chmod 0700 "$FAKE_HELPER"
chown root:root "$FAKE_HELPER"

echo "-- test users (no real login capability, just for getpwnam() to work) --"
for u in testsuccess testfail testtimeout; do
  id "$u" >/dev/null 2>&1 || useradd -M -N -s /bin/false "$u"
done

cat > /etc/pam.d/tpmtest <<EOF
auth	optional	pam_tpm_keyring_authtok.so
auth	optional	pam_spy_authtok.so
auth	required	pam_permit.so
EOF

run_case() {
  local user="$1"
  rm -f "$CAPTURE_FILE"
  local start end
  start=$(date +%s)
  pamtester tpmtest "$user" authenticate >/dev/null 2>&1 || true
  end=$(date +%s)
  echo "$((end - start))"
}

echo
echo "-- case: helper succeeds --"
elapsed=$(run_case testsuccess)
got_pw="$(cat "$CAPTURE_FILE" 2>/dev/null || echo "<none>")"
check "PAM_AUTHTOK equals what the helper printed" "$got_pw" "$FAKE_PASSWORD"

echo
echo "-- case: helper exits 1 with no output --"
elapsed=$(run_case testfail)
got_pw="$(cat "$CAPTURE_FILE" 2>/dev/null || echo "<none>")"
check "PAM_AUTHTOK stays empty when helper fails" "$got_pw" ""

echo
echo "-- case: helper hangs past the (test-shortened) timeout --"
elapsed=$(run_case testtimeout)
got_pw="$(cat "$CAPTURE_FILE" 2>/dev/null || echo "<none>")"
check "PAM_AUTHTOK stays empty when helper times out" "$got_pw" ""
if [ "$elapsed" -le 5 ]; then got_timing=bounded; else got_timing=unbounded; fi
check "timeout actually interrupted the hang (took ${elapsed}s, helper sleeps 10s)" "$got_timing" "bounded"

echo
echo
echo "-- control flow of the fingerprint attempt stack (bin/lib.sh's"
echo "   pam_fprintd_harden) --"
# There is no fingerprint reader in a container, so pam_flow_stub.so stands in
# for pam_fprintd.so and returns the three outcomes the real module produces.
# What's actually under test is libpam's handling of the bracketed control
# field: whether a success jump records a positive result for the stack (if it
# doesn't, a matched finger would fail the login), whether
# authinfo_unavail=ignore really falls through to the next attempt, and
# whether default=die stops on a mismatch.
FLOW_LOG=/tmp/pam-flow.log

gcc -Wall -Wextra -fPIC -shared \
  -o /tmp/pam_flow_stub.so \
  "$REPO_DIR/test/fixtures/pam_flow_stub.c" -lpam
install -o root -g root -m 0644 /tmp/pam_flow_stub.so \
  "$PAM_MODULE_DIR/pam_flow_stub.so"

# The service is built from what pam_fprintd_harden() actually generates, so
# this tests the shipped transformation rather than a hand-copied lookalike.
flow_service() {
  printf 'auth\trequired\tpam_fprintd.so\n' \
    | pam_fprintd_harden \
    | awk -v r1="$1" -v r2="$2" -v r3="$3" '
        {
          n++
          r = (n == 1 ? r1 : (n == 2 ? r2 : r3))
          sub(/pam_fprintd\.so.*/, sprintf("pam_flow_stub.so mark=fp%d ret=%s", n, r))
          print
        }' >/etc/pam.d/flowtest
  # the keyring lines the real gdm-fingerprint stack carries below fprintd
  cat >>/etc/pam.d/flowtest <<'INNER'
auth	optional	pam_flow_stub.so mark=tpm ret=success
auth	optional	pam_flow_stub.so mark=keyring ret=success
INNER
}

flow_case() {
  flow_service "$1" "$2" "$3"
  rm -f "$FLOW_LOG"
  local r
  if pamtester flowtest testsuccess authenticate >/dev/null 2>&1; then r=success; else r=failure; fi
  printf '%s %s' "$r" "$(tr '\n' ',' <"$FLOW_LOG" 2>/dev/null || true)"
}

check "match on the 1st attempt: succeeds and still reaches the keyring lines" \
  "$(flow_case success success success)" "success fp1,tpm,keyring,"
check "bad scan then match: 2nd attempt runs, stack still succeeds" \
  "$(flow_case authinfo_unavail success success)" "success fp1,fp2,tpm,keyring,"
check "two bad scans then match: 3rd attempt runs, stack still succeeds" \
  "$(flow_case authinfo_unavail authinfo_unavail success)" "success fp1,fp2,fp3,tpm,keyring,"
check "three bad scans: stack fails (no unauthenticated success)" \
  "$(flow_case authinfo_unavail authinfo_unavail authinfo_unavail)" \
  "failure fp1,fp2,fp3,tpm,keyring,"

# A mismatch has to cost exactly one attempt, same as a bad scan - that is the
# whole point of max-tries=1 plus auth_err/maxtries=ignore. With max-tries=1 a
# single no-match comes back as PAM_MAXTRIES, an unrecognised verify result as
# PAM_AUTH_ERR, so both have to fall through.
check "mismatch (PAM_MAXTRIES) then match: 2nd attempt runs, stack succeeds" \
  "$(flow_case maxtries success success)" "success fp1,fp2,tpm,keyring,"
check "unrecognised result (PAM_AUTH_ERR) then match: 2nd attempt runs" \
  "$(flow_case auth_err success success)" "success fp1,fp2,tpm,keyring,"
check "mixed failures still cost one attempt each, and the 3rd can match" \
  "$(flow_case maxtries authinfo_unavail success)" "success fp1,fp2,fp3,tpm,keyring,"
check "three mismatches: all three attempts run, then the stack fails" \
  "$(flow_case maxtries maxtries maxtries)" "failure fp1,fp2,fp3,tpm,keyring,"

# default=die: anything genuinely broken must stop at once rather than be
# retried three times over.
check "aborted conversation: dies on the spot, no further attempts" \
  "$(flow_case abort success success)" "failure fp1,"

if [ "$fail" -eq 0 ]; then
  echo "All runtime tests passed."
else
  echo "Some runtime tests FAILED." >&2
fi
exit "$fail"

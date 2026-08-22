# Tests

```bash
test/run-all.sh
```

Runs everything below and prints a pass/fail summary. Needs `docker` for
everything except the first item; without it, those are reported as
`SKIPPED`, not silently omitted. Same for the arm64 cross-build specifically
- it also needs a registered qemu binfmt handler (`docker run --privileged
--rm tonistiigi/binfmt --install all`), separately from `docker buildx`
itself being installed; without one it's `SKIPPED` too, rather than failing.

CI runs the same layers as separate GitHub Actions jobs on every push to
`main` and every PR - see `.github/workflows/test.yml`. The CI runner
registers qemu itself (`docker/setup-qemu-action`), so the arm64 job always
actually runs there, never skips.

## What's actually covered

- **`test/unit-regex-test.sh`** (no container) — the PAM auth-line
  detection/insertion regex (`bin/lib.sh`'s `PAM_GNOME_KEYRING_AUTH_RE`)
  against fixture files under `test/fixtures/pam.d/`: plain control syntax,
  bracketed control syntax, an already-patched file (must be skipped, not
  double-patched), and a file with no `pam_gnome_keyring.so` line at all.
- **`test/runtime-test.sh`** (one container, distro doesn't matter) — the
  compiled PAM module's actual fork/exec/pipe/timeout/`PAM_AUTHTOK` logic,
  using `pamtester` + a fake helper script standing in for
  `/usr/local/sbin/tpm-keyring-unseal` (swapped in at compile time via
  `-DHELPER_PATH`). Covers three real code paths: helper succeeds (password
  lands in `PAM_AUTHTOK`, captured via `pam_exec.so expose_authtok`), helper
  exits with no output (`PAM_AUTHTOK` stays empty), and helper hangs past
  the timeout (`-DHELPER_TIMEOUT_SECS=2` for the test, instead of waiting
  out the real 15s - asserts the process actually gets killed and the call
  returns promptly instead of hanging).
- **`test/distro/Dockerfile.{ubuntu,debian,fedora,arch,opensuse}`** +
  **`test/distro/test-packaging.sh`** — on each distro's own real base
  image: install the declared dependencies via that distro's real package
  manager (exercising `install.sh`'s actual per-manager package-name
  mapping, not a mock of it), compile the module against that distro's
  real PAM headers, and confirm `find_pam_module_dir()` (`bin/lib.sh`)
  lands on a directory that genuinely contains `pam_unix.so` on that
  distro - not just "some directory existed". Debian gets its own
  Dockerfile alongside Ubuntu's even though both go through the same
  `apt` codepath in `install.sh`: same package manager, different base
  image and default package versions, so "works on Ubuntu" isn't proof it
  works on Debian proper too.
- **arm64 cross-build** of the Ubuntu packaging test, via `docker buildx
  --platform linux/arm64` (needs `qemu-user-static`/binfmt registered on
  the host - see your distro's docs for `docker buildx` + QEMU
  emulation setup if `run-all.sh` reports this skipped). Confirms the
  module actually compiles and `find_pam_module_dir()`'s
  `aarch64-linux-gnu` candidates resolve correctly under real ARM64
  userspace, not just that the string is in the candidate list.

## The VM layer: `test/vm/run-vm-test.sh`

```bash
test/vm/run-vm-test.sh   # or: make test-vm
```

Everything above shares the host kernel and has no independent TPM or UEFI
firmware state, so `bin/seal.sh`, `require_secure_boot()`'s actual
detection paths, and the real `tpm-keyring-unseal` helper are structurally
untestable in a container. This script covers that layer with a real VM:
`qemu`/KVM + OVMF (real, toggleable Secure Boot state - both the plain and
`.ms` vars templates) + `swtpm` (a real TPM 2.0 device, not a fake helper
script). Two scenarios:

- **Secure Boot OFF** - boots with the empty (no enrolled keys) OVMF vars
  template and confirms `require_secure_boot()` genuinely refuses.
- **Secure Boot ON** - boots with the `.ms` (Microsoft keys pre-enrolled)
  vars template, confirms `require_secure_boot()` allows, then runs the
  real `bin/seal.sh` (a throwaway test secret, never a real password) and
  `pam/tpm-keyring-unseal.sh` against the real PCR7 policy. Then it fully
  stops both `swtpm` and `qemu` and restarts them against the same
  on-disk TPM state / OVMF vars / disk image - a genuine TPM reset-count
  increment, the same trigger as a real reboot - and confirms
  `tpm-keyring-unseal.sh` still unseals correctly. That's exactly the "integrity
  check failed" / "PCR have changed since checked" failure class documented
  in `JOURNAL.md`'s reboot-survival bugs, which no container can reproduce.
  Before that reboot it also injects a deterministic `tpm2_create` failure
  during re-sealing and proves that the previously working enrollment still
  unseals, covering the transactional staging path in `bin/seal.sh`.
  It also fires two concurrent unseal calls at the real TPM to check the
  `flock` serialization fix for the second reboot regression in the journal.

Needs `swtpm`, `qemu-system-x86_64`/`qemu-img`, `/dev/kvm`, and network
access once to fetch a small Ubuntu cloud image (cached afterward,
re-verified against Ubuntu's published checksum every run). Missing any of
these is a clean `SKIPPED`, same convention as everywhere else in this
suite - see the script's preflight section for exact package names.

Opt-in, not part of `test/run-all.sh`: real VM boots are slower than
containers. It does run in CI though (the `vm` job in
`.github/workflows/test.yml`) - GitHub-hosted Linux runners expose
`/dev/kvm`, which is what makes that possible there at all.

**Known CI-only limitation: the reboot-survival check is informational,
not a gate, in CI specifically.** On GitHub-hosted runners, PCR7 has been
observed to genuinely differ (confirmed via a direct `tpm2_pcrread`
comparison, not inferred from an error code) between boot 1 and boot 2 of
the *same* VM/disk/TPM-state - even with a fully graceful guest shutdown
in between - something never once reproduced across many repeated local
runs. Root cause not understood yet (see `JOURNAL.md` for the full
investigation, including the buffered-pflash-write hypothesis that was
tried and ruled out). Until it is, `.github/workflows/test.yml` sets
`KNOWN_CI_PCR7_DRIFT=1` for the `vm` job specifically, which makes
`run-vm-test.sh` print a mismatch on this one check as `KNOWN LIMITATION`
instead of `FAIL` and not count it toward the exit code - every other
check in the same job (including the same-boot seal/unseal round trip and
the concurrent-unseal `flock` check) still gates normally. Locally,
`make test-vm` never sets that variable, so this check is still a hard
failure there - which is where it actually catches product regressions,
since the CI-specific PCR7 drift appears to be an environment quirk
unrelated to `bin/seal.sh`/`pam/tpm-keyring-unseal.sh`'s own logic.

## What even the VM layer doesn't cover, and why

A real graphical login (GDM prompting for and reading a fingerprint) isn't
exercised here either - that needs a full desktop session inside the VM,
not just a booted OS. `libfprint` ships a virtual/test fingerprint device
driver (used in its own CI) that could exercise that path inside a VM
without physical hardware, but automating a real GDM greeter reliably is a
meaningfully heavier, more failure-prone undertaking than the headless
seal/unseal round trip above - not implemented here. `virt-manager` makes
building such a VM by hand easy through its GUI, for manual testing.

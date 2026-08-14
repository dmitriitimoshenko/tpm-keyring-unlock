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
- **`test/distro/Dockerfile.{ubuntu,fedora,arch,opensuse}`** +
  **`test/distro/test-packaging.sh`** — on each distro's own real base
  image: install the declared dependencies via that distro's real package
  manager (exercising `install.sh`'s actual per-manager package-name
  mapping, not a mock of it), compile the module against that distro's
  real PAM headers, and confirm `find_pam_module_dir()` (`bin/lib.sh`)
  lands on a directory that genuinely contains `pam_unix.so` on that
  distro - not just "some directory existed".
- **arm64 cross-build** of the Ubuntu packaging test, via `docker buildx
  --platform linux/arm64` (needs `qemu-user-static`/binfmt registered on
  the host - see your distro's docs for `docker buildx` + QEMU
  emulation setup if `run-all.sh` reports this skipped). Confirms the
  module actually compiles and `find_pam_module_dir()`'s
  `aarch64-linux-gnu` candidates resolve correctly under real ARM64
  userspace, not just that the string is in the candidate list.

## What's deliberately not covered here, and why

Nothing here touches a TPM, Secure Boot, or a real PAM-driven login. A
plain container shares the host kernel and has no independent TPM or UEFI
firmware state - there's no PCR7 to seal against, so `bin/seal.sh`,
`require_secure_boot()`'s actual detection paths, and the real
`tpm-keyring-unseal` helper are structurally untestable in Docker. That's
also true of a real graphical login (GDM/PAM prompting for a fingerprint) -
containers don't have one.

For that layer, the right tool is a VM with `swtpm` (virtual TPM 2.0) and
OVMF (UEFI firmware with real, toggleable Secure Boot state) - see the
main README's testing recommendations. `virt-manager` makes both easy to
add through its GUI. `libfprint` also ships a virtual/test fingerprint
device driver (used in its own CI) that can exercise the fingerprint path
inside such a VM without physical hardware.

In short: this suite proves the PAM_AUTHTOK bridge logic and the
packaging/detection layer work, across four distros and two
architectures. It doesn't and can't prove the TPM sealing itself works -
that's a VM-and-real-hardware question, not a Docker question.

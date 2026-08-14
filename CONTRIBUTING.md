# Contributing

## Project layout

- `install.sh` / `uninstall.sh` — the actual tool.
- `bin/seal.sh` — interactive TPM sealing, run by end users directly.
- `bin/lib.sh` — shared logic (`install.sh`, `uninstall.sh`, and the test
  suite all source this rather than keeping their own copies, so they
  can't drift out of sync on things like the PAM module directory
  candidate list or the PAM-line detection regex).
- `pam/` — the PAM module source and its root-owned helper script.
- `JOURNAL.md` — the running decision/debugging log. Read `CLAUDE.md` for
  the standing rule about keeping it updated; it applies to human
  contributors too, not just an AI agent working in this repo.

## Running the tests

```bash
make test        # everything; or: test/run-all.sh
make test-regex  # just the PAM-line detection regex (no docker needed)
make test-runtime    # just the PAM module's runtime behavior
make test-packaging  # just the per-distro dependency/compile/detection checks
make test-vm      # real TPM/Secure Boot round trip in a VM (opt-in, see below)
make build        # compile the module locally, no tests
```

The full suite (`make test`) needs `docker`; without it, the
container-based parts are skipped and reported as `SKIPPED`, not silently
dropped. `make test-vm` is separate and opt-in - it needs `swtpm`, `qemu`,
and `/dev/kvm`, and is the only layer that touches a real TPM/Secure Boot
state instead of a fake stand-in. See `test/README.md`.

CI (`.github/workflows/test.yml`) runs the same checks as separate jobs on
every push to `main` and every PR, including the VM layer, so `SKIPPED`
locally (e.g. no qemu binfmt registered for the arm64 leg, or no swtpm
installed) doesn't mean untested - CI has it covered.

**What's actually covered, and what isn't** — see
[`test/README.md`](test/README.md). Short version: everything that
doesn't need a TPM or a real login (the PAM_AUTHTOK bridge logic, PAM-file
detection/patching, per-distro dependency installation, cross-compiling
for arm64) is covered by the Docker-based suite. The TPM/PCR7/Secure-Boot
layer and a real graphical login can't be tested in a plain container —
that needs a VM with a virtual TPM (`swtpm` + OVMF), which `test/README.md`
also covers.

## Making changes

- Keep `install.sh`/`uninstall.sh`/`bin/seal.sh` mirror images where it
  matters: whatever one sets up, the other should be able to tear down.
- If you touch anything in `bin/lib.sh`, re-run `make test` — both the
  detection regex test and every per-distro container depend on it.
- If you touch `pam/pam_tpm_keyring_authtok.c`, run `make test-runtime` at
  minimum; it's the only thing that exercises the module's actual
  fork/exec/timeout logic rather than just compiling it.
- Add a `JOURNAL.md` entry for anything non-obvious — a root cause found,
  a design decision, a dead end. See `CLAUDE.md`.

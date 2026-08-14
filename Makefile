# Convenience wrappers around test/run-all.sh and friends. Not required to
# use this project - install.sh/uninstall.sh never call make - this is
# purely for running the test suite without remembering paths.

.PHONY: test test-regex test-runtime test-packaging test-vm build clean

# Full suite: regex/detection (no docker), runtime behavior, per-distro
# packaging + arm64 cross-build. See test/README.md for what each covers.
# Doesn't include test-vm - see that target, it's opt-in (slower, needs
# swtpm/KVM).
test:
	./test/run-all.sh

# Just the fast, no-docker regex/detection logic test.
test-regex:
	./test/unit-regex-test.sh

# Real TPM/Secure Boot round trip in a VM (swtpm + OVMF) - the layer Docker
# structurally can't cover. Needs swtpm, qemu, and /dev/kvm; degrades to a
# clean SKIPPED if any are missing. See test/README.md.
test-vm:
	./test/vm/run-vm-test.sh

# Just the PAM module runtime-behavior test (pamtester + fake helper).
test-runtime:
	docker build -q -f test/distro/Dockerfile.runtime -t tpm-keyring-unlock-test-runtime .
	docker run --rm tpm-keyring-unlock-test-runtime

# Just the per-distro dependency/compile/PAM-dir-detection tests.
test-packaging:
	@for d in ubuntu fedora arch opensuse; do \
		echo "--- $$d ---"; \
		docker build -q -f test/distro/Dockerfile.$$d -t tpm-keyring-unlock-test-$$d . && \
		docker run --rm tpm-keyring-unlock-test-$$d || exit 1; \
	done

# Compiles the PAM module the same way install.sh does, for a quick local
# check without running the full test suite.
build:
	gcc -Wall -Wextra -fPIC -shared -o pam/pam_tpm_keyring_authtok.so pam/pam_tpm_keyring_authtok.c -lpam

clean:
	rm -f pam/pam_tpm_keyring_authtok.so

# Two jobs in one file.
#
# 1. Convenience wrappers around test/run-all.sh and friends.
# 2. A build/install path for DISTRIBUTION PACKAGES (OBS, AUR, ...), which
#    need to compile into a staging tree and drop files wherever the distro
#    says, with no network, no prompts and no root.
#
# The hand-rolled path is untouched by any of this: ./install.sh compiles and
# installs the module itself and never calls make. Both can exist on one
# machine, but they write the SAME PAM module filename, so the last one to run
# wins - pick one per machine. See packaging/README.md.

DESTDIR     ?=
PREFIX      ?= /usr/local
BINDIR      ?= $(PREFIX)/bin
LIBEXECDIR  ?= $(PREFIX)/libexec/tpm-keyring-unlock
DATAROOTDIR ?= $(PREFIX)/share

# Where PAM loads modules from - different on every distro family, so a
# package always passes this in (Debian: /usr/lib/<triplet>/security, Fedora
# and openSUSE: /usr/lib64/security, Arch: /usr/lib/security). The fallback
# reuses bin/lib.sh's own detection rather than keeping a second list here.
PAMDIR      ?= $(shell bash -c 'source $(CURDIR)/bin/lib.sh && find_pam_module_dir' 2>/dev/null || echo /usr/lib/security)

# Baked into the module at compile time, because a PAM module cannot look
# anything up at runtime. install.sh's own build uses the C default
# (/usr/local/sbin/tpm-keyring-unseal); a packaged build points here instead,
# since /usr/local is off limits to packages.
HELPER_PATH ?= $(LIBEXECDIR)/tpm-keyring-unseal

CC          ?= gcc
CFLAGS      ?= -Wall -Wextra -O2
MODULE      := pam/pam_tpm_keyring_authtok.so

INSTALL     ?= install

.PHONY: all test test-regex test-runtime test-packaging test-vm build install uninstall clean

# MUST stay the first rule in this file. `make` with no target is what every
# packaging recipe runs (rpm's %make_build, dh_auto_build), and before this
# existed the first rule was `test` - so an rpm build ran the test suite and
# then compiled the module during %install instead, missing the distribution's
# own CFLAGS. Caught by actually building the package; see JOURNAL.md.
all: build

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
	@for d in ubuntu debian fedora arch opensuse; do \
		echo "--- $$d ---"; \
		docker build -q -f test/distro/Dockerfile.$$d -t tpm-keyring-unlock-test-$$d . && \
		docker run --rm tpm-keyring-unlock-test-$$d || exit 1; \
	done

# Compiles the PAM module for `make install`. Not identical to install.sh's
# own build: this one bakes in $(HELPER_PATH), install.sh keeps the C default.
build: $(MODULE)

$(MODULE): pam/pam_tpm_keyring_authtok.c
	$(CC) $(CFLAGS) -fPIC -shared -DHELPER_PATH='"$(HELPER_PATH)"' \
		-o $@ $< -lpam $(LDFLAGS)

# Staging-tree install for packagers. Deliberately does NOT touch /etc/pam.d,
# does not seal anything, and asks nothing: a package installs files, and the
# admin runs tpm-keyring-unlock-configure afterwards. Ownership is left to the
# packaging (%attr in the spec, dh in Debian); only modes are set here, and
# the helper keeps 0700 because it unseals a secret as root.
install: build
	$(INSTALL) -d $(DESTDIR)$(PAMDIR) $(DESTDIR)$(LIBEXECDIR) $(DESTDIR)$(BINDIR)
	# 0755, which is what Fedora and openSUSE ship PAM modules as. Not
	# cosmetic: rpm's find-debuginfo only looks at files carrying an execute
	# bit, so at 0644 it extracts nothing and the build dies on an empty
	# debugsource package. Debian prefers 0644 and dh_fixperms puts it back.
	# The bit means nothing for a dlopen'd object either way.
	$(INSTALL) -m 0755 $(MODULE) $(DESTDIR)$(PAMDIR)/pam_tpm_keyring_authtok.so
	$(INSTALL) -m 0700 pam/tpm-keyring-unseal.sh $(DESTDIR)$(HELPER_PATH)
	$(INSTALL) -m 0644 bin/lib.sh $(DESTDIR)$(LIBEXECDIR)/lib.sh
	$(INSTALL) -m 0755 bin/seal.sh $(DESTDIR)$(LIBEXECDIR)/seal.sh
	$(INSTALL) -m 0755 install.sh $(DESTDIR)$(LIBEXECDIR)/configure.sh
	$(INSTALL) -m 0755 uninstall.sh $(DESTDIR)$(LIBEXECDIR)/deconfigure.sh
	# Wrappers rather than symlinks: rpm warns about absolute symlinks out of
	# %{_bindir}, a relative one would hard-code how BINDIR and LIBEXECDIR sit
	# relative to each other, and two of the three have to pass --no-build
	# anyway (the package owns the module and the helper, so the configure
	# step must not rebuild or reinstall them).
	printf '#!/bin/sh\nexec %s/seal.sh "$$@"\n' '$(LIBEXECDIR)' \
		>$(DESTDIR)$(BINDIR)/tpm-keyring-seal
	# TPM_KEYRING_HELPER, or the scripts fall back to the hand-rolled
	# /usr/local/sbin path and refuse to run because the helper "is missing" -
	# it is simply somewhere else in a packaged install. Caught by the VM
	# test's packaged-path scenario; see JOURNAL.md, 2026-09-16.
	printf '#!/bin/sh\nexec env TPM_KEYRING_HELPER=%s %s/configure.sh --no-build "$$@"\n' \
		'$(HELPER_PATH)' '$(LIBEXECDIR)' \
		>$(DESTDIR)$(BINDIR)/tpm-keyring-unlock-configure
	printf '#!/bin/sh\nexec env TPM_KEYRING_HELPER=%s %s/deconfigure.sh --no-build "$$@"\n' \
		'$(HELPER_PATH)' '$(LIBEXECDIR)' \
		>$(DESTDIR)$(BINDIR)/tpm-keyring-unlock-deconfigure
	chmod 0755 $(DESTDIR)$(BINDIR)/tpm-keyring-seal \
		$(DESTDIR)$(BINDIR)/tpm-keyring-unlock-configure \
		$(DESTDIR)$(BINDIR)/tpm-keyring-unlock-deconfigure

uninstall:
	rm -f $(DESTDIR)$(PAMDIR)/pam_tpm_keyring_authtok.so \
		$(DESTDIR)$(HELPER_PATH) \
		$(DESTDIR)$(BINDIR)/tpm-keyring-seal \
		$(DESTDIR)$(BINDIR)/tpm-keyring-unlock-configure \
		$(DESTDIR)$(BINDIR)/tpm-keyring-unlock-deconfigure
	rm -rf $(DESTDIR)$(LIBEXECDIR)

clean:
	rm -f $(MODULE)

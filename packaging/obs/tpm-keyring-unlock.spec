#
# RPM recipe: openSUSE (Tumbleweed, Leap), Fedora, RHEL/CentOS Stream.
# Built by OBS from the tarball that _service pulls from the git tag.
#
Name:           tpm-keyring-unlock
Version:        1.7.1
Release:        0
Summary:        TPM-backed unlock of the GNOME login keyring at login
License:        MIT
URL:            https://github.com/dmitriitimoshenko/tpm-keyring-unlock
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  pam-devel

# Same tool, two names: openSUSE ships it as tpm2.0-tools.
%if 0%{?suse_version}
Requires:       tpm2.0-tools
%else
Requires:       tpm2-tools
%endif
Requires:       bash
Requires:       coreutils

%description
A PAM module that hands a TPM-sealed copy of the GNOME keyring password to
pam_gnome_keyring at login, so the login keyring unlocks even when the login
itself was by fingerprint - without blanking the keyring password.

The secret is sealed to this machine's TPM under a PCR7 (Secure Boot) policy.
Installing this package only puts the files in place; run
tpm-keyring-unlock-configure afterwards to seal a password and wire up PAM.

%prep
%autosetup

%build
# The distribution's own flags, not the Makefile's defaults: they carry the
# hardening options and -g. Without -g rpm's debuginfo extraction produces an
# empty debugsource package and the build fails outright.
%make_build \
  CFLAGS="%{optflags}" \
  LDFLAGS="%{?build_ldflags}" \
  PREFIX=%{_prefix} \
  PAMDIR=%{_libdir}/security \
  LIBEXECDIR=%{_libexecdir}/%{name}

%install
# Same flags as %build: `install` depends on `build`, and a mismatch here
# would silently recompile the module without the distribution's options.
%make_install \
  CFLAGS="%{optflags}" \
  LDFLAGS="%{?build_ldflags}" \
  PREFIX=%{_prefix} \
  PAMDIR=%{_libdir}/security \
  LIBEXECDIR=%{_libexecdir}/%{name}

%postun
# tpm-keyring-unlock-configure may have loaded the SELinux module, which lets
# every process in GDM's domain open the TPM (README.md, "SELinux"). With the
# package erased no helper is left to need it, so a full erase - never an
# upgrade - takes it out, and never fails the transaction over it.
if [ "$1" -eq 0 ] && command -v semodule >/dev/null 2>&1; then
  if semodule -l 2>/dev/null | grep -qx tpm_keyring_unlock; then
    semodule -r tpm_keyring_unlock >/dev/null 2>&1 || :
  fi
fi

%files
%license LICENSE
%doc README.md SECURITY.md
%{_libdir}/security/pam_tpm_keyring_authtok.so
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/lib.sh
# Loaded by tpm-keyring-unlock-configure on SELinux systems, never here.
%{_libexecdir}/%{name}/tpm_keyring_unlock.cil
%{_libexecdir}/%{name}/seal.sh
# The optional power-button LED service. tpm-keyring-unlock-configure installs
# the last three into /etc on a Framework laptop, when asked to; never here.
%{_libexecdir}/%{name}/tpm-keyring-led
%{_libexecdir}/%{name}/tpm-keyring-led.service
%{_libexecdir}/%{name}/90-tpm-keyring-led.rules
%{_libexecdir}/%{name}/tpm-keyring-led.sysusers
%{_libexecdir}/%{name}/configure.sh
%{_libexecdir}/%{name}/deconfigure.sh
# root-only: it unseals the keyring password and is executed by PAM as root.
%attr(0700,root,root) %{_libexecdir}/%{name}/tpm-keyring-unseal
%{_bindir}/tpm-keyring-seal
%{_bindir}/tpm-keyring-unlock-configure
%{_bindir}/tpm-keyring-unlock-deconfigure

%changelog
* Mon Nov 16 2026 Dmitrii Timoshenko <dmitrii.timoshenko16@gmail.com> - 1.7.1-0
- The power-button LED service of 1.7.0 never started. systemd refused its
  throwaway user, whose name was the service's group's (status 217/USER).
  tpm-keyring-unlock-configure noticed, took it out again and changed
  nothing.
- It now runs as a system user of its own, tpm-keyring-led, made by its
  sysusers file: no login shell, no home, no password. A throwaway user
  (DynamicUser=) cannot reach the system bus where that is dbus-daemon, as
  on Debian and Ubuntu, so even with its name fixed it would not have
  worked there. To get the service, run tpm-keyring-unlock-configure
  --upgrade once and answer the LED question.

* Mon Nov 16 2026 Dmitrii Timoshenko <dmitrii.timoshenko16@gmail.com> - 1.7.0-0
- On a Framework laptop, tpm-keyring-unlock-configure offers to blink the
  power button's LED while the fingerprint reader in it waits for a finger.
  It is a small sandboxed service with no root and no network. It follows
  fprintd's own finger-needed property and hands the LED back to the
  embedded controller afterwards. Asked only where that LED is present and
  a finger is enrolled. Idea and design from framework-fingerprint-led-blink
  by alejandroqh (Apache-2.0), reimplemented in bash.
  tpm-keyring-unlock-deconfigure takes it out.
- tpm-keyring-unlock-configure --upgrade re-checks the configuration after
  a package upgrade and offers what the new version adds. It keeps the
  sealed secret, with nothing to type, while it still unseals through the
  new helper, and re-seals only if it does not. To be offered the LED after
  upgrading, run it once.

* Fri Oct 23 2026 Dmitrii Timoshenko <dmitrii.timoshenko16@gmail.com> - 1.6.0-0
- tpm-keyring-unlock-configure can give polkit prompts (App Center and snap
  installs, other admin actions) a fingerprint line of their own, which the
  lock screen never reads. It is asked the other way round: answer n at
  "Keep polkit prompts password-only?" to add the line, Enter keeps polkit
  password-only. With it, an enrolled finger alone approves root-level
  changes. tpm-keyring-unlock-deconfigure takes it back out.
- Asked only where polkit prompts have no fingerprint and a finger is
  enrolled. To be asked after upgrading, run tpm-keyring-unlock-configure
  once more. Answer n at "Overwrite?" to keep the sealed secret.

* Tue Oct 06 2026 Dmitrii Timoshenko <dmitrii.timoshenko16@gmail.com> - 1.5.1-0
- Fedora: tpm-keyring-unlock-configure now wires gdm-fingerprint, which
  ships with no keyring line, adding the keyring lines with the module
  between them. None of the added lines can vote.
- Under SELinux it loads a one-rule policy module so that GDM's logins can
  reach the TPM. Erasing the package unloads it.
- After upgrading, run tpm-keyring-unlock-configure once more: it re-checks
  the PAM stacks an older version wired. Answer n at "Overwrite?" to keep
  the sealed secret.

* Sat Sep 26 2026 Dmitrii Timoshenko <dmitrii.timoshenko16@gmail.com> - 1.5.0-0
- After upgrading, run tpm-keyring-unlock-configure once more: it re-checks
  the PAM stacks an older version wired and takes the helper back out of
  any the stricter checks now refuse. Answer n at "Overwrite?" to keep the
  sealed secret.

* Wed Sep 16 2026 Dmitrii Timoshenko <dmitrii.timoshenko16@gmail.com> - 1.4.0-0
- Initial packaging: files only; tpm-keyring-unlock-configure does the rest.

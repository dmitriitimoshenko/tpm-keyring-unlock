#
# RPM recipe: openSUSE (Tumbleweed, Leap), Fedora, RHEL/CentOS Stream.
# Built by OBS from the tarball that _service pulls from the git tag.
#
Name:           tpm-keyring-unlock
Version:        1.4.0
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

%files
%license LICENSE
%doc README.md SECURITY.md
%{_libdir}/security/pam_tpm_keyring_authtok.so
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/lib.sh
%{_libexecdir}/%{name}/seal.sh
%{_libexecdir}/%{name}/configure.sh
%{_libexecdir}/%{name}/deconfigure.sh
# root-only: it unseals the keyring password and is executed by PAM as root.
%attr(0700,root,root) %{_libexecdir}/%{name}/tpm-keyring-unseal
%{_bindir}/tpm-keyring-seal
%{_bindir}/tpm-keyring-unlock-configure
%{_bindir}/tpm-keyring-unlock-deconfigure

%changelog
* Wed Sep 16 2026 Dmitrii Timoshenko <dmitrii.timoshenko16@gmail.com> - 1.4.0-0
- Initial packaging: files only; tpm-keyring-unlock-configure does the rest.

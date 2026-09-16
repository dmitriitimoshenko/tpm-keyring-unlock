# Packaging

Two ways to install this tool, and a machine should use exactly one.

| | What it does | Where files go |
|---|---|---|
| `./install.sh` | compiles, installs and configures in one interactive run | `/usr/local/sbin`, PAM module dir |
| a distribution package | installs files only; `tpm-keyring-unlock-configure` does the rest | `/usr/libexec/tpm-keyring-unlock`, PAM module dir |

Both write the same module filename into the same PAM directory, so the last
one to run wins. Nothing is corrupted by mixing them, but a packaged file
replaced by `install.sh` is invisible to the package manager, and the compiled
helper paths differ (`/usr/local/sbin` vs `/usr/libexec`). Pick one.

## Why a package cannot do the whole job

Distribution policy, not a limitation of the tool:

- **Sealing needs the keyring password**, typed on a terminal by the person
  who owns it. Maintainer scripts must not prompt, and debconf is not a place
  for passwords. So the package ships `tpm-keyring-seal`.
- **The PAM edits touch files owned by other packages** (`/etc/pam.d/gdm-*`
  belong to gdm). A package must not edit them in a scriptlet; an admin
  running a command afterwards may. So the package ships
  `tpm-keyring-unlock-configure`, which is `install.sh --no-build`: everything
  except compiling and installing the files the package already owns.

## Build system contract

`make install` is what every packaging recipe calls. Variables:

| Variable | Default | Typical package value |
|---|---|---|
| `DESTDIR` | empty | the staging tree |
| `PREFIX` | `/usr/local` | `/usr` |
| `PAMDIR` | detected via `bin/lib.sh` | `/usr/lib/<triplet>/security` (Debian), `/usr/lib64/security` (Fedora, openSUSE), `/usr/lib/security` (Arch) |
| `LIBEXECDIR` | `$(PREFIX)/libexec/tpm-keyring-unlock` | same, with `PREFIX=/usr` |
| `HELPER_PATH` | `$(LIBEXECDIR)/tpm-keyring-unseal` | inherited |

`HELPER_PATH` is compiled into the module (`-DHELPER_PATH`), because a PAM
module cannot look up a path at runtime. Build and install must be given the
same values, or the module will look for a helper that is not there.

The unseal helper must stay `0700 root:root`: it unseals a keyring password
and PAM runs it as root. `debian.rules` excludes it from `dh_fixperms`, and
the spec sets `%attr(0700,root,root)`.

## OBS (openSUSE, Fedora, RHEL, Debian, Ubuntu)

Files in `obs/`. One OBS package directory holds both recipes - OBS picks the
`.spec` for rpm targets and the `debian.*` files for deb targets.

1. Register at <https://build.opensuse.org>, then `sudo apt install osc` and
   run `osc` once to store credentials.
2. Web UI: **Home Project -> Repositories -> Add from a distribution**, tick
   openSUSE Tumbleweed, Fedora, Debian, Ubuntu; architectures `x86_64` and
   `aarch64`.
3. `osc checkout home:<login>` and create the package directory, then copy
   everything from `obs/` into it.
4. `osc add *` and `osc build openSUSE_Tumbleweed x86_64` to build locally
   first - it catches missing `BuildRequires` before the server does.
5. `osc commit -m "..."`, then watch `osc results` / `osc buildlog <repo> <arch>`.
6. Users get an install page at
   `https://software.opensuse.org/download/package?package=tpm-keyring-unlock&project=home:<login>`.
   OBS signs the repository itself.

New release: change the tag in `_service`'s `path`, bump `Version:` in the
spec and add a `debian.changelog` entry. OBS fetches the tarball itself -
nothing is uploaded by hand.

**Why `download_url` and not `obs_scm`.** The first attempt used `obs_scm`
with `tar`, `recompress` and `set_version` in `mode="buildtime"`, which is the
arrangement the OBS documentation leads with. Every rpm target built; every
deb target came back `unresolvable`:

    nothing provides obs-service-tar, obs-service-recompress, obs-service-set-version

Those services run *inside the build root* in buildtime mode, and the Debian
and Ubuntu base projects do not carry the packages that provide them (Fedora
tripped over a `wget` ambiguity pulling `obs-service-download_files` for the
same reason). Fetching the release tarball server-side at commit time sidesteps
all of it, and has the side benefit that every target consumes the exact file
GitHub publishes for the tag - the same artifact the AUR checksum pins.

## AUR (Arch)

Files in `aur/`. OBS's Arch support is patchy; the AUR is the right route here.

1. Account at <https://aur.archlinux.org>, add an SSH public key under **My
   Account**.
2. `git clone ssh://aur@aur.archlinux.org/tpm-keyring-unlock.git` (the remote
   repository is created on first push).
3. Copy `PKGBUILD` and `tpm-keyring-unlock.install` in, then:
   `updpkgsums` (fills in the real checksum) and
   `makepkg --printsrcinfo > .SRCINFO` (mandatory, the AUR rejects pushes
   without it).
4. `makepkg -si` to prove it builds and installs, `namcap PKGBUILD *.pkg.tar.zst`
   to lint.
5. `git add PKGBUILD .SRCINFO tpm-keyring-unlock.install && git commit && git push`.

Reference: <https://wiki.archlinux.org/title/AUR_submission_guidelines>.

## What has been verified

Both recipes were built, installed and inspected in containers, not just
written:

- Fedora 42, `rpmbuild -bb`: builds clean, installs, `tpm-keyring-unlock-configure`
  runs, helper lands as `-rwx------ root:root`.
- Debian 13, `dpkg-buildpackage -b` + `lintian`: builds clean, installs, both
  commands run, multiarch PAM path correct, helper mode preserved through
  `dh_fixperms`.

`lintian` is error-free. Three `no-manual-page` warnings remain - man pages are
the one known gap, and they matter for Debian proper rather than for OBS or the
AUR. The two permission tags on the helper are recorded in
`debian.lintian-overrides` as deliberate.

## Release checklist

1. `VERSION`, `Version:` in the spec, `pkgver` in `PKGBUILD`,
   `revision` in `_service`, a new `debian.changelog` entry - all to the same
   number.
2. Tag `vX.Y.Z` and push it; the tarballs both services download come from
   that tag.
3. AUR: `updpkgsums && makepkg --printsrcinfo > .SRCINFO`, push.
4. OBS: `osc commit` - it rebuilds every target.

# tpm-keyring-unlock

[![test](https://github.com/dmitriitimoshenko/tpm-keyring-unlock/actions/workflows/test.yml/badge.svg)](https://github.com/dmitriitimoshenko/tpm-keyring-unlock/actions/workflows/test.yml)

You log in with your fingerprint, and GNOME still asks for a password the
first time something needs a saved secret. This fixes that without blanking
the keyring password and without leaving it in a file.

The password goes into the TPM instead, sealed to this machine's Secure Boot
state. PAM unseals it at login.

## Requirements

This only helps if your disk is **not** encrypted. If it is, the keyring
password mostly duplicates protection you already have: blank it and you are
done.

You also need fingerprint login already working, and all of the following.
`install.sh` checks each one and stops if it is missing.

- TPM 2.0 with `/dev/tpmrm0`
- Secure Boot enabled. PCR7 is meaningless as a lock otherwise.
- systemd, and `gnome-keyring` as your actual secrets backend
- `tpm2-tools`, a C compiler, and PAM headers. The installer offers to fetch
  these on apt, dnf, pacman and zypper.

## Install

```bash
git clone https://github.com/dmitriitimoshenko/tpm-keyring-unlock.git
cd tpm-keyring-unlock
./install.sh
```

The installer prints its whole plan first: packages to install, the group
change, and the exact PAM diffs it would apply, with every file backed up. It
asks once before touching anything, and Enter accepts. It will not run without
a terminal.

Sealing the keyring password is part of that run: the installer calls
`bin/seal.sh` itself, which asks for the password in this same terminal. You
type it there. It is never written to disk unencrypted and never passed as a
command-line argument.

Log out and back in to test.

You only run `bin/seal.sh` yourself to **re-seal** later - after a Secure Boot
change, or after changing the keyring password. Straight after a first install
it may refuse with `Can't read TPM PCRs`: the installer ran the TPM steps
inside `sg tss`, and your own shell only picks up the new group membership
after a logout.

### From a distribution package

Prebuilt `x86_64` packages for openSUSE, Fedora, Debian and Ubuntu are
published from the Open Build Service. A package installs the files only -
sealing needs your password typed on a terminal and the PAM edits need your
consent, so neither happens behind a package manager's back.

**openSUSE** (Tumbleweed, Leap 16.0 - swap the repository name):

```bash
sudo zypper addrepo https://download.opensuse.org/repositories/home:/dmitrii.timoshenko/openSUSE_Tumbleweed/home:dmitrii.timoshenko.repo
sudo zypper refresh && sudo zypper install tpm-keyring-unlock
```

**Fedora** (42, 43 - swap the repository name):

```bash
sudo dnf config-manager addrepo --from-repofile=https://download.opensuse.org/repositories/home:/dmitrii.timoshenko/Fedora_42/home:dmitrii.timoshenko.repo
sudo dnf install tpm-keyring-unlock
```

**Debian 13, Ubuntu 24.04 / 26.04** (swap `Debian_13` for `xUbuntu_24.04` or
`xUbuntu_26.04`):

```bash
B=https://download.opensuse.org/repositories/home:/dmitrii.timoshenko/Debian_13
curl -fsSL "$B/Release.key" | gpg --dearmor | sudo tee /usr/share/keyrings/tpm-keyring-unlock.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/tpm-keyring-unlock.gpg] $B/ /" | sudo tee /etc/apt/sources.list.d/tpm-keyring-unlock.list
sudo apt update && sudo apt install tpm-keyring-unlock
```

**Arch**: AUR registration is closed for new accounts at the moment, so there
is no AUR package yet. The recipe works today without it:

```bash
git clone https://github.com/dmitriitimoshenko/tpm-keyring-unlock.git
cd tpm-keyring-unlock/packaging/aur && makepkg -si
```

Then, on any of them:

```bash
tpm-keyring-unlock-configure     # seal + wire up PAM, asks before each change
tpm-keyring-seal                 # re-seal later, on its own
```

Use one method or the other on a given machine, not both: `./install.sh` and a
package write the same PAM module filename, so whichever ran last wins. See
`packaging/README.md`.

## What this protects, and what it doesn't

**Protected: the disk comes out and gets read somewhere else.** The sealed
blob is ciphertext bound to this machine's TPM and its PCR7 state, and neither
travels with the disk.

**Not protected: the whole machine is taken.** PCR7 measures the Secure Boot
state: which keys are enrolled, and which certificate vouched for what loaded.
It does not measure the kernel, the initrd, or the kernel command line. The
policy also has no password on it, because unsealing has to happen at login
without a prompt.

Someone holding your laptop can therefore pick your own installed system in
GRUB, add `init=/bin/bash`, and boot to a root shell. Same bootloader, same
signatures, same PCR7, and the TPM unseals for them exactly as it does for
you. That distro's own install media reaches the same place. Your disk is not
encrypted, which was the premise here, so the sealed file is sitting right
there as well.

**This replaces a keyring password kept in a plaintext file. It is not a
substitute for full-disk encryption.** If "someone walks off with the laptop"
is in your threat model, use FDE, and then you do not need this tool.

Two further limits:

- Anyone with your running, logged-in machine, meaning root or you, can read
  the unsealed value the same way this tool does. Every "unlock without
  asking" scheme has this property.
- A failed fingerprint attempt still triggers an unseal. libpam keeps walking
  the stack after the distro's `required` fingerprint line fails, so the
  module below it runs anyway. The login still fails and the token is
  discarded, but someone at your lock screen can make the TPM perform an
  unseal by touching the sensor. This predates the tool: the seal is bound to
  the machine's state, not to who is standing in front of it.

Binding more PCRs (4, 8 and 9) would narrow the gap. It is not done, because
it would mean re-sealing after every kernel and bootloader update to partly
cover a case FDE already covers.

If your Secure Boot settings ever change, PCR7 changes and the seal breaks.
Re-run `bin/seal.sh`. Routine kernel and driver updates do not affect it.

## How it works

Two separate problems had to be solved.

**1. A systemd/PAM race that breaks keyring auto-unlock for everyone,**
password logins included, on distros that pre-start
`gnome-keyring-daemon.service`. The daemon is already running by the time PAM
tries to unlock it, so PAM spawns a second, disconnected one instead. Masking
the unit fixes it.

> If you get the keyring prompt even with password logins, this alone may be
> your whole fix. Try it before anything else:
>
> ```bash
> systemctl --user mask gnome-keyring-daemon.socket gnome-keyring-daemon.service
> ```

**2. Fingerprint auth never sets `PAM_AUTHTOK`,** so `pam_gnome_keyring.so`
has nothing to work with. A small PAM module unseals the password and sets it
for the next module to use:

```
auth	required	pam_fprintd.so
auth    optional        pam_tpm_keyring_authtok.so   <- added by this tool
auth    optional        pam_gnome_keyring.so         <- already there
```

That module is always `auth optional` and always returns `PAM_IGNORE`, so it
cannot grant or deny a login, including when it fails. If a real password was
typed, it does nothing.

Services named `*fingerprint*` are not the only ones affected. `install.sh`
patches every `/etc/pam.d/` service with an auth-phase `pam_gnome_keyring.so`
line, because `gdm-password` can also succeed via fingerprint once you enable
it system-wide. It refuses to patch a stack where a password module runs
*below* the insertion point, since that would let a token nobody typed
authenticate a login.

## The fingerprint reader dropping out mid-prompt

This is a separate problem, and `install.sh` offers to fix it in the same run.

One badly angled scan, or 30 seconds of not touching the sensor, and
fingerprint disappears for the rest of the lock screen while the sensor keeps
working. `pam_fprintd` returns "no such auth method here", and gnome-shell
treats that as permanent. `max-tries=` does not help, because it only counts
clean mismatches.

PAM has no loop construct, so the fix is to invoke the module three times:

```
auth  [success=2 …]  pam_fprintd.so max-tries=1
auth  [success=1 …]  pam_fprintd.so max-tries=1
auth  required       pam_fprintd.so max-tries=1
```

One line is one scan, so a mismatch, a bad scan and a timeout each cost
exactly one attempt. Three attempts is what the module's own default allowed
before, so the count has not changed, only which failures count toward it.
Each attempt keeps its own 30-second deadline.

This is applied only to a stack that offers fingerprint and nothing else,
which on Ubuntu and Debian means `gdm-fingerprint`, and the file is backed up
first. Stacks that the rewrite cannot reproduce faithfully are refused rather
than guessed at: a `sufficient` fingerprint line, a numeric jump above it, or
an extra auth module. Shared stacks such as `common-auth` are never touched.
`uninstall.sh` only reverts a file it can prove it wrote, and says so when it
cannot.

The measurements and the `pam_fprintd` source reading behind all of this are
in [`JOURNAL.md`](JOURNAL.md).

One thing to expect: `/etc/pam.d/gdm-fingerprint` belongs to the `gdm`
package, so an upgrade can restore the distro's version. Re-run `install.sh`
if dropouts come back.

## Fingerprint for `sudo`

This is a separate setting that the tool does not change for you:

```bash
sudo pam-auth-update --enable fprintd
```

Re-run `install.sh` afterwards. Enabling fingerprint system-wide means
`gdm-password` can now succeed via fingerprint too, which reopens the same gap
on a service that is not named after fingerprints.

It also costs you something. The same profile puts `pam_fprintd.so` into
`common-auth`, and at the greeter that stack races `gdm-fingerprint` for the
sensor and wins, with a single attempt on a 10-second timeout. Fingerprint for
`sudo` and polkit, and a retrying fingerprint prompt at the lock screen, are
therefore mutually exclusive. `install.sh` detects the conflict, explains it,
lists which services would lose fingerprint on your machine, and offers to
disable the profile:

```bash
sudo pam-auth-update --disable fprintd     # what the installer runs
sudo pam-auth-update --enable fprintd      # undo, any time
```

`sudo` itself keeps fingerprint either way, because Ubuntu's `/etc/pam.d/sudo`
carries its own line. polkit prompts, `login` and `su` fall back to the
password they already accept.

## Shared machines

The TPM primary key is one shared object at a fixed handle (`0x81018000`), and
it is the same key for every user. Evicting it, or removing the PAM module and
the helper, therefore affects the whole machine. `uninstall.sh` looks for
other users' sealed secrets first, names who would be affected, and either
refuses or defaults to no instead of breaking someone else's login.

Sharing the key does not mean sharing the secrets. Each user's blob lives in
their own `0700` directory, and the helper refuses to unseal one that is not
owned by the account being authenticated. It verifies this through file
descriptors it has already opened, so pointing a data directory at someone
else's does not work even if the swap happens mid-login.

## Uninstall

```bash
./uninstall.sh
```

Reverses each step, asking before each one. Your keyring password itself is
never changed by this tool, so there is nothing to restore there.

## Troubleshooting

- **Still prompted after install.** Find which service handled your login with
  `journalctl -b 0 | grep gkr-pam`. The name in brackets tells you which
  `/etc/pam.d/` file needs patching. Re-run `install.sh` and it will offer.
- **Broke after a reboot, nothing else changed.** Check `journalctl -b 0 |
  grep -i tpm`, then run
  `sudo /usr/local/sbin/tpm-keyring-unseal $USER >/dev/null; echo $?`. A
  non-zero exit usually means PCR7 changed because a Secure Boot setting
  moved. Re-run `bin/seal.sh`.
- **Broke after `pam-auth-update --enable fprintd`.** See "Fingerprint for
  sudo" above, then re-run `install.sh`.
- **Login pauses for several seconds, but auto-unlock works.** You are on the
  slow TPM path, either because the secret was sealed before the fast path
  existed, or because another user's uninstall evicted the shared primary. The
  journal says which. Either way, run `bin/seal.sh` and choose Overwrite with
  the same password.
- **"Can't determine the Secure Boot state."** Install `mokutil`, or confirm
  Secure Boot is on some other way, then re-run.
- **Anything deeper.** [`JOURNAL.md`](JOURNAL.md) is the full investigation
  log, including bugs found after this README was written and how each one was
  root-caused.

## Compatibility

Built and verified on one real machine: Ubuntu, GNOME, GDM, systemd, TPM 2.0,
Secure Boot on, no disk encryption.

Should work, in the sense that the logic handles it but it has not been run
there: any GNOME distro using `gnome-keyring` such as Fedora, Debian or
Pop!_OS; other display managers, provided `gnome-keyring` really backs your
secrets, since detection matches by file content rather than filename; apt,
dnf, pacman and zypper; x86_64 and aarch64. Arch has no `sg`, so you log out
and back in once during install.

Will not work: KDE with KWallet, which is a different secrets service
entirely; machines without TPM 2.0; Secure Boot off; a non-systemd init. The
installer checks for these and exits cleanly rather than half-working.

Untested: any TPM other than this machine's fTPM and the VM's software TPM,
and any real graphical fingerprint login, since the test VM is headless. If
something breaks for you there, it is a bug report rather than an unsupported
configuration. Please open an issue.

For what the automated tests do cover, including a real `swtpm` and OVMF VM,
see [`test/README.md`](test/README.md) and
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

If you find a way to reach a secret you should not be able to, see
[`SECURITY.md`](SECURITY.md). Private reporting is enabled.

## License

MIT, see [LICENSE](LICENSE).

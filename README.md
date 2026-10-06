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

- TPM 2.0 with `/dev/tpmrm0`. The unseal at login always goes through it,
  the kernel's own resource manager, and never through `tpm2-abrmd`.
- Secure Boot enabled. PCR7 is meaningless as a lock otherwise.
- systemd, and `gnome-keyring` as your actual secrets backend
- `tpm2-tools`, a C compiler, and PAM headers. The installer offers to fetch
  these on apt, dnf, pacman and zypper.

On SELinux systems such as Fedora, the installer also loads a one-rule policy
module so that GDM's logins can reach the TPM. See [SELinux](#selinux) for
what that gives up.

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

After upgrading the package, run `tpm-keyring-unlock-configure` once more. It
re-checks the PAM stacks an older version wired, and takes the helper back out
of any that the current checks refuse. Answer `n` at "Overwrite?" to keep your
sealed secret.

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
it system-wide.

Fedora's `gdm-fingerprint` has no keyring line at all: a finger never yields
a password, so GDM's Red Hat stacks leave the keyring out. For that one file
`install.sh` adds the keyring lines, with the module between them. The auth
lines go after the stack's last auth line, so nothing in the file runs after
the module. The session line goes where Fedora's own `gdm-password` has its
own, ahead of `postlogin`:

```
auth        include       postlogin
auth    optional        pam_tpm_keyring_authtok.so       <- added by this tool
auth    [default=ignore] pam_gnome_keyring.so             <- added by this tool
...
session     include       fingerprint-auth
session [default=ignore] pam_gnome_keyring.so auto_start  <- added by this tool
session     include       postlogin
```

None of the three can vote, so the stack lets in exactly whom it let in
before. That is why the keyring lines say `[default=ignore]` where
`gdm-password` says `optional`: `pam_gnome_keyring` reports success even
when it has no password to work with, and in a stack where nothing else has
voted, `optional` counts that success as a login. The installer also refuses
the file when a jump in it (`[success=1 ...]`) would reach the new lines,
because a jump counts every line it passes.

`uninstall.sh` takes all three back out by restoring the copy `install.sh`
took right before adding them. That copy is the only proof the lines are this
tool's: the same lines written by hand look identical. Without it, only the
module's own line comes out, and `uninstall.sh` says so.

Before it patches a stack, it checks everything that runs *after* the new
line. That covers the lines below the keyring line, whatever they include
(into `/usr/lib/pam.d` as well), and whatever follows the include in any
other service that includes the stack. Only a short list of vetted modules may
appear there: ones that never turn the token into a login, such as
`pam_permit`, `pam_nologin`, `pam_env`, `pam_fprintd`, `pam_gnome_keyring` and
`pam_kwallet5`. The full list, and why each module is on it, is in
`bin/lib.sh`. Anything else means the stack is not patched:

- an unknown module;
- a line the tool does not read the way libpam does;
- an include it cannot find;
- a continuation that different libpam versions read differently.

The installer prints the reason. Logins there work as before, but the keyring
stays locked until you type its password. The stacks GDM and LightDM ship on
Ubuntu, Debian, Fedora and Arch all pass. A stack wired by an earlier run is
checked again on every run, and the helper is taken back out of it if it no
longer passes, or if its keyring line has gone.

The installer edits `/etc/pam.d` only. A keyring stack, or `gdm-fingerprint`,
that libpam reads from the distribution's own `/usr/lib/pam.d` is listed with
the reason rather than edited. To have it wired, copy it over and re-run:

```bash
sudo cp /usr/lib/pam.d/gdm-fingerprint /etc/pam.d/gdm-fingerprint
```

The copy then replaces the vendor file for good, and updates to the vendor
file stop reaching you until you delete it. That trade is why the installer
leaves the step to you.

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
sensor and wins, with a single attempt on a 10-second timeout. As long as
`sudo` and polkit get fingerprint from that profile, fingerprint for them and
a retrying fingerprint prompt at the lock screen are mutually exclusive.
`install.sh` detects the conflict, explains it, lists which services would
lose fingerprint on your machine, and offers to disable the profile:

```bash
sudo pam-auth-update --disable fprintd     # what the installer runs
sudo pam-auth-update --enable fprintd      # undo, any time
```

On a stock Ubuntu or Debian that includes `sudo`: `/etc/pam.d/sudo` has no
fingerprint line of its own and gets one only through `common-auth`. polkit
prompts, `login` and `su` go the same way, back to the password they already
accept. The installer works out which services lose it from your files,
`/usr/lib/pam.d` included, which is where Ubuntu 26.04 keeps polkit's, and
names `sudo` and polkit in the question when they are among them.

### Keeping fingerprint for `sudo` and polkit anyway

You can give `sudo` and polkit a fingerprint line of their own, so they stop
depending on the profile. The tool does not do this for you. With
`sufficient`, a finger alone is enough to become root, and whether that is
acceptable on your machine is your call, not an installer's. A mistake in
these files can lock you out of `sudo`, so keep a root shell open until you
have tested.

1. Disable the profile, which is what `install.sh` offers anyway.
2. In `/etc/pam.d/sudo`, directly above `@include common-auth`, add:

   ```
   auth    sufficient    pam_fprintd.so
   ```

   `sudo -i` reads `/etc/pam.d/sudo-i` instead. Give it the same line if you
   use it.
3. For polkit, add the same line above the `@include common-auth` in
   `/etc/pam.d/polkit-1`. Where polkit ships its file in `/usr/lib/pam.d`
   instead (Ubuntu 24.04 and later, Debian 12), copy it over first. The copy
   in `/etc/pam.d` then replaces the vendor file. The command leaves an
   existing `/etc/pam.d/polkit-1` alone:

   ```bash
   [ -e /etc/pam.d/polkit-1 ] || sudo cp /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
   ```

4. Test with `sudo -k; sudo true` and with `pkexec true` or any polkit
   dialog. Both should ask for a finger.

A few things come with it:

- `/etc/pam.d/sudo` is a package configuration file, so a `sudo` upgrade that
  changes it will ask which version to keep.
- A copied `/etc/pam.d/polkit-1` replaces the vendor file for good. polkit
  updates to `/usr/lib/pam.d/polkit-1` stop reaching you until you delete the
  copy.
- If the profile comes back later (from GNOME Settings, `pam-auth-update` or
  `uninstall.sh`), `sudo` and polkit try the reader twice before the password:
  their own line first, then the one in `common-auth`. `uninstall.sh` names
  the services this applies to before it asks.

To undo, remove the line you added from each file. Delete
`/etc/pam.d/polkit-1` only if step 3 created it as a copy. On releases that
ship that file themselves, such as Ubuntu 22.04, it belongs to the package,
and deleting it loses it for good. Re-enable the profile afterwards if you want
it back.

`gdm-password` stays password-only this way, so the gap described above stays
closed.

## SELinux

GDM runs its PAM stacks in the SELinux domain `xdm_t`, and so does the
helper this tool's module starts there. Fedora's policy does not let `xdm_t`
open the TPM, so without a change every fingerprint login and unlock fails to
unseal, and the keyring stays locked. Password logins are unaffected: the
typed password reaches the keyring, and the helper never runs. The journal
shows it under `gdm-session-worker`:

```
tpm-keyring-unseal: cannot open /dev/tpmrm0 (Permission denied) as system_u:system_r:xdm_t:s0-s0:c0.c1023.
```

and `sudo ausearch -m avc -c tpm2_load` shows the denial on `tpm_device_t`.

`install.sh` checks the loaded policy for this and, when it is so, plans
loading [`selinux/tpm_keyring_unlock.cil`](selinux/tpm_keyring_unlock.cil),
which is one rule:

```
(allow xdm_t tpm_device_t (chr_file (open read write)))
```

It is the run's last step, taken only once a stack is wired, so a run that
stops early or wires nothing leaves the policy as it was. `uninstall.sh`
offers to remove it again, and removing the distribution package removes it
too. By hand: `sudo semodule -r tpm_keyring_unlock`.

The check needs no root, but the kernel answers it only for a login allowed
to ask (`security { compute_av }`), and a confined login may not be. The
installer then says it could not check. To check by hand, `sesearch -A -s
xdm_t -t tpm_device_t -c chr_file -p open` (from `setools-console`) prints
nothing when the access is missing. The journal line above shows the same
after a fingerprint login.

**What it gives up.** The rule is for all of `xdm_t`, not only the helper:
every process GDM runs as root may now open the TPM. File permissions still
keep the greeter out, since it runs as the `gdm` user and `/dev/tpmrm0` is
`root:tss 0660`. A compromised GDM root process could already read every
user's home and every password typed at the greeter. What the rule adds is
that it can also send the TPM commands of its choosing.

**Why not a narrower domain.** One for the helper alone would keep the TPM
away from the rest of GDM. But the helper is a shell script that runs
`tpm2-tools`, `getent` and coreutils, so its policy would need dozens of
rules that only a real Fedora login exercises, and every missing one fails
at login without a word. A compromised GDM could also still run the helper
with an environment of its choosing. That domain belongs in Fedora's own
policy, if anywhere.

Other display managers Fedora packages run as `xdm_t` too. A stack outside
them, such as `login` on a console, runs in a different domain and would
need its own rule. Fedora's console `login` has no keyring line, so
`install.sh` never wires it.

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
- **Fedora, or anything with SELinux enforcing.** Under GDM the helper's own
  messages go to the journal as `gdm-session-worker`:
  `journalctl -b -t gdm-session-worker | grep tpm-keyring-unseal`. If one
  says it cannot open `/dev/tpmrm0` as `xdm_t`, the policy module is not
  loaded. Re-run `install.sh`, or see [SELinux](#selinux).
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

Fedora 44 with SELinux enforcing is covered by a VM test,
`make test-vm-selinux`. It runs the installer against Fedora's own gdm and
authselect stacks, and runs `gdm-fingerprint` from GDM's SELinux domain, with
a stand-in for the fingerprint reader. A Fedora 44 laptop was made to work by
hand with the same two changes before the installer made them (GitHub issue
#23).

Should work, in the sense that the logic handles it but it has not been run
there: any GNOME distro using `gnome-keyring` such as Debian or
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

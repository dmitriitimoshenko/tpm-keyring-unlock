# tpm-keyring-unlock

[![test](https://github.com/dmitriitimoshenko/tpm-keyring-unlock/actions/workflows/test.yml/badge.svg)](https://github.com/dmitriitimoshenko/tpm-keyring-unlock/actions/workflows/test.yml)

You log in with your fingerprint, and GNOME still asks for a password the
first time something needs a saved secret. This fixes that — without blanking
the keyring password and without leaving it in a file.

The password goes into the TPM instead, sealed to this machine's Secure Boot
state, and PAM unseals it at login.

## Is this for you?

**Yes, if** your disk is *not* encrypted, you use GNOME keyring, and
fingerprint login already works.

**No, if** your disk is encrypted. The keyring password is then mostly
duplicating protection you already have — blank it and you're done. This tool
would add nothing.

You also need, and `install.sh` refuses to continue without:

- TPM 2.0 with `/dev/tpmrm0`
- Secure Boot **on** (PCR7 is meaningless as a lock otherwise)
- systemd, and `gnome-keyring` as your actual secrets backend
- `tpm2-tools`, a C compiler, PAM headers — the installer offers to fetch
  these on apt / dnf / pacman / zypper

## Install

```bash
git clone https://github.com/dmitriitimoshenko/tpm-keyring-unlock.git
cd tpm-keyring-unlock
./install.sh
```

It prints the whole plan first — packages, group change, the exact PAM diffs,
each file backed up — and asks once before touching anything. Enter accepts.
Without a terminal it refuses to run rather than answering itself.

Then seal your keyring password:

```bash
bin/seal.sh
```

Typed interactively, never written to disk unencrypted, never passed as an
argument.

Log out and back in to test.

## Threat model, honestly

Read this before trusting it with anything.

**Protected: the disk comes out and gets read somewhere else.** The sealed
blob is ciphertext bound to this machine's TPM and its PCR7 state. Neither
travels with the disk.

**Not protected: the whole machine is taken.** PCR7 measures the Secure Boot
state — which keys are enrolled, which certificate vouched for what loaded.
It does *not* measure the kernel, the initrd, or the kernel command line, and
the policy has no password on it, because unsealing has to happen at login
without asking anyone anything.

So someone holding your laptop can pick your own installed system in GRUB,
add `init=/bin/bash`, and boot to a root shell: same bootloader, same
signatures, same PCR7, and the TPM unseals for them exactly as it does for
you. That distro's own install media gets to the same place. Your disk isn't
encrypted — that was the premise — so the sealed file is right there too.

**The honest framing is narrow: this replaces a keyring password kept in a
plaintext file, not full-disk encryption.** If "someone walks off with the
laptop" is in your threat model, use FDE — at which point you don't need this.

Two more things, stated plainly:

- **Anyone with your running, logged-in machine** (root, or you) can read the
  unsealed value the same way this tool does. That's inherent to "unlock
  without asking," not specific to this approach.
- **A failed fingerprint attempt still triggers an unseal.** libpam keeps
  walking the stack after the distro's `required` fingerprint line fails, so
  the module below it runs anyway. The login still fails and the token is
  discarded, but someone at your lock screen can make the TPM do an unseal by
  touching the sensor. That predates this tool; the seal is bound to the
  machine's state, not to who's standing there.

Binding more PCRs (4, 8, 9) would narrow the gap and is deliberately not done
— it would mean re-sealing after every kernel and bootloader update, to
half-cover what FDE covers properly.

If your Secure Boot settings ever change, PCR7 changes and the seal breaks.
Re-run `bin/seal.sh`. Routine kernel and driver updates don't affect it.

## How it works

Two separate things had to be fixed.

**1. A systemd/PAM race that breaks keyring auto-unlock for everyone**,
password logins included, on distros that pre-start
`gnome-keyring-daemon.service`. The daemon is already running by the time PAM
tries to unlock it, so PAM spawns a second, disconnected one instead. Masking
the unit fixes it.

> If you're getting the keyring prompt even with **password** logins, this
> alone may be your whole fix — try it before anything else:
>
> ```bash
> systemctl --user mask gnome-keyring-daemon.socket gnome-keyring-daemon.service
> ```

**2. Fingerprint auth never sets `PAM_AUTHTOK`**, so `pam_gnome_keyring.so`
has nothing to work with. A small PAM module unseals the password and sets it,
purely so the next module can use it:

```
auth	required	pam_fprintd.so
auth    optional        pam_tpm_keyring_authtok.so   <- added by this tool
auth    optional        pam_gnome_keyring.so         <- already there
```

It is always `auth optional` and always returns `PAM_IGNORE` — it cannot grant
or deny a login under any circumstances, including its own failure. If a real
password was typed, it does nothing.

This isn't only about services named `*fingerprint*`. `install.sh` patches
every `/etc/pam.d/` service with an auth-phase `pam_gnome_keyring.so` line,
because `gdm-password` can succeed via fingerprint too the moment you enable
it system-wide. It refuses to patch a stack where a password module runs
*below* the insertion point, which would let a token nobody typed authenticate
a login.

## The fingerprint reader dropping out mid-prompt

Separate problem; `install.sh` offers to fix it while it's there.

One badly angled scan, or 30 seconds of not touching the sensor, and
fingerprint disappears for the rest of the lock screen — the sensor sitting
there working. `pam_fprintd` returns "no such auth method here", and
gnome-shell treats that as permanent. `max-tries=` does not help: it only
counts clean mismatches.

PAM has no loop, so the fix is to invoke the module three times:

```
auth  [success=2 …]  pam_fprintd.so max-tries=1
auth  [success=1 …]  pam_fprintd.so max-tries=1
auth  required       pam_fprintd.so max-tries=1
```

**One line is one scan, so whatever goes wrong costs exactly one attempt** —
mismatch, bad scan, timeout, all the same. Three attempts total, which is what
the module's own default allowed anyway; only *which* failures count has
changed. Each keeps its own 30s deadline.

Applied only to a stack that offers fingerprint and nothing else
(`gdm-fingerprint` on Ubuntu/Debian), backed up first. Stacks it can't
reproduce faithfully — a `sufficient` fingerprint line, a numeric jump above
it, an extra auth module — are refused rather than guessed at, and shared
stacks like `common-auth` are never touched. `uninstall.sh` only reverts a
file it can prove it wrote, and says so when it can't.

Full reasoning, measurements and the `pam_fprintd` source archaeology are in
[`JOURNAL.md`](JOURNAL.md).

Worth knowing: `/etc/pam.d/gdm-fingerprint` belongs to the `gdm` package, so
an upgrade can restore its version. Re-run `install.sh` if dropouts come back.

## Also want fingerprint for `sudo`?

That's separate and not this tool's doing:

```bash
sudo pam-auth-update --enable fprintd
```

Re-run `install.sh` afterwards — enabling it system-wide means `gdm-password`
can now succeed via fingerprint too, which reopens the same gap on a service
not named after fingerprints.

**There's a trade-off.** The same profile puts `pam_fprintd.so` into
`common-auth`, and at the greeter that stack races `gdm-fingerprint` for the
sensor — and wins, with a single attempt on a 10s timeout. So fingerprint for
`sudo`/polkit and a retrying fingerprint prompt at the lock screen are
mutually exclusive as things stand. `install.sh` detects the conflict,
explains it, lists exactly which services would lose fingerprint on *your*
machine, and offers to disable the profile:

```bash
sudo pam-auth-update --disable fprintd     # what the installer runs
sudo pam-auth-update --enable fprintd      # undo, any time
```

`sudo` itself keeps fingerprint either way — Ubuntu's `/etc/pam.d/sudo` has
its own line. polkit prompts, `login` and `su` fall back to the password they
already accept.

## More than one person on this machine?

The TPM primary key is **one shared object** at a fixed handle
(`0x81018000`) — the same key for everyone by construction. So evicting it, or
removing the PAM module and helper, is a machine-wide act. `uninstall.sh`
checks for other users' sealed secrets first, names who's affected, and
refuses (or defaults to no) rather than quietly breaking someone else's login.

**Sharing the key does not mean sharing the secrets.** Each user's blob lives
in their own `0700` directory, and the helper refuses to unseal one that isn't
owned by the account being authenticated — verified through file descriptors
it has already opened, so pointing a data directory at someone else's doesn't
work even if the swap happens mid-login.

## Uninstall

```bash
./uninstall.sh
```

Reverses each step, asking before each one. Your actual keyring password is
never changed by this tool, so there's nothing to restore there.

## Troubleshooting

- **Still prompted after install.** Find which service handled your login:
  `journalctl -b 0 | grep gkr-pam`. The name in brackets tells you which
  `/etc/pam.d/` file needs patching — re-run `install.sh`, it'll offer.
- **Broke after a reboot, nothing else changed.** `journalctl -b 0 | grep -i tpm`,
  then `sudo /usr/local/sbin/tpm-keyring-unseal $USER >/dev/null; echo $?`.
  Non-zero usually means PCR7 changed (a Secure Boot setting moved) — re-run
  `bin/seal.sh`.
- **Broke after `pam-auth-update --enable fprintd`.** See "Also want
  fingerprint for sudo" above — re-run `install.sh`.
- **Login pauses for several seconds, but auto-unlock works.** You're on the
  slow TPM path: either a secret sealed before the fast path existed, or the
  shared primary was evicted by someone else's uninstall (the journal says so
  explicitly). Fix for both: `bin/seal.sh`, choose Overwrite, same password.
- **"Can't determine the Secure Boot state."** Install `mokutil`, or confirm
  Secure Boot is on another way, then re-run.
- **Anything deeper:** [`JOURNAL.md`](JOURNAL.md) is the full, warts-and-all
  investigation log — including bugs found after this README was written and
  exactly how they were root-caused.

## Compatibility

Built and verified on one real machine: Ubuntu, GNOME, GDM, systemd, TPM 2.0,
Secure Boot on, no disk encryption.

**Should work** — the logic handles it, but it hasn't been run there: any
GNOME distro with `gnome-keyring` (Fedora, Debian, Pop!_OS…), other display
managers if `gnome-keyring` really backs your secrets (detection matches by
file *content*, not filename), apt/dnf/pacman/zypper, x86_64 and aarch64.
Arch has one rough edge: no `sg`, so you log out and back in once mid-install.

**Won't work:** KDE with KWallet (different secrets service entirely), no
TPM 2.0, Secure Boot off, non-systemd init. The installer checks and exits
cleanly rather than half-working.

**Genuinely untested:** any TPM other than this machine's fTPM and the VM's
software TPM, and any real graphical fingerprint login (the test VM is
headless). If you hit something broken there, that's a real bug report —
please open an issue.

What *is* covered by automated tests, including a real `swtpm` + OVMF VM:
see [`test/README.md`](test/README.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

Found a way to get at a secret you shouldn't? See [`SECURITY.md`](SECURITY.md)
— private reporting is enabled.

## License

MIT — see [LICENSE](LICENSE).

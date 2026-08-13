# tpm-keyring-unlock

Auto-unlock the GNOME login keyring on fingerprint login, without weakening
it — the keyring stays password-protected; the password is sealed inside
the TPM instead of typed by hand.

## Install

```bash
git clone https://github.com/dmitriitimoshenko/tpm-keyring-unlock.git
cd tpm-keyring-unlock
./install.sh
```

Walks through, with a confirmation before the one step that touches a
login-critical file: installing dependencies, adding you to the `tss` group
(needed for passwordless TPM access — requires a relogin partway through),
masking the systemd race, compiling and installing the PAM module, sealing
your password (typed interactively, never touches disk unencrypted, never
passed as a command-line argument), and finally — with an explicit
confirmation and an automatic backup of the file it touches — inserting the
one PAM line. See Requirements below before running it.

## The problem

GNOME's login keyring is encrypted with your password. Fingerprint auth
(`fprintd`/`libpam-fprintd`) only ever answers yes/no — it never produces
the password the keyring needs, so logging in with a fingerprint leaves the
keyring locked. The first app that needs a saved secret (Wi-Fi password,
browser-saved password, a token) triggers a manual "Authentication
required" password prompt.

The two obvious fixes are both bad:
- **Blank the keyring password.** Removes the prompt, but also removes the
  only thing protecting saved secrets if your disk isn't encrypted.
- **Store the real password in a plain file and feed it in at login.**
  Same problem as above — a plaintext password file gives zero additional
  protection over no password at all.

## The fix

Seal the real keyring password inside the TPM, bound to a PCR7 policy (the
Secure Boot state). The sealed blob is useless anywhere except this exact
machine, in this exact Secure Boot state — pull the disk and it's just
ciphertext. On this machine, in its current state, it can be unsealed
automatically and fed into the normal keyring-unlock path, whether you
logged in with a password or a fingerprint.

This only makes sense if your disk isn't already full-disk-encrypted (if it
is, the keyring password mostly duplicates protection you already have from
disk encryption, and you may as well just blank it).

## How it works

Two independent things had to be fixed:

**1. A systemd/PAM race that breaks keyring auto-unlock for *everyone*,
password login included, on distros that pre-start
`gnome-keyring-daemon.service` via `graphical-session-pre.target`.**
That unit starts the daemon before login/PAM runs. By the time PAM's own
keyring-unlock logic (`pam_gnome_keyring.so`) tries to create/unlock the
daemon with your password, the systemd-started instance already owns the
D-Bus name and control socket — PAM's attempt just spins up a second,
disconnected daemon instead of unlocking the real one. Masking the unit
(`systemctl --user mask gnome-keyring-daemon.socket
gnome-keyring-daemon.service`) stops the race: PAM's own spawn becomes the
only daemon there ever is. On its own, this already fixes password-login
auto-unlock. **If you're hitting the keyring-unlock prompt even with
password logins, this alone might be your whole fix — try it before the
fingerprint-specific pieces below.**

**2. Fingerprint auth never sets `PAM_AUTHTOK`, so even with the race
fixed, `pam_gnome_keyring.so` has nothing to stash.**
A small PAM module (`pam/pam_tpm_keyring_authtok.c`) sits right before
`pam_gnome_keyring.so` in every login PAM stack that has one. It unseals
the TPM-sealed password (via a root-owned helper script) and sets it as
`PAM_AUTHTOK`, purely so the next module can use it. It is always `auth
optional` and always returns `PAM_IGNORE` — it cannot grant or deny login
by itself under any circumstances, including its own failure. If
`PAM_AUTHTOK` is already set (a real password was typed), it does nothing.
Whatever module actually authenticated you (`pam_fprintd.so`, `pam_unix.so`
via a typed password, etc.) remains the sole thing deciding whether login
succeeds.

```
auth	required	pam_fprintd.so
auth    optional        pam_tpm_keyring_authtok.so   <- added by this tool
auth    optional        pam_gnome_keyring.so          <- already there by default
```

**This isn't only about a service literally named `*fingerprint*`.** Any
login PAM stack that includes `pam_gnome_keyring.so` in its auth phase
needs this module if it can *ever* succeed via something other than a
typed password — including `gdm-password` itself, the moment you enable
fingerprint system-wide with `pam-auth-update --enable fprintd` (which
adds `pam_fprintd.so` to `common-auth`, included by `gdm-password` too).
`install.sh` accounts for this: it patches every `/etc/pam.d/` service file
with an auth-phase `pam_gnome_keyring.so` line, not just ones with
"fingerprint" in the filename.

## Also want fingerprint for `sudo` / installing software?

That's a separate, independent thing — not specific to this tool — and the
officially supported way to do it is:

```bash
sudo pam-auth-update --enable fprintd
```

This is a maintainer-shipped profile (`/usr/share/pam-configs/fprintd` on
Debian/Ubuntu) that adds fingerprint as the first auth method system-wide,
with automatic fallback to your password if it fails or times out. It's
what makes `sudo` in a terminal, and polkit-gated GUI prompts (installing a
snap from Ubuntu's App Center, GNOME Software, etc.), accept a fingerprint.

If you use this, run (or re-run) `install.sh` afterward. Enabling
system-wide fingerprint auth means your regular password login screen
(`gdm-password`) can now also succeed via fingerprint, not just a dedicated
fingerprint option — which reopens the exact `PAM_AUTHTOK` gap described
above, on a service that isn't named after fingerprints at all.
`install.sh` looks for every `/etc/pam.d/` service with an auth-phase
`pam_gnome_keyring.so` line and patches all of them for exactly this
reason.

## Requirements

Hard requirements — the tool refuses to proceed without these, they're not
optional:

- TPM 2.0 with a resource-manager device (`/dev/tpmrm0`)
- Secure Boot enabled (PCR7 is meaningless as a lock if Secure Boot is off)
- `gnome-keyring` as your actual secrets backend, with fingerprint login
  already set up and working (`fprintd`/`libpam-fprintd`, enrolled
  fingerprint) — this tool doesn't set fingerprint auth up, it only fixes
  what happens to the keyring once fingerprint auth already works
- `tpm2-tools`, a C compiler, and PAM development headers — `install.sh`
  offers to install these itself on apt/dnf/pacman/zypper systems (see
  Compatibility below for other package managers)
- systemd as your init/session manager (for the `systemctl --user mask`
  step — see "How it works" part 1)

## Compatibility

Everything in this repo was built against, and is directly verified on,
one real machine: Ubuntu, GNOME, GDM, systemd, TPM 2.0, Secure Boot on, no
disk encryption (see `JOURNAL.md` for the actual test log). Past that,
here's an honest breakdown of what the code does and doesn't account for
— "should work" below means the logic handles it, not that it's been
run there:

**Should work, same as the tested setup:**
- Any GNOME-based distro using `gnome-keyring` + GDM (Fedora Workstation,
  Debian, Pop!_OS, etc.) — `install.sh`'s PAM-file detection matches by
  *content* (any `/etc/pam.d/` service with an auth-phase
  `pam_gnome_keyring.so` line), not by filename, so it isn't GDM-specific
  by construction.
- Other display managers (LightDM, SDDM, ...) *if* `gnome-keyring` is what
  actually backs your secrets — same reasoning, detection is content-based.
- `apt`, `dnf`, `pacman`, and `zypper` systems for the dependency-install
  step.
- `x86_64` and `aarch64` machines for PAM module install-path detection.

**Won't work, by design or by architecture mismatch:**
- **KDE Plasma with KWallet.** Different secrets service entirely, not
  `gnome-keyring` — this tool has nothing to attach to. (KDE running
  `gnome-keyring` instead of KWallet is a different story and should fall
  under "should work" above.)
- No TPM 2.0, or Secure Boot off, or a non-systemd init — hard requirements
  above, `install.sh` checks and exits cleanly rather than doing something
  half-working.
- Any other package manager (e.g. `apk` on Alpine) — dependency
  auto-install isn't wired up; install `tpm2-tools`/a C compiler/PAM
  headers yourself first, the rest of `install.sh` doesn't care how they
  got there.

**Untested, logic present but not exercised on real hardware:** `dnf`/
`pacman`/`zypper` dependency install, `aarch64` PAM paths, any non-GDM
display manager. If you hit something broken on one of these, that's a
real bug report, not a "this was never claimed to work" situation — please
open an issue.

## Uninstall

```bash
./uninstall.sh
```

Reverses each step. Your actual GNOME keyring password is never changed by
this tool, so there's nothing to restore there.

## Threat model, honestly

What this protects against: someone getting hold of your powered-off laptop
and pulling the disk. The sealed secret is worthless off this TPM.

What this does **not** protect against: anyone with control of your running,
logged-in machine (root, or you) can read the sealed secret's decrypted
value the same way this tool does — that's inherent to "unlock
automatically without asking," not a bug specific to this approach.

If your BIOS Secure Boot settings ever change (enabled/disabled, keys
reset), PCR7 changes and the seal breaks — you'll need to re-run
`bin/seal.sh`. Routine kernel/driver updates do not affect PCR7 and won't
break it.

## Troubleshooting

- **Still prompted after install.** Check which PAM service actually
  handled your login: `journalctl -b 0 | grep gkr-pam`. The service name in
  brackets (e.g. `gdm-password][1234]`) tells you which `/etc/pam.d/` file
  needs the patch — re-run `install.sh`, it'll find and offer to patch any
  service it missed.
- **Worked, then broke after a reboot, and you didn't change anything
  PAM-related.** Check `journalctl -b 0 | grep -i tpm` and try `sudo
  /usr/local/sbin/tpm-keyring-unseal $USER >/dev/null; echo $?` — a
  non-zero exit usually means the TPM's PCR7 changed (a Secure Boot
  setting changed) and the seal needs redoing: `bin/seal.sh`.
- **Worked, then broke after enabling `pam-auth-update --enable
  fprintd`.** See "Also want fingerprint for sudo" above — re-run
  `install.sh`.
- Diagnosing anything deeper: `JOURNAL.md` in this repo is the full,
  warts-and-all investigation log this tool came out of, including two
  regressions found after this README was first written and exactly how
  they were root-caused. If you hit something not covered above, it's
  worth a skim.

## License

MIT — see [LICENSE](LICENSE).

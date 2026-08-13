# tpm-keyring-unlock — journal

A running log of decisions, dead ends, root causes, and why things are built
the way they are. Not a tutorial — a record, kept so anyone (human or agent)
picking this project back up doesn't have to re-derive what's already been
learned. See `CLAUDE.md` for the rule that keeps this updated going forward.

Reference machine this was built and tested against: Ubuntu laptop, AMD
Ryzen AI 300 series (kernel 7.0.0-29-generic), AMD GPU gfx1152, Secure Boot
enabled, **disk is NOT LUKS-encrypted**.

## Goal

Currently GNOME keyring (login keyring) does not auto-unlock when logging in via
fingerprint (fprintd only returns pass/fail, it never produces the password-derived
key the keyring needs), so an "Authentication required" popup asks for the keyring
password by hand.

Wanted: keep the keyring password-protected (don't blank it), but have it unlock
automatically regardless of whether the session was started via password or via
fingerprint.

## Options considered, and why we rejected the first two

1. **Blank the keyring password entirely.** Works, zero prompts, but removes the
   only encryption layer protecting saved secrets (wifi passwords, browser-saved
   passwords, tokens) — and disk is unencrypted, so this is the *only* layer they
   have. Rejected as too weak given the threat model.

2. **Store the real keyring password in a plain file, auto-feed it to
   `gnome-keyring-daemon --unlock` at session start.** Works technically, but
   correctly called out as pointless ("schizophrenia"): a plaintext password file
   on an unencrypted disk gives *zero* additional protection over option 1 — anyone
   who can read the disk reads the password. Rejected.

3. **Seal the real keyring password inside the TPM, bound to a PCR policy, unseal
   automatically at session start.** This is the one being implemented. The
   difference from option 2: the sealed blob is useless off this machine — the TPM
   will only unseal it while running on this exact physical chip AND while the
   measured platform state (PCR) matches what it was sealed against. Stealing the
   disk gets you an undecryptable blob, not a password.

## Design

- Bind the seal to **PCR7** (Secure Boot policy state) rather than boot-chain PCRs
  (0/2/4/8/etc.) — PCR7 does *not* change on kernel/initrd updates, only on actual
  Secure Boot configuration changes (enabling/disabling SB, changing PK/KEK/db/dbx).
  This is the same PCR `systemd-cryptenroll --tpm2-device=auto` recommends for LUKS
  auto-unlock, for the same reason (survives normal `apt upgrade` of the kernel).
  Consequence: if Secure Boot settings are ever changed in BIOS, the seal breaks and
  the password needs re-sealing (step 3 below, redone).
- Sealed blob lives under `~/.local/share/tpm-keyring-unlock/` (not `/etc` — no need
  for root ownership, the TPM policy is the actual protection, not file permissions).
- User needs to be in the `tss` group to talk to `/dev/tpmrm0` without sudo, so the
  unseal-at-login step can run unattended from an autostart entry (no password
  prompt defeating the whole point).
- Unlock mechanism: `tpm2_unseal` prints the plaintext password to stdout, piped
  directly into `gnome-keyring-daemon --unlock` (which reads the password on stdin).
  Runs from a `~/.config/autostart/*.desktop` entry so it fires on every session
  start, independent of whether login used password or fingerprint.
- Note this doesn't literally hook the *fingerprint touch* to the unlock — it hooks
  *session start* to the unlock, which happens to satisfy the actual requirement
  ("no manual prompt regardless of login method") without needing PAM-stack surgery
  (pam_exec can't inject PAM_AUTHTOK for a downstream module to consume, so directly
  chaining fprintd → keyring auth isn't practical).

## Manual test log

Trying this by hand first, in the real terminal, before packaging into
install scripts — so this section is the running log.

- [x] Confirm TPM 2.0 present and resource manager device exists (`/dev/tpmrm0`)
- [x] Confirm/add `tss` group membership (needed a relogin/reboot to take effect
      on the session — group was granted via `usermod -aG tss $USER` but didn't
      apply until the desktop session restarted)
- [x] `tpm2-tools` installed
- [x] Seal test password into TPM (PCR7 policy) — sealed `test-secret-123` as a
      throwaway value, purely to validate the TPM mechanics work
- [x] Unseal manually, confirm it prints the right password back — matched
      exactly
- [ ] Pipe unseal output into `gnome-keyring-daemon --unlock`, confirm login
      keyring shows unlocked (`seahorse` or `secret-tool` check) — **blocked on
      sealing the real keyring password**, see note below
- [ ] Wire into autostart `.desktop` entry
- [ ] Log out / log in via **password**, confirm no popup
- [ ] Log out / log in via **fingerprint**, confirm no popup
- [ ] Reboot, repeat both checks
- [ ] Only after all manual checks pass: fold into `bin/` scripts + `install.sh`
      for the packaged version

### Dead end found: `gnome-keyring-daemon --unlock` doesn't work against the
### systemd-managed daemon on this system

System detail that matters here: this machine runs gnome-keyring-daemon 50.0
("testing" build) managed by systemd user units, not the classic PAM/X-session
autostart model:

```
$ systemctl --user cat gnome-keyring-daemon.service
[Unit]
Requires=gnome-keyring-daemon.socket
[Service]
ExecStart=/usr/bin/gnome-keyring-daemon --foreground --components="pkcs11,secrets" --control-directory=%t/keyring
[Install]
WantedBy=graphical-session-pre.target
```

This unit starts the daemon early and unconditionally, independent of login
method — well before any autostart entry runs.

Tried, all failed (login keyring stayed `Locked: true`, confirmed via
`gdbus call --session --dest org.freedesktop.secrets
--object-path /org/freedesktop/secrets/collection/login
--method org.freedesktop.DBus.Properties.Get org.freedesktop.Secret.Collection Locked`):

1. `gnome-keyring-daemon --unlock` (password on stdin) — silent no-op.
2. Same, with `GNOME_KEYRING_CONTROL` explicitly set to the systemd unit's
   control directory (`/run/user/1000/keyring`) — silent no-op.
3. `gnome-keyring-daemon --replace --unlock --components=pkcs11,secrets
   --control-directory=/run/user/1000/keyring` — logs
   `Replacing daemon, using directory: ...` but the original daemon **process
   (PID) is untouched** afterward and the collection stays locked. `--replace`
   doesn't appear to actually take over the systemd-started instance.

All three attempts also left a **lingering, non-exiting
`gnome-keyring-daemon --unlock`/`--replace` process** behind each time — not
just "didn't work", but didn't clean up after itself either. Had to kill these
by PID each time (careful: `pkill -f "gnome-keyring-daemon --unlock"` is
dangerous here — it can match the *invoking* shell command's own argv text and
kill the wrong thing; use `ps aux | grep "[g]nome-keyring..."` + explicit PID
kill instead).

Every attempt logged `gnome-keyring-daemon[PID]: another secret service is
running` — the systemd-started instance already owns the
`org.freedesktop.secrets` bus name, and the CLI unlock path apparently isn't
honored once that's the case on this build.

**Isolated the variable that mattered**: sealed password itself is *correct* —
confirmed by manually unlocking the same "Login" keyring through Seahorse
(Passwords and Keys GUI) with the same password, which worked. So this is
purely a mechanism problem with the classic `--unlock`/`--replace` CLI path
on this systemd-managed setup, not a sealing bug.

**Working theory**: on older setups, `pam_gnome_keyring` invoked
`gnome-keyring-daemon --login` (or `--unlock`) *as the very first thing that
creates the daemon process*, during the PAM session phase — i.e. it wasn't
"feed a password to an already-running daemon" so much as "bootstrap the
daemon with a password already known". Since systemd now starts the daemon
unconditionally and early via socket activation, independent of PAM, that
window doesn't exist anymore on this system — there may no longer be a
supported *userspace/CLI* way to retroactively unlock it after the fact.

### Root cause found and confirmed: systemd races PAM to create the daemon

`gnome-keyring-daemon.service`/`.socket` (user systemd units, shipped by this
distro) are `WantedBy=graphical-session-pre.target` — they start the daemon
*unconditionally, before login/PAM even runs*, for **any** login method,
password included. By the time PAM's own keyring-spawn logic runs
(`pam_gnome_keyring.so`, which internally execs `gnome-keyring-daemon
--daemonize --login`), the real D-Bus `org.freedesktop.secrets` name and the
control socket path are already claimed by the systemd-started instance.
PAM's spawn attempt doesn't error, it just creates a second, disconnected
daemon instance that "successfully" unlocks *itself*, while the one actually
serving the desktop session stays locked forever. This is a real,
distro-level race condition, not specific to fingerprint auth — it likely
affects password logins on this system too (unconfirmed until masking, see
below — turned out yes, see confirmation).

Built the official-path PAM module (`pam/pam_tpm_keyring_authtok.c`, see
below) first and used it to test this theory via `pamtester` against an
isolated test service (`/etc/pam.d/tpm-keyring-test`), before touching any
real login file:

- `pamtester ... authenticate` alone: keyring stayed locked — turned out
  `pam_gnome_keyring.so`'s actual unlock only happens in the **session**
  phase (`open_session`, `auto_start`), not `auth`. Auth phase only stashes
  the password.
- `pamtester ... authenticate open_session` as regular user: our module's
  `execve()` of the root-owned `0700` helper failed with permission denied
  (log: `gkr-pam: no password is available for user`) — a test-harness
  artifact (pamtester wasn't run as root, unlike real GDM auth), not a real
  bug.
- Same, via `sudo pamtester`: log showed `gkr-pam: unable to locate daemon
  control file` then `stashed password ... started properly and unlocked
  keyring` — but `Locked` stayed `true` on the real collection, and a new
  orphan `gnome-keyring-daemon --daemonize --login` process appeared. Root
  cause of *this* symptom traced to `sudo` stripping `XDG_RUNTIME_DIR` by
  default, so `pam_gnome_keyring` couldn't find the real control socket and
  spun up yet another disconnected instance.
- Same again with `sudo env XDG_RUNTIME_DIR=/run/user/1000 pamtester ...`:
  env was now correct, but the *same* "started properly and unlocked
  keyring" + orphan-process pattern happened anyway — proving the collision
  isn't an env problem, it's the systemd-started instance already sitting on
  the control socket path and bus name.

**Fix (confirmed working):**
```bash
systemctl --user mask gnome-keyring-daemon.socket gnome-keyring-daemon.service
```
(user-level, no sudo, trivially reversible with `unmask`). This stops systemd
from ever pre-starting the daemon, leaving PAM's own spawn as the sole
creator. Tested end to end with a real logout/login **via password** (no PAM
edits needed for this part — `pam_gnome_keyring.so` was already present in
`gdm-password`): login keyring came up unlocked automatically, confirmed via
`Locked: false` and the log sequence `gkr-pam: stashed password to try later
in open session` → `gnome-keyring-daemon started properly and unlocked
keyring`. Root cause fully confirmed.

### Remaining step: the fingerprint-specific piece

Masking the systemd units fixes password logins (they already had a real
`PAM_AUTHTOK` from `pam_unix.so` to stash). Fingerprint logins still won't
auto-unlock on their own, since `pam_fprintd.so` never sets `PAM_AUTHTOK` —
that's what `pam/pam_tpm_keyring_authtok.so` (built and unit-tested above via
`pamtester`, confirmed to correctly inject the TPM-unsealed password once
run with root privileges and correct `XDG_RUNTIME_DIR`) is for. Not yet
wired into the real `/etc/pam.d/gdm-fingerprint` — that's the one remaining,
actually-in-production edit, and it gets an explicit confirmation checkpoint
before touching it, as planned.

The old `~/.config/autostart/tpm-keyring-unlock.desktop` approach (task #5)
is now superseded/dead weight — it silently no-ops (harmless, but should be
removed once the PAM-based fix is confirmed working, to avoid two competing
unlock mechanisms).

### Note: real password sealing happens outside the assistant's tool loop

`bin/seal.sh` and `bin/unlock.sh` are written (in `bin/`). `seal.sh` must be
run **directly by the user in their own terminal**, not through the assistant's
Bash tool — it prompts interactively with `read -s` so the real keyring
password never transits the chat or any tool-call log. The assistant refused
to accept the password when offered directly in chat (twice) for the same
reason — this is a hard boundary, not a one-off judgment call.

Once `seal.sh` has been run by hand, `unlock.sh` needs no secret input (it only
reads the already-sealed blob), so the assistant can run and verify *that*
part directly.

## Open questions

- License for the eventual repo: defaulting to MIT unless told otherwise.
- Repo will be prepared locally only — no GitHub push without explicit go-ahead.

## Resolved (2026-08-13)

Fingerprint login now auto-unlocks the (still password-protected) login
keyring, confirmed via real logout/login: `Locked: false`, log sequence
`gkr-pam: stashed password to try later in open session` → `gnome-keyring-daemon
started properly and unlocked keyring` — identical to the password-login
success path. Same for password login (fixed by the systemd mask alone,
independent of the PAM module).

Final working setup on this machine:
1. `systemctl --user mask gnome-keyring-daemon.socket gnome-keyring-daemon.service`
   — stops systemd from racing PAM to create the daemon (this alone fixed
   password logins).
2. `/usr/local/sbin/tpm-keyring-unseal` (root:root, 0700) — unseals the TPM-sealed
   password for a given username.
3. `/lib/x86_64-linux-gnu/security/pam_tpm_keyring_authtok.so` — PAM module,
   `auth optional`, injects the unsealed password into `PAM_AUTHTOK`; never
   affects the auth decision itself.
4. One line added to `/etc/pam.d/gdm-fingerprint`, between `pam_fprintd.so`
   and the pre-existing `pam_gnome_keyring.so`:
   `auth    optional        pam_tpm_keyring_authtok.so`
5. Sealed secret at `~/.local/share/tpm-keyring-unlock/` (TPM-bound, PCR7 policy).

Cleaned up: removed the dead-end `~/.config/autostart/tpm-keyring-unlock.desktop`
(superseded by the PAM fix) and the isolated test service `/etc/pam.d/tpm-keyring-test`.

Remaining: fold steps 1-5 into `install.sh` for the packaged/repo version
(task #7) — not urgent, the machine itself is already fully fixed.

## Bug found on full reboot (2026-08-13, later) — fixed

The "Resolved" section above was confirmed via logout/login only, not a full
reboot. On an actual reboot, fingerprint login went back to prompting for
the keyring password manually. Root cause was different from anything
above, and specific to the TPM sealing, not the PAM/systemd design:

- `bin/seal.sh` created the primary key with `tpm2_createprimary -C o -c
  "$DATA_DIR/primary.ctx"` and kept that **context file** around, and
  `tpm-keyring-unseal.sh` loaded the primary from that same saved context
  file on every unseal.
- A saved context for a *transient* TPM object (which is what
  `tpm2_createprimary` produces unless you explicitly persist it via
  `tpm2_evictcontrol`) is only valid within the TPM's current reset epoch.
  Every reboot increments the TPM's internal reset counter, and the TPM
  then refuses to load any context saved before the reset:
  `Esys_ContextLoad() ... integrity check failed`. This is intended TPM
  behavior, not a bug in tpm2-tools.
- Confirmed by reproducing the exact failure directly:
  `sudo env -i /usr/local/sbin/tpm-keyring-unseal dmitrii` (empty envp, same
  as how the PAM module execve's it) → `tpm2_load` failed with exactly that
  error, immediately after a real reboot.
- Fix: don't persist the primary's context at all. `tpm2_createprimary`
  with a fixed hierarchy+template is **deterministic** — same TPM, same
  template in, same key out, every time — so both `seal.sh` and
  `tpm-keyring-unseal.sh` now call `tpm2_createprimary` fresh into a
  throwaway `mktemp -d` workdir on every run instead of loading a saved
  `primary.ctx`. Verified directly: recreated the primary fresh, loaded the
  *existing* `seal.pub`/`seal.priv` under it, ran `tpm2_unseal` — succeeded.
  No re-sealing needed; the sealed blob itself was never the problem, only
  how its parent key was being loaded.
- Practical effect: `~/.local/share/tpm-keyring-unlock/primary.ctx` (the old
  file) is now unused dead weight and safe to delete; nothing reads it
  anymore. The already-installed `/usr/local/sbin/tpm-keyring-unseal` on
  this machine still has the old, broken logic and needs re-installing from
  the fixed `pam/tpm-keyring-unseal.sh` (`sudo install -o root -g root -m
  0700 pam/tpm-keyring-unseal.sh /usr/local/sbin/tpm-keyring-unseal`).
- Lesson for next time: don't declare something "survives reboot" without
  an actual reboot test. Logout/login exercises the PAM stack but not the
  TPM's reset-counter behavior — those are genuinely different failure
  surfaces.

**Confirmed fixed by an actual reboot test** (not just logout/login) after
reinstalling the corrected `/usr/local/sbin/tpm-keyring-unseal`: fingerprint
login unlocked the keyring with no manual password prompt. `Locked: false`,
log sequence `gkr-pam: stashed password to try later in open session` →
`gnome-keyring-daemon started properly and unlocked keyring` — clean
success path, this time genuinely surviving a full reboot.

Optional leftover cleanup (harmless, nothing reads it anymore): `rm -f
~/.local/share/tpm-keyring-unlock/primary.ctx`.

## Second regression: enabling system-wide fingerprint reopened the gap (2026-08-13, later still) — fixed

Separately from `tpm-keyring-unlock` itself, the user wanted fingerprint to
also work for `sudo` and for polkit-gated actions (e.g. installing snaps
from Ubuntu's App Center). `/etc/pam.d/sudo` already had `pam_fprintd.so`
wired in directly. `/etc/pam.d/polkit-1` and `/etc/pam.d/pkexec` don't
exist on this system, so those fall back to `/etc/pam.d/other`, which
`@include`s `common-auth`. Fix: `sudo pam-auth-update --enable fprintd` —
the official, maintainer-shipped profile at `/usr/share/pam-configs/fprintd`
(`Priority: 260`, `[success=end default=ignore] pam_fprintd.so
max-tries=1 timeout=10`), which inserts fingerprint as the first auth
method in `common-auth` with automatic fallback to password.

This worked for `sudo`/polkit, but **broke keyring auto-unlock again**
after the next reboot. Root cause: `gdm-password` (the regular login
screen) also does `@include common-auth`. Once `common-auth` offers
fingerprint, touching the sensor *on the password screen* (not the
dedicated fingerprint option) succeeds via `pam_fprintd.so` through the
include — and `gdm-password` was never patched with our
`pam_tpm_keyring_authtok.so` bridge, only `gdm-fingerprint` was. Same root
cause as the original fingerprint bug, new attack surface. Confirmed via
`journalctl`: login session's PAM service was `gdm-password`, logged
`gkr-pam: no password is available for user`.

Fix, in two parts:
1. Immediate: patched `/etc/pam.d/gdm-password` by hand with the same
   bridge line, inserted directly before its `auth optional
   pam_gnome_keyring.so` line (backed up first).
2. Structural: rewrote `install.sh` step 6 to stop targeting
   `/etc/pam.d/*fingerprint*` specifically. It now finds *every*
   `/etc/pam.d/` service file with an auth-phase `pam_gnome_keyring.so`
   line (`gdm-password`, `gdm-fingerprint`, `gdm-smartcard*`,
   `gdm-autologin`, ...) and offers to patch each one. The module is
   always a no-op when a real password was typed, so patching broadly is
   safe.

Lesson: this module's job is "make sure PAM_AUTHTOK is populated before
pam_gnome_keyring.so runs, no matter what actually authenticated you." That
job is defined by *which PAM service could invoke pam_gnome_keyring.so*,
not by which service happens to be named after fingerprints. Scoping the
fix to "the fingerprint file" was the actual bug, not a one-off.

Also found and removed during this pass: `/etc/pam.d/tpm-keyring-test`,
a leftover isolated test-service file from the original `pamtester`
debugging session that was never cleaned up.

**Confirmed fixed by an actual reboot test.** Fingerprint on the regular
password screen (`gdm-password`), no manual keyring prompt. `Locked:
false`, log: `gkr-pam: stashed password to try later in open session` →
`gnome-keyring-daemon started properly and unlocked keyring`.

Current full status: keyring auto-unlock works via password, dedicated
fingerprint screen, and fingerprint-on-password-screen, and survives real
reboots. `sudo` and polkit/pkexec-gated actions (snap installs via App
Center included) also accept fingerprint now, via the system-wide
`pam-auth-update --enable fprintd` profile. `install.sh` has been updated
to apply the broader PAM patch (all `pam_gnome_keyring.so`-referencing
services, not just fingerprint-named ones) on fresh installs.

## Pre-publish pass: secrets scrub, rename, portability review (2026-08-13, later still)

Before making the repo public: scrubbed this journal (then still
`PLAN.md`) and every other file for anything that shouldn't be public.
Found one thing — this file's header identified the specific machine by
its full hostname, generalized to just the CPU family instead. No
passwords, emails, IPs, or other secrets found anywhere in the repo
(grepped explicitly for the sudo password that was pasted into chat early
in this project — never made it into any file). Renamed `PLAN.md` → `JOURNAL.md`
and added `CLAUDE.md` instructing future agents to keep it updated as a
standing rule, not just this once.

Also did an honest portability review, since everything so far was
designed and tested against exactly one machine. Real gaps found in
`install.sh`/`uninstall.sh`:

- **Dependency install was hardcoded to `apt`.** Would hard-fail on any
  non-Debian-family distro with "apt: command not found" instead of doing
  anything useful. Fixed: detects `apt`/`dnf`/`pacman`/`zypper` and maps
  package names per manager (PAM dev headers in particular are named
  differently everywhere: `libpam0g-dev` / `pam-devel` / `pam` / `pam-devel`
  respectively). Falls back to a clear manual-install message if none of
  the four are found, instead of just crashing on the `apt` call.
- **PAM module directory detection only looked at `x86_64-linux-gnu`
  paths.** Would fail to find the install location on `aarch64` (ARM64)
  machines even though the module itself compiles fine there (gcc targets
  whatever it's run on). Added `aarch64-linux-gnu` candidates alongside
  the existing `x86_64-linux-gnu` ones in both `install.sh` and
  `uninstall.sh`.

Not fixed, and not believed to be fixable by this tool: KDE/KWallet
(architecturally different secrets service, no `pam_gnome_keyring.so` to
hook), non-systemd init systems (the whole "systemd races PAM" root cause
and its fix don't apply there — whether *a* version of the underlying
problem exists on such systems is unknown, untested), package managers
other than the four above.

None of the above were tested on real hardware/distros other than the
original Ubuntu machine — the fixes are code-reviewed for correctness,
not field-verified. README's new "Compatibility" section says this
explicitly rather than claiming broader support than is actually known.

## Old status notes (superseded by "Resolved" above, kept for history)

Everything is built and verified except the last production edit. **User has
already confirmed** they want this edit applied — just paused mid-session,
resume by doing it directly, no need to re-ask.

**What's done and confirmed working:**
- TPM sealing/unsealing mechanics (`bin/seal.sh`, `bin/unlock.sh`) — verified
  round-trip correct, real keyring password sealed and confirmed correct
  (manually unlocked via Seahorse).
- Root cause of the whole problem found and fixed at the system level:
  `systemctl --user mask gnome-keyring-daemon.socket
  gnome-keyring-daemon.service` — **already applied on this machine**. This
  alone fixed password-login auto-unlock (verified: real logout/login via
  password, `Locked: false`, clean `gkr-pam` success log). This fix stands on
  its own regardless of what happens with fingerprint.
- PAM helper module for the fingerprint-specific gap: `pam/pam_tpm_keyring_authtok.c`,
  compiled to `pam/pam_tpm_keyring_authtok.so`, **already installed** at
  `/lib/x86_64-linux-gnu/security/pam_tpm_keyring_authtok.so`. Companion root
  helper **already installed** at `/usr/local/sbin/tpm-keyring-unseal` (root:root,
  0700). Mechanism verified end-to-end via `pamtester` against the isolated
  `/etc/pam.d/tpm-keyring-test` service (`sudo env XDG_RUNTIME_DIR=/run/user/1000
  pamtester tpm-keyring-test dmitrii authenticate open_session` → password
  correctly landed in `PAM_AUTHTOK`, `pam_gnome_keyring` consumed it — the
  *earlier* "still locked" result in that same test was the systemd-race bug
  above, not this module; once the mask was applied the mechanism was already
  proven sound via the password-login test, which exercises the identical
  `pam_gnome_keyring` session-unlock path).

**Not yet done — the one remaining step, confirmed by user, ready to execute:**

Edit `/etc/pam.d/gdm-fingerprint`, insert one line:
```diff
 auth	required	pam_fprintd.so
+auth    optional        pam_tpm_keyring_authtok.so
 auth    optional        pam_gnome_keyring.so
```
(`sudo tee`/manual edit — needs interactive sudo, must be run by the user
directly, not through the assistant's Bash tool, same as every other sudo
step in this session.)

Then: real logout/login **via fingerprint**, check `Locked` property and
`gkr-pam` logs the same way as the password test above (task #6).

**Cleanup still pending after that succeeds:**
- Remove the now-dead `~/.config/autostart/tpm-keyring-unlock.desktop` and
  `bin/unlock.sh`'s role as an autostart entry — superseded by the PAM fix,
  currently just a silent no-op left over from the earlier (dead-end)
  approach.
- Remove the test-only `/etc/pam.d/tpm-keyring-test` service file.
- Task #7 (package into installable `bin/` + `install.sh` + `README` +
  `LICENSE`) — needs redesigning around the *actual* working mechanism
  (systemd mask + PAM module + helper), not the original autostart-script
  design that PLAN.md started with. The install.sh should handle: compiling/
  installing the .so and helper, masking the systemd units, sealing the
  password (interactive, user-run), and inserting the gdm-fingerprint line
  (with a clear warning/confirmation prompt, mirroring the caution used here).

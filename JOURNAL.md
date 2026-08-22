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

## Fixes from a fresh-eyes review, post-publish (2026-08-14)

Repo was already pushed to GitHub at this point (`origin/main` matched
HEAD). Ran an independent review with no context from this project's
history — deliberately, to catch things too familiar to notice anymore.
It found one real blocking issue and several worth-fixing ones. Fixed all
except one, judgment call below.

**Blocking, fixed: README claimed Secure Boot was a "hard requirement -
the tool refuses to proceed without it," but nothing in the code ever
checked it.** `install.sh` would happily seal a password against PCR7 in
whatever state Secure Boot happened to be in and declare success - on a
machine with it off, that's a seal that looks like a lock but isn't one,
which is exactly the failure mode this tool's whole design is supposed to
prevent. Fixed with a new `bin/lib.sh` (`require_secure_boot()`), sourced
by both `install.sh` and `bin/seal.sh` (seal.sh can be run standalone per
the re-seal instructions in README, so it needs the same guard
independently, not just via install.sh). Detection: `mokutil --sb-state`
first, falling back to reading the `SecureBoot` EFI variable directly
(`/sys/firmware/efi/efivars/SecureBoot-...`, byte at offset 4: 1=on,
0=off) if mokutil isn't installed; hard exit if determined off, hard exit
with a legacy-BIOS-specific message if `/sys/firmware/efi` doesn't exist
at all, hard exit asking for manual confirmation if neither method can
determine the state. Verified both detection paths agree and correctly
report "on" on the real dev machine before wiring it in.

**Fixed: PAM module logged nothing, anywhere, ever.** `pam_ext.h` (the
header `pam_syslog` comes from) was included but never called - every
failure path returned `PAM_IGNORE` in total silence. Compounding this, the
helper subprocess's own stderr was explicitly redirected to `/dev/null`,
throwing away tpm2-tools' own diagnostic output too. Meanwhile README's
Troubleshooting section tells people to check `journalctl` for exactly
this module's failures. Fixed: added `pam_syslog` calls on the genuinely
unexpected failure paths (`pam_get_user`/`getpwnam`/`pipe`/`fork`
failures, at `LOG_ERR`) and on "helper produced no usable output" (at
`LOG_NOTICE` - deliberately lower severity, since "no sealed secret yet"
is a normal state, not an error); stopped discarding the helper's stderr
so tpm2-tools' own messages flow to the journal via the login process's
existing stderr→journald path, same as `gkr-pam`'s messages already do.

**Fixed: no timeout on the TPM call.** `waitpid()` on the helper process
had no bound - a hung TPM call (firmware hiccup, resource-manager
contention) would block the login prompt indefinitely with no fallback.
Added an `alarm(15)` + `SIGALRM` handler (deliberately not `SA_RESTART`,
so it interrupts the blocking `read()`/`waitpid()` instead of silently
retrying) that kills the helper and falls through to `PAM_IGNORE`, logged
at `LOG_ERR`, on timeout.

**Fixed: `install.sh` installed dependencies before checking hardware.** A
machine with no TPM at all got walked through a sudo package install
before being told, only afterward, that it can't use the tool anyway.
Reordered: `/dev/tpmrm0` + `require_secure_boot` now run first, as step 0,
before any package installation.

**Fixed: `TPM_KEYRING_UNLOCK_DATA_DIR` env override in `seal.sh` was a
trap.** It let you override the sealed-secret path when sealing, but the
PAM module execve's the helper with a **completely empty environment**
(hardening, intentional), so the override could never reach
`tpm-keyring-unseal.sh` at actual login time even if someone used it.
Anyone who found and used this undocumented override would get a
permanently-silent login failure. Removed the override entirely rather
than plumbing it through - the path needs to be the same constant on both
sides of the seal/unseal boundary, an env var can't safely be that.

**Fixed: PAM-line detection/insertion regex assumed a single-token control
field.** `grep -lE '...auth\s+\S+\s+pam_gnome_keyring...'` and the matching
`sed` insert address would silently fail to match a line like `auth
[success=ok default=ignore] pam_gnome_keyring.so` (bracketed control syntax
contains spaces, `\S+` stops at the first one). Low real-world odds for
this specific module, but this is code that edits live login-auth files,
so "silently does nothing instead of failing loudly" is the wrong failure
mode. Fixed the pattern to `(\S+|\[[^]]*\])` in both `install.sh`'s
detection grep and its sed insert address; tested both the plain-keyword
and bracketed-control cases directly against sample PAM lines before
committing to the fix.

**Fixed: misleading error message when TPM PCR read fails and there's no
`tss` group at all.** The old message always said "even though the tss
group looks right" - but if the group doesn't exist on this system, that
was never actually verified, it just wasn't checked. Now tracks whether
the group was actually confirmed present and tailors the message
accordingly.

**Fixed: `uninstall.sh` didn't mirror `install.sh`'s `tss` group step.**
`install.sh` can add the user to `tss`; `uninstall.sh` had no way to
reverse that, meaning full removal required knowing to go find
`install.sh`'s source to figure out what to undo by hand. Added a matching
confirm-gated `gpasswd -d "$USER" tss` step.

**Fixed: `pam/tpm-keyring-unseal.sh` was committed non-executable** while
every other script in the repo was `755`. Harmless in practice
(`install.sh` deploys it via `install -m 0700`, which sets the mode
explicitly regardless of the source file's own bit), but inconsistent.
`chmod +x`'d.

**Not fixed, deliberate: real Linux username ("dmitrii") appears in
example commands in this file's older entries.** Flagged by the review
as low-severity since `LICENSE` already publicly attributes the whole
project to "Dmitrii Timoshenko" by full name - the username adds
essentially no new exposure. Chose not to scrub it: this file's value is
being an accurate record of what was actually typed and why, and
retroactively genericizing historical entries would quietly misrepresent
that history for a redaction that isn't actually protecting anything.

All fixes syntax-checked (`bash -n`), the C module recompiled clean with
`-Wall -Wextra` (zero warnings) after each change, and the new
Secure-Boot detection and PAM-regex fixes were each tested in isolation
(against the real machine's actual EFI state, and against synthetic
sample PAM lines for both control-syntax cases) before being wired into
the real scripts.

## Missing feature-test macro found by VS Code IntelliSense (2026-08-14)

User spotted a red squiggle in VS Code on the `struct sigaction sa, old_sa;`
line added in the previous pass: "incomplete type 'struct sigaction' is not
allowed". Initial instinct was to dismiss it as an IntelliSense false
positive, since `gcc -Wall -Wextra` (the exact command `install.sh` uses)
had already compiled the file clean, repeatedly. Checked instead of
asserting that - and it wasn't a false positive.

Reproduced with `gcc -std=c11 -pedantic` and `-std=c99 -pedantic`: both
failed for real, with `struct sigaction`'s storage size "not known" and
`sigemptyset`/`sigaction`/`kill` all "implicit declaration". Root cause:
glibc's `<signal.h>` guards the POSIX.1-2008 signal-handling declarations
behind feature-test macros (`_POSIX_C_SOURCE` and friends). Plain `gcc`
with no `-std=` flag defaults to GNU mode, which defines these implicitly
- so the code "worked," but only because of a compiler default it never
asked for, not because it was actually correct C. VS Code's IntelliSense
(and any stricter/non-default build - a different compiler, a different
libc, someone adding `-std=c11` for portability) would legitimately break.

Fixed properly rather than papering over it: added `#define
_POSIX_C_SOURCE 200809L` as the first thing in the file, before any
`#include`. Feature-test macros only take effect if defined before the
first system header that checks them, so it has to be that early.
Re-verified clean under plain `gcc`, `-std=c11 -pedantic`, and `-std=c99
-pedantic` - zero errors, zero warnings, all three.

Lesson: "the exact build command we ship compiles clean" and "this code is
actually portable C" are different claims. The former was true the whole
time; the latter wasn't until this fix. Worth remembering for any future
signal/POSIX-API code added here.

## Docker-based test suite added (2026-08-14)

User asked for real E2E coverage across distros/architectures via Docker
or VMs. Worked out what Docker can and can't actually prove here, rather
than assuming either "containers can test everything" or "containers are
useless for this":

**Can't touch, structurally**: TPM/PCR7/Secure-Boot state (containers
share the host kernel, no independent TPM or UEFI firmware) and real
GDM/PAM login flow. Said so plainly in `test/README.md` rather than
building something that looks like coverage but isn't - that layer needs
a VM with `swtpm`+OVMF, per the earlier testing-methodology research.

**Can genuinely test, and now does**: the PAM_AUTHTOK bridge module's
actual runtime logic, and the packaging/detection layer, both without
needing a TPM at all - because the module's only contact with "TPM stuff"
is executing a fixed helper path and reading its stdout, a boundary that's
trivially fakeable.

Added `bin/lib.sh` extensions (`PAM_MODULE_DIR_CANDIDATES` array,
`find_pam_module_dir()`, `PAM_GNOME_KEYRING_AUTH_RE`) so `install.sh`,
`uninstall.sh`, and the test suite all share one copy of this logic
instead of three that could drift - this was already a latent
duplication risk between install/uninstall before tests were added.

Test suite (`test/run-all.sh`):
- `test/unit-regex-test.sh` - detection/insertion regex against fixture
  PAM files (plain control, bracketed control, already-patched,
  no-match). No container needed, pure logic. Ran it directly - passes.
- `test/runtime-test.sh` (container) - compiles the module with
  `-DHELPER_PATH`/`-DHELPER_TIMEOUT_SECS` overrides (added to the C
  source specifically for this - `#ifndef`-guarded, so `install.sh`'s
  plain compile is untouched and still gets the real path/15s default),
  swaps in a fake helper script that branches on username
  (success/no-output-failure/hang), and uses `pamtester` +
  `pam_exec.so expose_authtok` to observe whether `PAM_AUTHTOK` actually
  landed correctly in each case - including timing the hang case to
  confirm the `SIGALRM`+`SIGKILL` timeout path really interrupts it
  instead of just eventually returning on its own.
- `test/distro/Dockerfile.{ubuntu,fedora,arch,opensuse}` +
  `test/distro/test-packaging.sh` (containers) - install deps via each
  distro's real package manager, compile against that distro's real PAM
  headers, verify `find_pam_module_dir()` lands on a directory that
  genuinely has `pam_unix.so` there. Plus an arm64 cross-build of the
  Ubuntu one via `docker buildx --platform linux/arm64` (qemu-user-static
  emulation), to exercise the `aarch64-linux-gnu` candidate paths under
  real ARM64 userspace rather than just trusting the string is correct.

**Real bug found while writing the openSUSE Dockerfile, before any
container was even run**: looked up openSUSE's actual `tpm2-tools`
package name to write the Dockerfile's `RUN zypper install` line, and it
turned out to be `tpm2.0-tools`, not `tpm2-tools` like every other distro
(confirmed via software.opensuse.org). `install.sh`'s zypper branch was
passing the generic `tpm2-tools` name through unchanged - would have
failed with a package-not-found error on real openSUSE, the exact
regression class the openSUSE Dockerfile exists to catch. Fixed
`install.sh`'s zypper package-name mapping to translate this specific
case, before the test suite even ran once.

**Update: Docker installed, full suite actually run.** First real run
found two genuine problems, neither of which were bugs in the product
code being tested - both in the test harness and host setup:

1. `runtime-test.sh`'s "helper succeeds" case failed:
   `PAM_AUTHTOK equals what the helper printed (got: , want:
   unit-test-fake-password-do-not-use)`. Root cause turned out to be the
   test's own assumption about `pam_exec.so`'s `expose_authtok` option -
   this container's base image strips man pages (`dpkg -L` listed
   `pam_exec.8.gz`, the file wasn't actually on disk), so the assumption
   couldn't even be checked against docs. Rather than keep guessing,
   wrote a minimal purpose-built "spy" PAM module
   (`test/fixtures/pam_spy_authtok.c`) that calls `pam_get_item(pamh,
   PAM_AUTHTOK, ...)` directly - the exact same call the real
   `pam_gnome_keyring.so` makes - and confirmed with it that
   `pam_tpm_keyring_authtok.so` was setting `PAM_AUTHTOK` correctly the
   whole time. The module was never broken; `pam_exec expose_authtok` in
   `test-runtime-test.sh` was the wrong tool for observing it, in this
   particular stripped-down image. Swapped the test to use the spy module
   instead - more direct, and no longer dependent on a pam_exec option
   whose exact behavior couldn't be verified locally.
2. The arm64 cross-build failed outright: `exec /bin/sh: exec format
   error`. Root cause: no QEMU binfmt handlers were registered on this
   host at all (`ls /proc/sys/fs/binfmt_misc/` had zero `qemu-*` entries)
   - `docker buildx` had a working builder instance, but nothing to
   actually emulate foreign-architecture binaries with. Fixed via the
   standard approach: `docker run --privileged --rm tonistiigi/binfmt
   --install all`.

After both fixes: full suite green - regex/detection, runtime (all four
PAM_AUTHTOK scenarios including the timeout path), and packaging on
Ubuntu/Fedora/Arch/openSUSE plus the arm64 cross-build, all `PASS`, in
one `make test` run.

Lesson, again: writing a test and running a test catch different classes
of bug. The openSUSE package name was caught by *writing* the Dockerfile
(a lookup, no execution needed). The `pam_exec` assumption and the
missing binfmt registration were only found by *actually running*
everything end to end - both would have shipped as "tests exist" while
being silently wrong or silently unable to run at all.

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

## Recurrence after a real cold reboot, post-publish (2026-08-14) — open, instrumented

First real cold-boot test since publishing (v1.1.0) failed: user logged in
via fingerprint, keyring did not auto-unlock, Chrome's "Authentication
required" popup appeared minutes later and had to be answered by hand.
Same failure signature as the `gdm-password` regression fixed on 2026-08-13
(`gkr-pam: no password is available for user`), but this time the file was
already correctly patched, so it's a different failure with the same
symptom.

**Ruled out, with evidence, before touching any code:**
- PAM files reverted/missing the bridge line — no, `grep`/`cat` on
  `/etc/pam.d/gdm-password` and `gdm-fingerprint` both still have `auth
  optional pam_tpm_keyring_authtok.so` right before `pam_gnome_keyring.so`.
- The systemd race is back — no, `systemctl --user is-enabled
  gnome-keyring-daemon.socket gnome-keyring-daemon.service` still reports
  `masked` for both, and the journal shows no `Started
  gnome-keyring-daemon.service` line for the user's own session this boot
  (only for the unrelated `gdm-greeter` user's session, which is expected
  and harmless).
- The helper/TPM path itself is broken — no, `sudo
  /usr/local/sbin/tpm-keyring-unseal dmitrii` (full env, run manually,
  hours after the failed login) returned exit 0. Since PCR values only ever
  extend forward within a boot and never reset until the next one, if it
  unseals now it was equally unsealable at 09:55:34 this same boot.
- The module crashing (segfault, etc.) — no `coredumpctl` available to
  fully confirm, but a crash inside a `.so` loaded into GDM's own PAM
  client process would very likely have taken down more than just this one
  optional auth step, and login/session-open proceeded cleanly right after.

**What the journal actually shows:** GDM spawns two parallel PAM
conversations on this login screen — `gdm-fingerprint][3936]` (requires
`pam_fprintd.so` only) and `gdm-password][3935]` (via `common-auth`, which
now leads with `pam_fprintd.so` too, `[success=3 default=ignore]`, since
`pam-auth-update --enable fprintd` was enabled earlier this session). The
user touched the sensor; the login that actually succeeded and opened the
session for `dmitrii` was `gdm-password][3935]`, meaning fingerprint
success came through `common-auth`'s leading `pam_fprintd.so` line (which
jumps straight to `pam_permit`, skipping `pam_unix`/`pam_sss`/`pam_deny`
entirely) — not through the dedicated `gdm-fingerprint` service. Either
way, `pam_unix` never ran in the winning stack, so `PAM_AUTHTOK` was
genuinely never set by anyone *except* whatever our bridge module did.

**The actual gap: the module is observationally silent on its two most
important paths.** `pam_tpm_keyring_authtok.so` only calls `pam_syslog()`
on explicit failure branches (`pam_get_user`/`getpwnam`/`pipe`/`fork`
failure, timeout, non-zero helper exit). It logs *nothing* on: (a) the
early-return no-op path when `PAM_AUTHTOK` is already set, and (b) the
success path after `pam_set_item()`. `journalctl -b 0` (all priorities,
including `debug`, both PAM services) shows **zero** lines from this
module for the failing login — not even a failure log. That means either
it silently succeeded and something *else* dropped `PAM_AUTHTOK` before
`pam_gnome_keyring` read it, or it silently no-op'd for a reason that
shouldn't have applied here. Logs alone can't currently tell these apart —
this is a real observability gap in the module, not a red herring.

**Fix applied (this entry): instrumentation, not a guessed root-cause
fix.** Added two `pam_syslog(LOG_INFO, ...)` calls: one right before the
fork/exec attempt ("PAM_AUTHTOK not set yet, attempting TPM keyring unseal
for user %s" — only fires on the non-trivial path, so ordinary
typed-password logins stay silent as before), and one right after a
successful `pam_set_item()` ("TPM keyring unseal succeeded for user %s,
PAM_AUTHTOK set"). Also started checking `pam_set_item()`'s own return
value for the first time (previously assumed to always succeed) and log if
it fails. Compiles clean under plain `gcc -Wall -Wextra`, `-std=c11
-pedantic`, and `-std=c99 -pedantic`.

**Not yet resolved.** Needs a full cold reboot (not a screen lock/unlock —
the assistant initially suggested `Super+L` + fingerprint, which the user
correctly flagged as not equivalent: lock/unlock reuses the already-running
`gnome-keyring-daemon` and an already-measured boot, so it can't reproduce
a boot-time-only race or a fresh-PCR unseal failure) with the rebuilt
module installed, then a fingerprint login, then `journalctl -b 0 | grep
tpm-keyring-unseal` (user-run, since installing a compiled PAM module
requires `sudo`) to see which of the three outcomes actually happened:
never attempted, attempted but `pam_set_item` itself reported failure, or
attempted-and-reported-success (which would mean the bug is on
`pam_gnome_keyring`'s side, not ours, and a very different investigation).

One live hypothesis not yet tested: GDM ran *two* parallel PAM stacks this
boot, and both include `auth optional pam_tpm_keyring_authtok.so`. If both
fired near-simultaneously, two concurrent `tpm2_*` sessions against the
same TPM (this machine's is an AMD PSP firmware TPM, more resource-
constrained than a discrete chip) could race for session slots on
`/dev/tpmrm0`. If that happened, the losing side's helper script would
`exit` non-zero under `set -e`, which *should* already be caught by the
"helper produced no usable output" log — but that log was equally silent,
so this needs the instrumentation above to confirm either way, not more
speculation.

### Root cause found and fixed (same day, after a real cold reboot with the instrumentation above)

The instrumentation worked immediately. `journalctl -b 0` on the next real
cold boot + fingerprint login showed, for **both** parallel PAM stacks:
`PAM_AUTHTOK not set yet, attempting TPM keyring unseal for user dmitrii`
followed ~13-14 seconds later by `tpm-keyring-unseal helper produced no
usable output (exit 1)`. Not a timeout (would say so explicitly) — a real
`exit 1` after a suspiciously long delay for what should be a sub-second
TPM operation.

The helper's own `exit 1` from `set -e` doesn't say *which* command failed,
and the child's stderr — deliberately left inherited from the login
process specifically so this kind of thing would be diagnosable (see
`pam_tpm_keyring_authtok.c` comment) — doesn't show up under the PAM
service's own syslog tag, because it's a **different PID** (the forked
child, not the PAM module's own process). Widening the `journalctl` window
to *all* lines (no tag/PID filter) for that ~14s window surfaced it, under
`gdm-session-worker[4460]` and `gdm-session-worker[4463]` — two child
processes, 92ms apart:

```
ERROR:esys:...Esys_Unseal.c:98:Esys_Unseal() Esys Finish ErrorCode (0x00000128)
ERROR: Esys_Unseal(0x128) - tpm:error(2.0): PCR have changed since checked
ERROR: Unable to run tpm2_unseal
```

**Root cause confirmed:** GDM always spawns two parallel PAM conversations
on this login screen (`gdm-fingerprint` and `gdm-password`, since
`common-auth` now leads with `pam_fprintd.so` too), and our bridge module
is wired into both — by design, since either one could be the one that
ends up needing it. On this boot, both fired within about a second of each
other, both ran the full `tpm2_createprimary` → `tpm2_load` →
`tpm2_startauthsession --policy-session` → `tpm2_policypcr` → `tpm2_unseal`
sequence *concurrently* against the same TPM device. `tpm2_policypcr`
checks and locks in the current PCR7 value into its session's policy
digest; by the time that session's own `tpm2_unseal` actually runs, the
interleaving with the *other* concurrent session's activity on the same
device caused the TPM to see the PCR-checked-at-policy-time state as
invalidated ("PCR have changed since checked") — even though PCR7 never
actually, legitimately changed. The ~13s delay is consistent with
contention/serialization overhead on this machine's AMD PSP firmware TPM
(fTPM), which is more resource-constrained (fewer session slots, slower)
than a discrete TPM chip. The script itself never races with anything
external — this is strictly two copies of *our own* helper stepping on
each other, something no earlier reboot test happened to trigger (both
parallel stacks have to actually attempt fingerprint-path unsealing at
close enough timing, which depends on exactly how/when the user touches
the sensor relative to GDM's own stack setup).

**Fix:** serialize `pam/tpm-keyring-unseal.sh` with `flock` around a lock
file at `/run/lock/tpm-keyring-unseal.lock` (`exec 9>...; flock -w 10 9 ||
exit 1`, right after the `seal.priv` existence check, before any `tpm2_*`
call). The losing invocation now just waits up to 10s for the winner to
finish and release the TPM, instead of racing it and failing. 10s wait +
the actual sub-second unseal work comfortably fits inside the PAM module's
existing 15s `HELPER_TIMEOUT_SECS` budget, so a normal double-fire still
completes well within the login-blocking timeout. `/run/lock` (tmpfs,
world-writable-sticky, cleared every boot) was used instead of `/var/lock`
to avoid depending on the latter being a symlink to it on every distro.
Only the login-time helper needs this — `bin/seal.sh` is a one-off,
user-run, interactive command with no concurrent-invocation exposure.

**Lesson:** GDM's habit of running multiple PAM stacks in parallel for one
login screen (already the cause of the `gdm-password` regression above) has
a *second*, independent failure mode beyond "which files are patched" —
concurrent execution of the same helper against shared hardware. Anything
this bridge module shells out to that touches genuinely single-consumer
hardware state (a TPM session, in this case) needs to assume it can be
invoked twice in the same half-second, because on this login manager, it
routinely is.

**Confirmed fixed by an actual cold reboot test.** Fingerprint login, clean
log sequence: `PAM_AUTHTOK not set yet, attempting...` → (this time ~8s,
consistent with `flock` serialization overhead even though only one stack
ended up needing to unseal) → `TPM keyring unseal succeeded for user
dmitrii, PAM_AUTHTOK set` → `gkr-pam: stashed password to try later in
open session` → `gkr-pam: gnome-keyring-daemon started properly and
unlocked keyring`. No manual password prompt. Status: keyring auto-unlock
on fingerprint login survives a real cold reboot again, this time with the
concurrent-TPM-access race actually closed rather than just not triggered.

**Correction, same day, released as v1.1.1: incomplete.** The `flock` fix
above only rules out one specific *source* of the race (two copies of this
same script running at once). It recurred a few hours later, this time on
a resume-from-suspend re-authentication (`gdm-fingerprint` PAM stack
re-runs on unlock-after-suspend the same way it does on a cold boot login -
not the same thing as a plain screen-lock/unlock, which was already
established not to reproduce this class of bug). This time only **one**
PAM stack ran - no second concurrent instance of the script, `flock`
acquired instantly, and it still failed with the exact same `Esys_Unseal
... PCR have changed since checked` error. So contention between two
copies of *this* script was a real, confirmed cause (see above) but not
the *only* one.

**Profiled where the ~7-8s actually goes** (`/usr/bin/time`, each `tpm2_*`
step timed individually, secret output discarded, never printed):
`tpm2_createprimary` alone: **6.90s**. `tpm2_load`: 0.21s.
`tpm2_startauthsession`: 0.02s. `tpm2_policypcr`: 0.06s. `tpm2_unseal`:
0.12s. `tpm2_flushcontext`: 0.02s. So the actual PCR-check-then-use window
(`startauthsession` → `policypcr` → `unseal`) is only ~0.2s - tight - but
whatever is perturbing it doesn't need a wide window, and `createprimary`
dominating the runtime means every single login pays a fixed ~7s tax
before even reaching that window, every time, by design (recreating the
primary fresh instead of loading a saved context is the reboot-survival
fix from earlier - see above - so this cost isn't avoidable without
reopening that bug).

Checked for another concrete concurrent TPM consumer in the same window:
`gnome-remote-desktop-configuration.service` starts near every login/boot
and its daemon fails its *own* TPM credential init almost immediately
(`tcti:IO failure, using GKeyFile as fallback`) - but this happens on
*every* boot checked so far, including the one that succeeded, so it
doesn't correlate with failure specifically and isn't a confirmed cause,
just a permanently-broken, unrelated fallback path on this hardware.

**Fix (v1.1.2): retry the fast part, not the slow part.** Since
`createprimary`+`load` are deterministic and only need to happen once,
and the actual check-and-use step is cheap (~0.2s), `tpm-keyring-unseal.sh`
now retries *only* `tpm2_startauthsession` → `tpm2_policypcr` →
`tpm2_unseal` (fresh session context each attempt, old one flushed before
retrying), up to 5 attempts with a 0.3s backoff between them, before
giving up. This is a defensive measure, not a root-cause fix - the exact
reason a single, uncontended run can still see "PCR have changed since
checked" on this fTPM remains unconfirmed. It's treated the same way as
any other transient hardware hiccup: detect, back off briefly, retry,
bounded.

Worst-case timing budget grew as a result: `flock` wait (≤10s, only under
real contention) + `createprimary`/`load` (~7.1s, fixed) + up to 5 retries
of the fast step (~0.5s each with backoff, ~2.5s) ≈ 20s worst case. The PAM
module's `HELPER_TIMEOUT_SECS` was raised from 15 to 25 to give that
headroom - at 15s, a retry that would have eventually succeeded could get
killed by the module's own alarm-based timeout instead, turning a
recoverable transient failure into a hard "timed out" one. Normal case
(single stack, first attempt succeeds) is unchanged, still ~7.4s.

Verified: `bash -n` on the script, `gcc -Wall -Wextra` under plain, `-std=c11
-pedantic`, and `-std=c99 -pedantic` all clean on the module. Ran the
updated script directly (via `tss` group membership, no sudo needed to
reach `/dev/tpmrm0`) against the real sealed blob with a throwaway lock
path (the real `/run/lock/tpm-keyring-unseal.lock` is root-owned 0644 from
the actual login attempts, correctly unwritable by a non-root test) -
`exit 0`, secret discarded to `/dev/null` without ever being displayed.

**Not yet confirmed by a real reboot/resume test with this version
installed** - same verification loop as before: cold boot or
resume-from-suspend, fingerprint login, `journalctl -b 0 | grep -i "tpm
keyring unseal"` should show the `succeeded` line, ideally without even
needing a retry (retries would show as multiple close-together
`tpm2_startauthsession` policy-session attempts inside one script run,
currently not separately logged to journald - only the script's own final
outcome is visible to PAM). Version bumped to 1.1.2 in `VERSION`.

## Docker test suite reviewed, arm64-skip bug fixed, CI added (2026-08-14)

Independent review of the whole Docker test suite (no prior context from
this file, deliberately - same "fresh eyes" method as the earlier
post-publish review). Actually ran every layer live rather than trusting
the "full suite green" claim above at face value:

- `test/unit-regex-test.sh`: PASS (11/11), run directly, no container.
- `test/distro/Dockerfile.runtime` + `runtime-test.sh`: PASS, all 3
  `PAM_AUTHTOK` scenarios including the timeout-actually-interrupts-the-hang
  timing check.
- All four `test/distro/Dockerfile.{ubuntu,fedora,arch,opensuse}`: PASS.
- The arm64 cross-build: **FAIL** - on this machine, right now, with no
  qemu binfmt handler registered (`ls /proc/sys/fs/binfmt_misc/` empty of
  `qemu-*` entries, same check the original binfmt fix used).

**Real bug found, not a flake:** `run-all.sh`'s decision to skip the arm64
leg checked only `docker buildx version` (does the CLI plugin exist), not
whether foreign-arch containers can actually *run* on this host. Two
consequences confirmed directly:

1. `docker buildx build --platform linux/arm64 ... --load` can succeed
   with **zero actual emulation**, if the layer that would need it (here,
   `apt-get install`) is already cached from a previous build that *did*
   have a working qemu handler - buildx just replays the cached layer
   without re-executing it. Reproduced this exactly: rebuilt with a stale
   cache, `docker buildx build` reported `CACHED` all the way through and
   exited 0, then `docker run --rm --platform linux/arm64 ...` failed with
   `exec /usr/bin/bash: exec format error`.
2. Because the check only gated on `buildx` existing, a host with buildx
   installed but no registered binfmt handler got a hard `FAIL` from
   `run-all.sh`, not the `SKIPPED` the rest of the suite gives for
   "capability genuinely absent here." `make test` could go red purely
   from host state, unrelated to any actual code regression.

**Fix:** added `arm64_emulation_available()` to `test/run-all.sh` -
checks `docker buildx version` *and* greps
`/proc/sys/fs/binfmt_misc` for a registered `aarch64`/`arm64` handler
before attempting anything. Verified: after removing the stale cached
image and re-running on this same qemu-less machine, the leg now reports
`SKIPPED` (with a pointer to the `tonistiigi/binfmt` install command from
`test/README.md`) and the overall suite exits 0, instead of the previous
false `FAIL`.

**Also added: GitHub Actions CI** (`.github/workflows/test.yml`), since
none existed - the whole suite above, container-based tests included, was
only ever run by hand. Mirrors `run-all.sh`'s four layers as separate jobs
(`regex`, `runtime`, `packaging` as a 4-way distro matrix,
`packaging-arm64`) rather than one script-in-a-job, so a PR check shows
which specific layer broke. Triggers on push to `main` and on every PR.
The arm64 job uses `docker/setup-qemu-action` to register binfmt on the
ephemeral GitHub-hosted runner - the CI equivalent of the manual
`tonistiigi/binfmt` install, scoped to that job's throwaway VM - so in CI
this leg always actually executes, never falls into the `SKIPPED` branch
above (that branch exists for contributors' local machines, which usually
won't have qemu registered).

Validated: `bash -n` on the changed `run-all.sh`, the workflow YAML parsed
with `python3 -c "import yaml; yaml.safe_load(...)"`, and the full local
suite re-run end to end after the fix (regex/runtime/all four distros:
PASS, arm64: correctly `SKIPPED`, overall exit 0).

**Not yet verified: whether the CI workflow itself is green on GitHub.**
Everything above was checked locally, including the YAML's syntax, but the
workflow has not yet been pushed/run on GitHub Actions infrastructure -
that's the next real confirmation step once this is committed and pushed.

## VM test layer added: real TPM/Secure Boot, not a fake helper (2026-08-14, later)

User asked for the layer `test/README.md` had always said Docker
structurally can't provide: something that exercises a real TPM 2.0
device and real, toggleable UEFI Secure Boot state, since containers share
the host kernel and have neither. Built `test/vm/run-vm-test.sh`
(`make test-vm`): `qemu`/KVM + OVMF (this machine already had both the
plain and `.ms`-with-Microsoft-keys `OVMF_VARS_4M*.fd` templates installed
via the `ovmf`/`ovmf-generic` packages - no new package needed for
toggleable Secure Boot state) + `swtpm` (needed installing, handed to the
user per this repo's standing sudo rule - `sudo apt install -y swtpm
swtpm-tools`). Cloud-init seed served over the SLIRP gateway via a local
`python3 -m http.server` (`ds=nocloud-net` datasource) instead of building
an ISO, since neither `cloud-localds` nor `genisoimage`/`mkisofs` were
installed and pulling in another package wasn't worth it for this.

Two scenarios, both against a real Ubuntu 24.04 minimal cloud image
(downloaded once, cached under `~/.cache/tpm-keyring-unlock-vm-test/`,
re-verified against Ubuntu's currently-published `SHA256SUMS` on every run
rather than a hash frozen in the script, since the file at that URL gets
refreshed upstream periodically):

- **Secure Boot OFF** (plain `OVMF_VARS_4M.fd`, no enrolled keys): confirms
  `require_secure_boot()` genuinely refuses.
- **Secure Boot ON** (`OVMF_VARS_4M.ms.fd`): confirms `require_secure_boot()`
  allows, then runs the real `bin/seal.sh` (a throwaway secret piped via
  stdin - `read -rsp` doesn't need a tty - never a real password) and
  `pam/tpm-keyring-unseal.sh` against a real PCR7 policy, fires two
  concurrent unseal calls at the same real TPM (validates the `flock` fix
  for the second reboot regression further up this file), then fully stops
  both `swtpm` and `qemu` and restarts them against the same on-disk TPM
  state / OVMF vars / disk image and confirms unseal still works - a
  genuine TPM reset-count increment, the same trigger as the "integrity
  check failed" / "PCR have changed since checked" bugs earlier in this
  file, which no container can reproduce.

**All real, run-blocking bugs, found by actually running this repeatedly
rather than trusting it after one green run** - consistent with this
project's established pattern (see the Docker-suite entry above) that
writing a test and running a test catch different classes of bug, and that
running it *once* isn't the same as it being *correct*:

1. **`start_swtpm`'s backgrounded `swtpm &` had no output redirect.**
   Harmless everywhere it was called directly - but `boot_b()` (which
   calls it) was originally invoked as `B1_SSHPORT=$(boot_b)`, a command
   substitution, which is a pipe. Since `swtpm` never exits, it inherited
   that pipe's write end and the pipe never saw EOF - `$(boot_b)` hung
   forever, on the very first line of scenario B, no SSH connection ever
   attempted. Fixed by redirecting `swtpm`'s (and, defensively, `qemu`'s)
   output to a log file instead of leaving it as an inherited fd.

2. **`boot_b()`'s "return values" were bash globals set inside a command
   substitution.** Fixing bug 1 exposed this one immediately: even with
   the hang gone, `$(boot_b)` still runs in a *subshell* - every variable
   `boot_b()` set (`B_BOOT_QEMU_PID`, `B_BOOT_SWTPM_PID`) vanished the
   moment that subshell exited, well before the caller could read them.
   Failed with `B_BOOT_QEMU_PID: unbound variable` (`set -u` caught it
   immediately rather than silently killing the wrong PID later, which
   would have been much worse). Fixed by calling `boot_b` directly (not
   substituted) and reading its globals straight afterward - the port
   itself became one more such global (`B_BOOT_SSHPORT`) instead of an
   echoed return value.

3. **Killing `qemu` right after `seal.sh` could race the guest's own
   write-back cache.** The reboot-survival check failed once with `got:
   ` (empty) - `tpm-keyring-unseal.sh` exits 1 silently if
   `$DATA_DIR/seal.priv` doesn't exist, which is consistent with the
   just-sealed files still sitting in the guest's dirty page cache when
   `qemu` got SIGTERM'd (no ACPI shutdown, no chance for ext4's normal
   writeback to run) - i.e. this was accidentally testing "survives a hard
   power cut before the disk syncs," a real but *different* question from
   the intended "survives a clean reboot's TPM reset." Fixed by running
   `sync` over SSH inside the guest immediately before tearing down `qemu`
   for the B1→B2 transition - keeps the deliberate full process
   restart (needed for a genuine TPM reset-count increment) while removing
   the unintended disk-durability variable.

4. **Found only after everything reported "All VM tests passed" and exited
   0: `qemu`/`swtpm`/the seed `http.server` were still running minutes
   later.** `stop_pid()` (and the `cleanup()` EXIT trap) sent `kill` then
   called `wait "$pid"` to confirm death - but `qemu` runs with
   `-daemonize`, which forks internally and reparents away from this
   script's shell, so the PID read back from `$pidfile` was never actually
   a direct child of this shell. `wait` on a non-child PID fails
   immediately ("not a child of this shell") and returns right away
   regardless of whether the process is still alive - so "cleanup"
   declared victory instantly, every single time, without ever confirming
   anything. Caught by manually checking `ps` well after a run had already
   printed its success summary and exited - the kind of thing that's
   invisible from the test's own output, only from watching the system
   around it. Fixed by replacing the `wait`-based confirmation with an
   active `kill -0` poll loop (up to 5s), escalating to `SIGKILL` if the
   process is still there after that.

**Confirmed genuinely stable, not just "passed once":** re-ran the full
suite twice in a row after all four fixes, including a direct `ps` check
for leftover `qemu`/`swtpm`/`http.server` processes after each run - both
runs: all 7 checks `ok`, exit 0, zero leftover processes. Also added a
`vm` job to `.github/workflows/test.yml` (the KVM device on GitHub-hosted
Linux runners needs a udev rule to be group-accessible to the default
runner user - the standard `KERNEL=="kvm", GROUP="kvm", MODE="0666"` fix
used by many QEMU-based Actions workflows; not yet confirmed green on
actual GitHub infrastructure, same caveat as the earlier CI entry).

Also added `errfile` support to the test's `check()` helper (prints
captured stderr inline on failure) - this is what made bug 3 diagnosable
at all instead of just "got empty string, guess why."

Lesson, same shape as the earlier "GDM runs multiple PAM stacks at once"
and "openSUSE package name" lessons in this file: a test suite for
infrastructure-adjacent code (bash driving real daemons, real subshells,
real process lifecycles) has its own bug surface, orthogonal to the
product code it's testing. All four bugs above were in the test harness,
none in `bin/seal.sh`, `pam/tpm-keyring-unseal.sh`, or `bin/lib.sh` - but
finding and fixing them was exactly as real a debugging exercise as the
TPM/PCR bugs those scripts already went through.

## Bug 5: reboot-survival check failed on real GitHub Actions CI, passed locally (2026-08-15)

First actual CI run of the `vm` job (GitHub Actions, PR #1) failed on
exactly the check bugs 1-4 above were fixed to make trustworthy - the
reboot-survival unseal - even though it had just passed twice in a row
locally before pushing. Every other check in the job passed (SB OFF, SB
ON, seal, same-boot unseal, concurrent unseal).

**Symptom, from the CI log:** all 5 of `tpm-keyring-unseal.sh`'s internal
retry attempts failed identically:

```
WARNING:esys:src/tss2-esys/api/Esys_Unseal.c:295:Esys_Unseal_Finish() Received TPM Error
ERROR:esys:src/tss2-esys/api/Esys_Unseal.c:98:Esys_Unseal() Esys Finish ErrorCode (0x0000099d)
ERROR: Esys_Unseal(0x99D) - tpm:session(1):a policy check failed
ERROR: Unable to run tpm2_unseal
```

**This is a different, more telling error than the ones earlier in this
file.** The real-hardware bugs above are all `0x128` ("PCR have changed
since checked" - a *race*, the PCR value changes concurrently mid-session).
This is `0x99D` (`TPM_RC_POLICY_FAIL`) - the policy digest computed at
unseal time simply does not match the sealed object's `authPolicy`, full
stop. All 5 retries failing *identically*, instead of eventually
succeeding the way a timing race would, means PCR7's live value at
unseal-time (boot 2) genuinely differed from what got captured into the
policy at seal-time (boot 1) - a real, deterministic mismatch, not
flakiness. Retrying the fast check-and-use step (which is what those 5
attempts are, by design - see the "profiled where the ~7-8s actually
goes" entry above) can never fix a *correct* readout of a value that has
actually changed; it only helps when the *TPM* transiently rejects a
still-valid check due to contention.

**Root cause (reasoned, not directly instrumented - see caveat below):**
the B1->B2 transition tore down qemu with a plain `kill` (`stop_pid`),
after only a guest-side `sync` (bug 3's fix). That `sync` flushes the
*guest's* ext4 write-back cache to the virtual disk - it says nothing
about qemu's *own* device-model buffering for the OVMF_VARS pflash store,
which is a `-drive if=pflash` with no explicit `cache=`, defaulting to
`writeback` at the qemu/host layer - a completely different cache the
guest-side `sync` never touches. If OVMF's firmware wrote anything to
that vars store during boot 1 that hadn't reached the actual file bytes
on disk when qemu got killed, boot 2's firmware could measure PCR7 from a
stale or partially-written vars store, producing a genuinely different
PCR7 - which deterministically breaks the policy check, every retry,
exactly as observed. Plausible why this didn't reproduce on the machine
this was developed and verified on twice, but did on GitHub's runner:
different disk speed/scheduling changes how much unflushed state exists
at the moment of a kill, the same category of environment-dependent
timing sensitivity as every TPM contention bug earlier in this file, just
one layer further down the stack.

**Fix:** replaced the abrupt kill (and the now-redundant `sync`) with
`graceful_poweroff_and_wait()`: issue `sudo systemctl poweroff` inside the
guest (backgrounded and not waited on - the SSH connection dies mid-shutdown,
which would otherwise make the `ssh` call itself hang or return a spurious
non-zero), then poll `kill -0` on the qemu PID (not `wait` - see bug 4's
comment on why `wait` doesn't work on a `-daemonize`d process) for up to
30s for qemu to exit on its own - qemu isn't passed `-no-shutdown`, so it
exits by itself once the guest's ACPI poweroff completes - falling back to
the existing forceful `stop_pid` only if it doesn't exit in time. A real
reboot is always an orderly shutdown before power is actually cut, never a
yanked cord; letting the guest own its own shutdown and letting qemu's
block backends go through their normal close/flush path addresses the
guest cache, the qemu-pflash cache, and any other buffering layer at once,
rather than requiring a fifth bug report the next time a different layer
turns out to matter. Considered also setting `cache=directsync` on the
pflash drive as extra defense; decided against it as redundant - a clean
qemu exit already flushes its block backends regardless of cache mode, so
it would add complexity without covering anything the graceful shutdown
doesn't already cover.

**Verified locally:** re-ran the full suite twice in a row after the fix,
on the same machine bugs 1-4 were verified on - both runs: all 7 checks
`ok`, exit 0, including `tpm-keyring-unseal.sh survives a real reboot`,
zero leftover processes after each run.

**Honest caveat, unlike every other entry in this file: the actual root
cause was never directly instrumented or confirmed on the CI runner
itself** - unlike bugs 1-4, which were each reproduced and re-verified in
the same environment they were diagnosed in, this fix is reasoned from the
error code's meaning and the one asymmetry (abrupt kill vs. clean
shutdown) between the local and CI runs, not from adding logging to the CI
run itself and watching it fail again with more detail. It passing locally
twice, both before and after this fix, cannot by itself prove the CI
failure is resolved, since it was never reproduced locally in the first
place. The only real confirmation will be an actual green (or red, with
more detail this time) run on GitHub Actions after this is pushed.

### Follow-up: graceful-shutdown fix did NOT resolve it on real CI - instrumented and got a real answer (2026-08-15)

Pushed the graceful-shutdown fix above and re-ran the `vm` CI job for
real. **Failed identically** - same `Esys_Unseal(0x99D) - tpm:session(1):a
policy check failed`, all 5 retries, same as before the fix. This directly
disproves the buffered-pflash-write hypothesis: a clean guest shutdown
(confirmed completing in 1s, not falling back to the forceful-kill path -
see below) still didn't fix it, so whatever's wrong isn't about qemu not
having flushed something to disk before dying.

Rather than propose a third guess, added direct instrumentation instead
(`log_pcr7()`, prints a live `tpm2_pcrread sha256:7` straight to stdout) at
three points: boot 1 right after seal, boot 1 right before teardown, and
boot 2 right after SSH comes up but before the unseal attempt. Also made
`graceful_poweroff_and_wait()` explicitly log which path it took (clean
exit vs. forceful-kill fallback after the 30s timeout), since "did the
graceful shutdown actually happen" was itself an open question, not
something the previous run's output could answer.

Ran locally first (sanity check the instrumentation doesn't break anything
- it doesn't, all 7 checks still `ok` twice in a row, and predictably PCR7
read identical at all three points locally: `0xC86235C7...`). Pushed, and
this time got real, direct evidence from the actual CI runner instead of
inference from an error code:

```
PCR7 (boot 1, right after seal):          0x8F0253A021DFD42A5115E88929E2AFBCB6397CDA0F0CFF19537650F6F8AF52A1
PCR7 (boot 1, right before teardown):     0x8F0253A021DFD42A5115E88929E2AFBCB6397CDA0F0CFF19537650F6F8AF52A1  (same as above - stable within boot 1)
-- graceful shutdown: qemu exited cleanly after 1s --
PCR7 (boot 2, right after SSH up):        0x8CF7C02C818E524FFAC4F88B1682D8EED0F3F7F7B4235457ABDBA53BA0AA53C2  (different!)
```

**Confirmed, not inferred: PCR7 genuinely, deterministically differs
between boot 1 and boot 2 of the same VM/disk/OVMF-vars/TPM-state on
GitHub-hosted runners** - with a clean graceful shutdown in between, ruling
out both the original "abrupt kill" theory and the "pflash write not
flushed" follow-up theory. Something about how OVMF measures PCR7 is
genuinely different between these two boots on this specific CI
environment; the mechanism is still unknown (candidates not yet
investigated: OVMF/qemu/swtpm package version specifics on GitHub's
runner image vs. this dev machine's locally-installed versions - CI does
a fresh `apt-get install` each run against whatever's currently in
Ubuntu's repos, this machine has whatever was installed whenever; possible
GRUB boot-path/menu-selection differences between a "normal" boot and
whatever boot 2 does after a poweroff; OVMF Secure Boot measurement
non-determinism under nested virtualization specifically). None of these
were confirmed - listed as candidates for whoever picks this up next, not
conclusions.

**Decision: mark this one check as a known CI limitation rather than keep
chasing it.** Two things this investigation did establish with actual
confidence: (1) the product code itself (`bin/seal.sh`,
`pam/tpm-keyring-unseal.sh`) behaves correctly given a *stable* PCR7 -
proven by the same-boot round trip and the reboot-survival check both
passing repeatedly, both locally and even in the CI runs above (every
check *except* reboot-survival passed in every CI run this session); (2)
the reboot-survival failure specifically correlates with something
CI-environment-specific (never reproduced locally, across many runs, with
and without the graceful-shutdown fix), not with anything about the
product code changing. Chasing OVMF/edk2 firmware measurement internals
further has uncertain payoff for a bridge-module project whose actual
job is the PAM_AUTHTOK plumbing, not firmware verification semantics.

Implementation: `.github/workflows/test.yml`'s `vm` job now sets
`KNOWN_CI_PCR7_DRIFT=1` for the `run-vm-test.sh` step. In
`run-vm-test.sh`, the reboot-survival check now branches on that variable
- set (CI only): a mismatch prints as `KNOWN LIMITATION` and does *not*
increment `FAIL`, so a CI-environment quirk can't block real PRs for a
failure mode nothing in the product code can actually cause. Unset (the
default, including `make test-vm` locally): unchanged, still a hard
failure - this is where the check actually earns its keep, since the
CI-specific drift doesn't reproduce there and every local run so far
(bugs 1-4's fixes, the graceful-shutdown fix, and this instrumentation)
has passed it repeatedly and reliably. Every other check in the `vm` job
(SB off/on, same-boot seal/unseal, concurrent-unseal `flock` check) still
gates normally in CI - only this one specific check is softened, not the
whole job.

Verified: `bash -n` on the script, the workflow YAML parsed with
`python3 -c "import yaml; yaml.safe_load(...)"`. Not yet verified: an
actual CI run with `KNOWN_CI_PCR7_DRIFT=1` in place, to confirm the job
goes green despite the underlying PCR7 mismatch still happening
underneath.

**If this recurs and someone picks it up again**: don't re-derive the
above from scratch. The buffered-write theory is ruled out. Start instead
by comparing exact `ovmf`/`qemu-system-x86`/`swtpm` package versions
between a GitHub-hosted `ubuntu-latest` runner and whatever's on the
machine reproducing (or failing to reproduce) it locally, and by dumping
the OVMF serial console log (`-serial file:...`, already captured but
never printed anywhere) for both boots to see if OVMF's own boot-time
messages show what's actually being measured differently.

## Debian added to the distro packaging matrix (2026-08-15)

User asked for Debian coverage specifically, separate from Ubuntu, and
asked what distro coverage already existed first. Answer at the time:
Ubuntu 24.04, Fedora 40, Arch (rolling), openSUSE Tumbleweed (rolling) +
an arm64 cross-build of the Ubuntu one - no Debian proper.

Worth its own Dockerfile even though Debian and Ubuntu both go through
`install.sh`'s same `apt` branch: same package manager, but a different
base image, different default package set, and different exact package
versions (Debian stable tends to ship older versions of everything than
Ubuntu's latest LTS) - "works on Ubuntu" was never actual proof it works
on Debian too, just an untested assumption. Added
`test/distro/Dockerfile.debian` (`FROM debian:13` - Trixie, current
Debian stable at the time of writing, mirrors the existing pattern of
pinning a specific numbered release rather than a floating tag, same as
`ubuntu:24.04`/`fedora:40`), wired into `test/run-all.sh`, `Makefile`'s
`test-packaging` target, and the `packaging` matrix in
`.github/workflows/test.yml`.

No changes needed to `install.sh` itself - its `apt` branch already
covers Debian generically (same `libpam0g-dev`/`tpm2-tools`/`gcc` package
names as Ubuntu; unlike the openSUSE case, which needed an explicit
`tpm2-tools` → `tpm2.0-tools` name translation, Debian's package names
matched Ubuntu's exactly, confirmed by the test actually passing on the
first build rather than assumed).

Verified directly, not just "should work": built and ran the new
container standalone (`docker build -f test/distro/Dockerfile.debian ...
&& docker run ...`) - passed on the first try, `find_pam_module_dir()`
correctly landed on `/lib/x86_64-linux-gnu/security` with `pam_unix.so`
present, confirming "Debian GNU/Linux 13 (trixie)" in the container's own
output. Then re-ran the full `test/run-all.sh` end to end to confirm nothing
else regressed - all layers `PASS` (arm64 leg correctly `SKIPPED` on this
machine, no qemu binfmt registered locally, same as before).

Done on a fresh branch (`test/debian-docker`) off `main`, deliberately not
based on the not-yet-merged `feat/vm-tests-init` branch (the VM test layer
from the previous session, held back from merging pending a CI failure
investigation there - see that branch's own JOURNAL.md entries above) to
avoid any dependency between the two pieces of unmerged work.
`feat/vm-tests-init` was merged into `main` in the meantime (PR #1); this
entry originally followed immediately after the "Docker test suite
reviewed" entry on this branch's own history, reordered here after the
merge conflict with `main` to keep the file in actual chronological order
rather than merge order.

## Login latency fix: primary key persisted in TPM NV storage instead of recreated every login (2026-08-16)

User reported the real-world symptom directly: fingerprint login on this
laptop pauses for "5, maybe 7 seconds" after the fingerprint touch before
the session actually opens, versus ~1s when this repo's PAM module isn't
in the loop at all. Not a new bug - it's the same ~7.4s hot-path cost
already profiled in the "Correction... incomplete" entry above
(2026-08-14): `tpm2_createprimary` alone measured **6.90s** per call on
this machine's fTPM, out of ~7.4s total, because both `bin/seal.sh` and
`pam/tpm-keyring-unseal.sh` recreate the primary key from scratch on
*every single invocation* - a deliberate choice at the time, to sidestep
the reboot-survival bug documented further up this file (a saved *context
file* for a transient object is tied to the TPM's reset counter and
becomes unloadable after a reboot: `Esys_ContextLoad() ... integrity check
failed`).

That earlier fix conflated two different things: "don't save a transient
object's context blob across reboots" (correctly true, and the actual root
cause of that bug) with "the primary can't be cached across logins at
all" (never actually true - just the simplest fix available at the time).
TPM 2.0 has a separate, purpose-built mechanism for exactly this:
`tpm2_evictcontrol`, which asks the TPM to move an object into its own
persistent NV storage under a fixed handle. A persistent object is *not* a
context blob - it lives inside the TPM's own state, survives resets by
design, and is the same mechanism `systemd-cryptenroll --tpm2-device=auto`
uses to keep a reusable SRK for LUKS unlocking. Since `tpm2_createprimary
-C o` with a fixed hierarchy+template is deterministic (already confirmed
by the reboot-survival fix above - same TPM, same template in, same key
out, every time), persisting it once is safe: it's the exact same key
either way, just computed once instead of on every login.

**Fix:**
- `bin/seal.sh`: still creates the primary fresh (needed either way, to
  get a context to persist or to compare against), but now checks whether
  a fixed handle (`0x81018000` by default, or whatever's already recorded
  in `$DATA_DIR/primary.handle` on a re-seal) already holds a persisted
  object. Empty → `tpm2_evictcontrol`s the fresh primary into it. Occupied
  → compares the *name* (`tpm2_readpublic -n`) of what's there against the
  freshly-derived primary's name: match → reuse it (idempotent re-seal, no
  wasted evictcontrol call); mismatch → hard-refuse rather than silently
  reusing or clobbering an object this tool didn't create. Records
  whichever handle actually got used in `$DATA_DIR/primary.handle`, then
  seals the child secret under that handle directly (`-C $PRIMARY_HANDLE`)
  instead of under a transient context file.
- `pam/tpm-keyring-unseal.sh`: reads `$DATA_DIR/primary.handle` if
  present and uses it directly as `tpm2_load`'s parent - skips
  `tpm2_createprimary` entirely. Falls back to the old recreate-fresh
  behavior, byte-for-byte unchanged, if the file is absent (sealed data
  from before this change, not yet re-sealed) - nothing breaks for anyone
  mid-migration, it's just still slow until they re-seal.
- `uninstall.sh`: new step evicts the persisted primary
  (`tpm2_evictcontrol -C o -c $HANDLE`, no output handle given = remove)
  before offering to delete `$DATA_DIR` - otherwise a full uninstall would
  leave an orphaned object sitting in the TPM's small number of
  persistent-object NV slots forever.
- `pam_tpm_keyring_authtok.c`: comment-only update - the 25s
  `HELPER_TIMEOUT_SECS` budget's ~7s `createprimary` term is now only paid
  on the pre-migration fallback path. Left the actual timeout value
  unchanged: the module has no way to know in advance which path a given
  login will take, and 25s is already a safe, conservative bound for both.
- `test/vm/run-vm-test.sh`: added non-assertive wall-clock timing prints
  (`elapsed_ms`) around both the same-boot and post-reboot unseal calls,
  so the speedup shows up as real evidence in the test's own output
  instead of only being asserted in prose.

**Why the handle is looked up from a file instead of hardcoded identically
in both scripts:** already burned by this exact class of mistake once -
the `TPM_KEYRING_UNLOCK_DATA_DIR` env-var removal entry above notes "the
path needs to be the same constant on both sides of the seal/unseal
boundary, an env var can't safely be that." Same reasoning applies to the
handle: `seal.sh` is the only writer, `tpm-keyring-unseal.sh` only ever
reads back whatever `seal.sh` actually used, so the two can never drift
out of sync with each other even if the default constant changes in a
future version.

**Verified, not just "should be fast":**
- `bash -n` clean on all three changed shell scripts; `gcc -Wall -Wextra`
  clean (zero warnings) on the comment-only `.c` change.
- `make test` (regex/detection + runtime/pamtester + 5-distro packaging):
  all PASS, arm64 cross-build correctly SKIPPED (no qemu binfmt registered
  locally, same as every prior run) - confirms nothing outside
  seal.sh/unseal.sh/uninstall.sh regressed, as expected (those layers
  don't exercise real TPM mechanics at all, so they couldn't have caught
  this change either way - listed for completeness, not as evidence of
  the fix itself).
- `make test-vm` (real swtpm + OVMF, throwaway secret, the layer that
  actually exercises real TPM mechanics): all 7 checks `ok`, including the
  two that matter most for this change:
  - same-boot unseal: **407ms**.
  - **post-reboot unseal: 426ms**, after a real `swtpm`+`qemu` process
    restart (a genuine TPM reset-count increment - PCR7 read back
    identical across both boots, `0xC86235C7...`) - this is exactly the
    scenario the persisted-handle approach had to prove itself against,
    since a reset-count increment is what broke the old context-file
    approach in the first place. It didn't just survive, it stayed fast.
  - The two-concurrent-unseal-calls check (the `flock` serialization fix
    from 2026-08-14) still passes - the fast path doesn't reopen that
    race; if anything it shrinks the contention window it has to defend
    from ~7s to well under half a second.
- Deliberately did not touch this machine's real
  `~/.local/share/tpm-keyring-unlock/` or run `bin/seal.sh`/
  `tpm-keyring-unseal.sh` against it directly - per CLAUDE.md, only the
  user can do that (it needs the real keyring password). Every number
  above came from the VM's own throwaway secret and its own isolated
  swtpm, never the real machine's TPM or real password.

**Not yet done - the one remaining step, and it has to be the user's:**
this machine's actual sealed secret predates this change (no
`primary.handle` file yet), so it's still on the slow fallback path today.
Re-running `bin/seal.sh` (same password as before, choosing "Overwrite"
when it asks) is what actually adopts the fast path here - can't be done
through a tool call, same as every other real-secret step in this
project.

## Installer: collapsed per-step y/N prompts into one upfront confirmation (2026-08-18)

**Problem:** `install.sh` could ask up to ~4 separate `[y/N]` questions in
one run — install missing packages, add to the `tss` group, re-seal
(if a secret already existed), and one more *per* `/etc/pam.d/*` file
that needed the helper line (can be more than one service on a system with
both `gdm-password` and a fingerprint-capable stack). User asked for this
collapsed to a single confirmation.

**Why not just drop the confirmations to make it quieter:** `CLAUDE.md`'s
"security of stored data comes first" rule explicitly calls out
`/etc/pam.d/*` edits as needing backup + explicit confirmation "even when
the change is well-understood" — removing that gate entirely to reduce
prompt count would be exactly the kind of quiet security regression the
rule exists to prevent. Silently editing PAM stacks (login-critical files)
without the user ever seeing which files or what diff was also rejected
for the same reason.

**What was done instead:** restructured `install.sh` into two phases —
1. **Plan** (read-only; no packages installed, no files touched, no sudo
   run): detect missing deps + the exact package list per package manager,
   whether the `tss` group needs joining, whether this is a fresh seal or
   a re-seal, and which `/etc/pam.d/*` files actually need the helper line
   (already-wired ones are excluded from the plan display, same
   idempotency check as before).
2. **One `confirm()` call** that prints the entire plan first — every
   package, the group change, seal vs. re-seal, and for *every* PAM file
   that will change, its literal path and the exact diff (the same
   before/after block the old per-file prompt showed) — then asks
   "Proceed with all of the above?" exactly once. A "no" changes nothing
   and exits 0.
3. **Execute**, only after a "yes", straight through with no further
   prompts.

This keeps the substance of the `/etc/pam.d/` rule (explicit, informed
confirmation before any login-critical file is touched, backup still taken
via `$TARGET.bak-<timestamp>` right before each edit) while satisfying the
actual complaint, which was about *prompt count*, not about *informedness*.

**One prompt that could NOT be collapsed away, and why:** if the user
needs adding to the `tss` group, `usermod -aG tss` doesn't take effect in
the current shell/session — the script must still stop and ask them to
log out, back in, and re-run. This isn't a confirmation being reinstated;
it's the same Linux group-membership constraint the original script also
hit (it already `exit 0`'d there). A second run of the installer after
relogin will again show one consolidated plan + one confirmation, not a
new pile of prompts.

**Incidental fix while restructuring:** the original script had a path
where, if zero `/etc/pam.d/*` services had a `pam_gnome_keyring.so` auth
line at all, it printed a message and `exit 0`'d immediately — skipping
the final "Log out and back in to test" line at the very end of the
script, even though the systemd-mask + seal steps earlier in that same run
still made a real change worth testing. Restructured version falls
through to that final message in all cases. Not part of the ask, but
clearly a bug in the original control flow (early-exit forgot the
otherwise-unconditional trailer), so fixed it alongside since the whole
"wire PAM stacks" block was being rewritten anyway.

**Verified:** `bash -n install.sh` clean; manually traced the control flow
against the original step-by-step (dependency detection → package-name
translation per distro → tss group → re-seal detection → PAM candidate
detection minus already-wired ones) to confirm the plan-phase and
execute-phase logic each still match what the original per-step code did,
just reordered around a single confirmation gate. Did not run the
installer end-to-end against this machine's real TPM/PAM stack — that
would require sudo and touch login-critical files, which per `CLAUDE.md`
needs to be run by the user themselves, not through a tool call. The VM
test suite (`test/vm/run-vm-test.sh`) and Docker packaging tests
(`test/distro/*`) don't invoke `install.sh` at all (they call
`bin/seal.sh` / the PAM-dir-detection logic in `bin/lib.sh` directly), so
they were unaffected by this change and required no update.

## Failed re-seal now preserves the previous enrollment (2026-08-22)

**Problem:** `bin/seal.sh` deleted `pcr.policy`, `seal.pub`, and
`seal.priv` immediately after the user accepted the overwrite prompt. Every
fallible operation needed to build the replacement happened afterward. A TPM
error, interruption, or full filesystem during `tpm2_create` therefore turned
a working enrollment into no enrollment at all. The two-entry password prompt
only detects entries that differ from each other; it does not prove the
resulting TPM object is loadable and unseals to the supplied bytes.

**Fix:** build the PCR policy, public/private blobs, and handle metadata in a
mode-0700 staging directory under `DATA_DIR`, leaving the installed files
untouched. Load the staged object, open a fresh PCR policy session, unseal it,
and compare the exact result to the supplied password. Only after that complete
round trip succeeds are the staged files mode-normalized to 0600 and moved into
place. Cleanup also flushes any TPM sessions/objects left live by a failed
command before deleting the staging and context directories.

Keeping staging below `DATA_DIR` is deliberate: it keeps staged files on the
destination filesystem and avoids a cross-filesystem `mv` silently becoming a
copy. This is failure-transactional for every checked command path; the four
separate destination names are still not a single power-loss-atomic filesystem
transaction, which would require a versioned state-directory format and an
atomic pointer swap. That larger format migration was not necessary to fix the
actual early-deletion bug and was deliberately kept out of this focused change.

**Regression coverage:** the real-TPM VM test now shadows only `tpm2_create`
with a helper that exits 42 during an accepted re-seal. It asserts that the
re-seal fails and then invokes the real root helper against swtpm to prove the
original secret still unseals. This would fail against the previous code
because its early `rm -f` removed the old blobs before reaching the injected
failure.

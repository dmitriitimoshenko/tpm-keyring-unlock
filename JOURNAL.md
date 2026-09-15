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
## Investigation: fingerprint "goes away" after an idle timeout at the lock screen (2026-09-14)

Not a bug in this repo, but it lands squarely on the login path this
project hooks into (`/etc/pam.d/gdm-fingerprint` is where
`pam_tpm_keyring_authtok.so` runs), so the mechanism is worth recording —
it took a disassembly to pin down and nobody should have to re-derive it.

**Symptom:** on the GNOME lock screen / GDM greeter, if you don't touch the
sensor for ~30 s, the reader stops responding entirely and the only way in
is the password. Touching it again does nothing until the prompt is reset.

**Two separate timeouts exist, with different values:**

- `/etc/pam.d/common-auth` has `pam_fprintd.so max-tries=1 timeout=10` —
  that's Debian's shipped `pam-configs` snippet
  (`/usr/share/pam-configs/fprintd`), not something we set. It governs
  `sudo`, polkit and `gdm-password`: 10 s, one attempt.
- `/etc/pam.d/gdm-fingerprint` has a bare `auth required pam_fprintd.so`,
  so it uses the module defaults, documented in `man 8 pam_fprintd`:
  `timeout` = 30 s, `max-tries` = 3. This is the lock-screen path, and it
  matches the observed ~30 s.

**Root cause of the "and then it's gone" part** — the non-obvious bit.
On timeout, `pam_fprintd` does *not* return `PAM_AUTH_ERR`; it returns
`PAM_AUTHINFO_UNAVAIL` (9), i.e. "this authentication method is not
available", the same code it would use for a missing reader. Confirmed by
disassembling the module (`fprintd` 1.94.5), since Ubuntu ships no source:

    objdump -d --no-show-raw-insn /usr/lib/x86_64-linux-gnu/security/pam_fprintd.so

The timeout branch sets its `timed_out` flag, emits "Verification timed
out" as a `PAM_TEXT_INFO` (msg style 4, *not* `PAM_ERROR_MSG` 3 — so it is
not even reported as a failure), then falls to the shared exit at `0x3360`
which is literally `mov $0x9,%edx` → `PAM_AUTHINFO_UNAVAIL`. A finger
*mismatch* takes the other branch: `PAM_ERROR_MSG` + `mov $0x7,%edx`
(`PAM_AUTH_ERR`). That difference is the whole story.

From there the chain is deterministic:

1. `gdm-session-worker` maps `PAM_AUTHINFO_UNAVAIL` onto its
   `service-unavailable` signal /
   `org.gnome.DisplayManager.SessionWorker.Error.ServiceUnavailable`
   (strings present in `/usr/libexec/gdm-session-worker`).
2. gnome-shell 50.1 `/org/gnome/shell/gdm/util.js` (extract with
   `gresource extract /usr/lib/gnome-shell/libshell-18.so /org/gnome/shell/gdm/util.js`):
   `_onServiceUnavailable()` does `this._unavailableServices.add(serviceName)`.
3. `_onConversationStopped()` opens with
   `if (this._unavailableServices.has(serviceName)) return;` — which skips
   the `_verificationFailed(serviceName, true)` → `_retry()` path that
   would otherwise restart the reader. `_shouldStartBackgroundService()`
   rejects the service for the same reason.
4. `_unavailableServices` is cleared only in `_onReset()`. So the reader is
   out for the remaining life of that auth prompt.

That also explains why a *wrong finger* doesn't kill it: that path goes
through `_onProblem()`, increments `_failCounter`, and keeps retrying up to
`gsettings get org.gnome.login-screen allowed-failures` (3 here).

> **Partly superseded (same day, later):** true only for a *clean* mismatch
> (`verify-no-match`). A bad *scan* can come back as `verify-unknown-error` or
> `verify-disconnected`, which return `PAM_AUTHINFO_UNAVAIL` just like the
> timeout does and kill the reader for the rest of the prompt. See the
> correction entry at the end of this file.

**Workaround with no config change:** press Esc / let the screen blank and
wake it — the prompt resets, `_onReset()` clears the set, reader is armed
again.

**Actual fix (needs the user, sudo + login-critical file):** give
`gdm-fingerprint` a longer or unlimited window, e.g.
`auth required pam_fprintd.so timeout=-1` (per the man page a negative
value means no limit, reader stays armed while the module is loaded), or a
plain `timeout=300`. `common-auth`'s 10 s can be raised the same way, but
that file is regenerated by `pam-auth-update`, so the edit belongs in
`/usr/share/pam-configs/fprintd` (or a local pam-config) followed by
`pam-auth-update`, otherwise the next `fprintd` upgrade reverts it.
Not applied — needs explicit confirmation and a backup per `CLAUDE.md`.

**Side observation relevant to us** (briefly fixed by the attempt stack's
`default=die`, then deliberately un-fixed when failures were made to fall
through to the next attempt - the final word is in the security re-review
entry at the end of this file; the behaviour today is the same as the
distro's own): in `gdm-fingerprint`, `pam_fprintd.so` is `required`, not
`requisite`. libpam keeps running the rest of the auth
stack after a `required` module fails, so a *failed or timed-out*
fingerprint attempt still invokes `pam_tpm_keyring_authtok.so` and still
performs a TPM unseal. The secret goes nowhere (auth fails, `PAM_AUTHTOK`
is discarded, no session opens), but the unseal is triggerable by anyone
at the lock screen. Changing that line to `requisite` would short-circuit
the stack on fingerprint failure and avoid the pointless unseal; nothing
later in that stack needs to run on a failed attempt. Not changed — again
a login-critical `/etc/pam.d` edit, and it's gdm's own file, so an upgrade
would revert it. Recorded as a known property, not a hole.

## Installer now offers `timeout=-1` on the fingerprint stack (2026-09-14, later)

Follow-up to the investigation entry above, which explains *why* the reader
disappears after 30 idle seconds. This is the fix, wired into `install.sh`
as an opt-out step, plus a real bug the work uncovered.

### Shape of the feature

`install.sh` detects PAM services eligible for `timeout=-1`, asks one
`[Y/n]` question (empty answer = yes), and then folds the answer into the
existing single plan + single approval gate. `uninstall.sh` reverses it.
Detection, rewriting and the safety predicate all live in `bin/lib.sh`, so
installer, uninstaller and tests can't drift apart — same reasoning as the
existing `PAM_GNOME_KEYRING_AUTH_RE`.

### Why a second prompt at all, and why *before* the plan

The 2026-08-18 entry collapsed per-step y/N prompts into one upfront
confirmation, and that decision stands: this is not a step prompt. It's a
*policy* question whose answer changes what the plan says, so it's asked in
the plan phase, before anything is printed or touched, and the plan then
lists the resulting edit like any other. Execution still runs start to
finish with no questions. Declining leaves that file untouched and changes
nothing else about the install.

`confirm_default_yes()` treats a failed `read` (EOF, i.e. a non-interactive
run) as **no**, not yes. A piped-in install must never be able to opt
*into* editing a login-critical file by accident; the final gate would abort
the run anyway, but the default should not depend on that.

### The safety rule: fingerprint-only stacks, never a shared one

`pam_auth_is_fingerprint_only()` is the entire safety argument, and it's a
whitelist, not a blacklist. A stack qualifies only if every auth-phase line
is a module that can't let anyone in by itself (`pam_nologin`,
`pam_succeed_if`, `pam_faillock`, `pam_gnome_keyring`, our own module,
fprintd itself) and it `@include`s nothing that could carry auth lines.
Anything else — `pam_unix`, `pam_sss`, an `auth include system-auth`, an
unrecognised module — disqualifies the file.

The thing this prevents is applying `timeout=-1` to `common-auth`, which is
exactly where Ubuntu puts fingerprint for `sudo`/polkit. PAM is strictly
serialised (`man 8 pam_fprintd`, LIMITATIONS): `common-auth` runs
`pam_fprintd` and then `pam_unix`, so an unlimited fingerprint wait there
would mean `sudo` blocks on the sensor forever and never reaches its
password prompt. GDM is the opposite case and the reason this is safe at
all: it runs `gdm-fingerprint` and `gdm-password` as two separate PAM
conversations in parallel, so a fingerprint stack that waits forever costs
nothing.

Verified against this machine: the predicate accepts
`/etc/pam.d/gdm-fingerprint` and refuses `common-auth`, `gdm-password`,
`sudo` and `login`.

### Why `timeout=-1` and not `timeout=300`

`man 8 pam_fprintd` documents a negative value as "no limit at all", but the
same page documents a *minimum* ("1 second being the minimum") and the
module contains the string `timeout %d secs too low, using %d` — so a
plausible failure mode was `-1` being clamped up to 1 second, which would
have made the problem dramatically worse rather than fixing it. Checked in
the disassembly before shipping it (`objdump -d` on
`/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so`, fprintd 1.94.5):

    3f43:  call  strtol
    3f4f:  test  %eax,%eax
    3f51:  js    4016          <-- negative jumps here
    ...
    4016:  movl  $0xffffffff,0x4154(%rip)   <-- timeout = -1, stored verbatim

The clamp is only reached when the parsed value is exactly `0` (`3f6d: movl
$0x1,...`). Negative values are stored as `-1` and never clamped, as
documented. `max-tries` has the identical shape a few instructions later.

Capability is probed per machine by `pam_fprintd_supports_timeout_option()`,
which greps the installed module binary for the `timeout=` option string
rather than parsing a version — `pam_fprintd` has no `--version`, and distro
version strings don't map cleanly onto when the option landed. An older
module would log the argument as unknown and carry on, so a false negative
costs only a skipped step.

### Rewriting details that matter

- The rewriter is comment-aware. Debian ships
  `pam_fprintd.so max-tries=1 timeout=10 # debug`, and appending an option
  after that `#` would silently comment it out instead of applying it. The
  option is written before any trailing comment, and the comment stays last.
- Anchored to the **auth** phase. `gdm-fingerprint` also has a
  `password required pam_fprintd.so` line (enrollment, not verification);
  a verification timeout there would mean nothing.
- Idempotent both ways, so a re-run is a no-op rather than a second edit.
- `pam_fprintd_clear_unlimited_timeout()` (uninstall) removes only the
  literal `timeout=-1`, restoring the module's own default. That *is* the
  original state for the bare line gdm ships, but not for a stack that had
  some other explicit value, so the `.bak-<timestamp>` copy stays the
  exact-restore path. Documented in both the code and the README.
- Writes go `sudo cp <tmp> <target>` — onto the existing file, not replacing
  it — so mode and ownership stay exactly as the distro shipped them.
- Before writing, the result must still look like the same file: identical
  line count (`grep -c ''`, which counts a final unterminated line too) and
  the fprintd auth line still an fprintd auth line now carrying
  `timeout=-1`. Otherwise the file is left untouched with a message. Cheap
  insurance on a login-critical file.

### Bug found while dry-running this: the installer was patching its own backups

`install.sh` scanned `/etc/pam.d/*`, which globs in the `.bak-<timestamp>`
files **it creates itself**. So it treated old backups as services to wire
the module into, and then backed those up in turn. The dry run
(`printf 'y\nn\n' | ./install.sh`, which changes nothing since nothing is
touched before the approval gate) printed the evidence plainly:

    /etc/pam.d/gdm-password.bak-20260813220005.bak-20260817001908

This machine already had 7 leftover `.bak-*` files in `/etc/pam.d/`, one of
them carrying our injected line. Not a live security hole — PAM only ever
opens the file whose name matches the service being authenticated, so a
`gdm-password.bak-...` file is never read — but it's litter that grows on
every run, and it would have hit the new fingerprint step too (a
`gdm-fingerprint.bak-*` file is a fingerprint-only stack by every test that
matters). Fixed with `PAM_BACKUP_RE` in `bin/lib.sh`, excluded in every
detection loop in both scripts.

The existing leftovers are deliberately left alone: they're the user's only
pristine copies of those files, and rewriting or deleting someone's backups
isn't the uninstaller's business. `uninstall.sh` now skips them rather than
offering to edit them.

Second, smaller fix in the same area: backups are now taken once per run via
`backup_pam_file()` against a single run-wide `RUN_TS`. Both PAM steps can
touch the same file (`gdm-fingerprint` is eligible for the timeout edit
*and* a wiring candidate), and with a per-edit `date +%Y%m%d%H%M%S` the
second backup would land on the same name within the same second and
overwrite the first — leaving a "backup" of the already-half-edited file
instead of the pristine one.

### Verified

- `./test/unit-regex-test.sh`: 31 checks pass, 20 of them new — selector
  accepts/refuses the right fixtures, the rewrite lands before the `#`
  comment, the password-phase line survives, line count is preserved,
  set-then-clear restores `fprintd-only` byte for byte, both directions
  idempotent. New fixtures: `fprintd-only`, `fprintd-shared`,
  `fprintd-unlimited`.
- Dry runs of the real installer on this machine, answering `y` then `n` and
  `n` then `n` at the two prompts: the eligible list is exactly
  `/etc/pam.d/gdm-fingerprint`, the plan item appears or doesn't according to
  the answer, and the plan no longer lists any `.bak-*` file.
- **Not** verified: the actual lock-screen behavior with `timeout=-1`
  applied. That needs the edit to be live (sudo, user's own terminal) and a
  real lock screen. The change was not applied to this machine as part of
  this work.

### Note for whoever edits these scripts next

Splicing multi-line blocks in with `perl -0pi -e 's|...|...|g'` went badly
wrong here: it inserted the replacement after *every character* of
`uninstall.sh` (5113 lines out of 103) and prepended a stray line to
`install.sh`. Recovered `uninstall.sh` from `git` (its only uncommitted
change was re-appliable) and deleted the stray line from `install.sh`. Use
the awk form instead, which is what every other block insertion here used
and none of them misfired:

    awk -v bf=block.txt 'BEGIN{while((getline l < bf)>0) b=b l ORS}
      !done && /anchor/ {printf "%s", b; done=1} {print}' file > file.new

Always `bash -n` and `git diff` afterward — `bash -n` alone would have
passed the corrupted `install.sh`, since a stray `if [[ ... ]]; then
continue; fi` line is perfectly valid syntax.

## Correction + extension: one bad scan kills the reader too, `timeout=-1` alone doesn't help (2026-09-14, later still)

**Supersedes a claim in the two entries above.** They said a wrong finger
"behaves completely differently - that's a plain auth failure, and retries
keep working". That is true only for a *clean* mismatch. It came up because
the user reported, from actual use, that after putting a finger on the sensor
at a bad angle the lock screen offers nothing but the password - which the
earlier explanation didn't account for.

### What the module actually does with each verify result

Read out of `pam_fprintd` 1.94.5's machine code (the strcmp chain that
dispatches on the `VerifyStatus` string, around `0x34c8`-`0x3760`):

| result | return | effect |
|---|---|---|
| `verify-no-match` | `PAM_AUTH_ERR`, and `max-tries--` | retried inside the module |
| `verify-unknown-error` | `PAM_AUTHINFO_UNAVAIL` | conversation over |
| `verify-disconnected` | `PAM_AUTHINFO_UNAVAIL` | conversation over |
| idle timeout | `PAM_AUTHINFO_UNAVAIL` | conversation over |
| anything else / NULL | `PAM_ERROR_MSG` + `PAM_AUTH_ERR` | plain failure |

The tries counter is decremented **only** in the `verify-no-match` branch
(`0x34f6: subl $0x1,0xc(%rbx)`); the two error results jump straight to the
shared `0x3360: mov $0x9,%edx` exit. So `max-tries=` has no effect whatsoever
on a bad scan, and a bad scan lands in exactly the same
`PAM_AUTHINFO_UNAVAIL` -> `service-unavailable` -> gnome-shell
`_unavailableServices` dead end as the idle timeout. That is the user's
symptom, and `timeout=-1` does nothing for it.

Which of `verify-unknown-error` / `verify-disconnected` a given reader emits
for a bad scan is driver-specific and was **not** established here (this
machine is a Goodix MOC via `libfprint-2-tod1`). `fprintd-verify` in a
terminal prints the result string per scan and needs no sudo and no config
change, if that ever needs pinning down.

### The fix: attempts, not a longer deadline

PAM has no loop construct, so the only way to get another attempt is to invoke
the module again - each `pam_sm_authenticate()` re-claims and re-arms the
device. `pam_fprintd_harden()` therefore rewrites the single line into:

    auth  [success=2 authinfo_unavail=ignore default=die]  pam_fprintd.so timeout=-1
    auth  [success=1 authinfo_unavail=ignore default=die]  pam_fprintd.so timeout=-1
    auth  required                                         pam_fprintd.so timeout=-1

- `authinfo_unavail=ignore` is the whole point: a bad scan falls through to the
  next attempt instead of ending the conversation.
- `success=N` is a relative jump over the *remaining attempts only*, so a match
  still falls through to `pam_tpm_keyring_authtok.so` and
  `pam_gnome_keyring.so`. `success=done` would have been wrong - it returns
  from the stack immediately and would have skipped the keyring unseal, i.e.
  broken the entire point of this repo for fingerprint logins.
- `default=die` keeps a real mismatch behaving as before, and as a side effect
  fixes the "pointless unseal on a failed fingerprint" note from the first
  entry above: a mismatch now stops before `pam_tpm_keyring_authtok.so`.
  **[Superseded the same day:** once mismatches were made to fall through to
  the next attempt, the last line - the distro's own `required` one - decides,
  and `required` keeps running the rest of the stack, so a fully failed
  attempt reaches `pam_tpm_keyring_authtok.so` again. Same as the distro's
  original behaviour; see the security re-review entry at the end.**]**
- The service's own line stays as the last attempt with its original control
  field, so the distro's semantics for the final verdict are untouched.

### The trap this nearly walked into, and how it was caught

Debian's generated `/etc/pam.d/common-auth` carries this comment:

    # prime the stack with a positive return value if there isn't one already;
    # this avoids us returning an error just because nothing sets a success code
    # since the modules above will each just jump around
    auth	required			pam_permit.so

Read literally, that says a `success=N` jump does **not** record a positive
result for the stack - which would mean a matched finger on attempt 1 or 2
jumps over the remaining attempts, lands on two `optional` modules that record
nothing, and the stack ends with no positive impression: fingerprint login
broken outright, on a login-critical file. Reasoning from the libpam source
from memory wasn't good enough for that, so it was tested for real instead.

`test/fixtures/pam_flow_stub.c` (new) stands in for `pam_fprintd.so` - it takes
`mark=` and `ret=` module arguments, appends its mark to a log and returns
`PAM_SUCCESS` / `PAM_AUTHINFO_UNAVAIL` / `PAM_AUTH_ERR` on demand - and
`test/runtime-test.sh` builds the service file out of what
`pam_fprintd_harden()` actually generates, then runs `pamtester` against real
libpam in the container. Result: **the jump does record success.** All five
cases pass:

    match on the 1st attempt: succeeds and still reaches the keyring lines
    bad scan then match: 2nd attempt runs, stack still succeeds
    two bad scans then match: 3rd attempt runs, stack still succeeds
    three bad scans: stack fails (no unauthenticated success)
    mismatch: dies on the spot, no further attempts, no TPM unseal

So no `pam_permit.so` primer is needed in our shape (Debian needs one because
their jumps land past a `requisite pam_deny.so`, on a line that would
otherwise record nothing). Worth keeping the test: if that ever changes, the
failure mode is "nobody can log in with a fingerprint", which is not something
to discover on a lock screen.

### Installer / uninstaller

Still exactly one `[Y/n]` question, asked before the plan, now covering both
effects - no new prompts. The plan prints the three lines it will write. The
write guard changed shape: line count is no longer preserved, so it now
requires that every line which is *not* an auth-phase fprintd line is byte for
byte identical, that the result has exactly `PAM_FPRINTD_ATTEMPTS` fprintd auth
lines, and that exactly `PAM_FPRINTD_ATTEMPTS-1` of them are generated ones.
Eligibility is now simply "hardening it would change something, there is
exactly one real fprintd auth line, and the stack is fingerprint-only" -
`pam_fprintd_harden <file> | cmp -s - file` is both the idempotence check and
the already-done check. `uninstall.sh` mirrors it with
`pam_fprintd_unharden`, under the same invariant.

Generated lines are identified by `authinfo_unavail=ignore` in the bracketed
control rather than by a trailing marker comment - that way nothing in this
tool depends on whether libpam strips trailing comments, which is an open
question (Debian's own `# debug` suffix suggests it does, but it was never
verified and now doesn't need to be).

### Verified

- `./test/unit-regex-test.sh`: all green, 36 checks (new fixture
  `fprintd-hardened`, generated by the real function; jump distances,
  idempotence, harden/unharden round trip, "every other line untouched").
- `docker run` of `test/runtime-test.sh`: the five control-flow cases above,
  plus the pre-existing `PAM_AUTHTOK` cases.
- Installer dry run (`printf 'y\nn\n' | ./install.sh`): one eligible file,
  `/etc/pam.d/gdm-fingerprint`, and the plan prints the exact three lines.
- **Not** verified: real fingerprint hardware behaviour with the stack live.
  That's the user's own test - uninstall, install, reboot, try a bad-angle
  scan and see whether the reader comes back for a second and third go.

## All prompts default to yes, and the scripts refuse to run without a terminal (2026-09-14, last)

Two changes, both prompted by a real failed run.

**1. `[y/N]` -> `[Y/n]` everywhere.** `confirm()` in `install.sh` and
`uninstall.sh` now accepts on an empty answer, and the separate
`confirm_default_yes()` added earlier today is gone - one helper, one
behaviour. `bin/seal.sh`'s inline "A sealed secret already exists. Overwrite?"
prompt got the same treatment, since it is asked *during* an `install.sh` run
and a different default in the middle of the same flow is exactly the
inconsistency being removed. Worth knowing what Enter now means in the two
places where it costs something: it removes you from the `tss` group (which
forces a relogin plus a second `install.sh` run afterwards) and it overwrites a
working seal (which means retyping the keyring password).

A "no" is still `n`/`no`, and anything else counts as yes, matching the `[Y/n]`
label.

**2. A missing terminal is now a hard stop.** The failed run that prompted
this was `./uninstall.sh` with no tty:

    Found the injected line in /etc/pam.d/gdm-autologin
    ... (7 files, every confirm silently declined on EOF)
    sudo: A terminal is required to authenticate

Two separate problems in one output. Every `confirm()` hit EOF and declined, so
the file list looked like it was being processed when nothing was; then step 2
(removing the installed module) has no confirm at all and went straight to
`sudo`, which failed for lack of a tty, and `set -e` aborted mid-uninstall.
With prompts now defaulting to yes, a non-interactive run is even less
acceptable, so `install.sh`, `uninstall.sh` and `bin/seal.sh` all check
`[ -t 0 ]` up front and exit 1 with an explanation.

`read ... || return 1` stays in `confirm()` as the second line of defence: if
the tty check is ever bypassed, EOF still declines rather than accepting. For
`bin/seal.sh` the check matters for its own reason - it reads a password with
`read -rsp`, and that must come from a terminal, never from a pipe or a file.

Side effect on how the installer gets dry-run during development: piping
answers into it (`printf 'y\nn\n' | ./install.sh`) no longer works, since
that's precisely the case now refused. Use a pty:

    printf '\nn\n' | script -qec './install.sh' /dev/null

Nothing in `test/` invokes these three scripts (the suite exercises
`bin/lib.sh`'s logic and the compiled module directly), so the tty check
doesn't affect the test suite - checked before adding it.

## Diagnostic: "Chrome asks for the keyring password after installing" - the install had not actually finished (2026-09-14, last)

Reported symptom: installed, not yet rebooted, and opening Chrome brings up a
password prompt. Worth recording because the state looked like "installed but
broken" and was actually "not installed", and because the journal evidence
distinguishing the two is easy to miss.

State on the machine at the time: no `~/.local/share/tpm-keyring-unlock`, no
`pam_tpm_keyring_authtok.so` in the PAM module dir, no
`/usr/local/sbin/tpm-keyring-unseal`, no injected lines in any
`/etc/pam.d/*`, and `gdm-fingerprint` still carrying a bare
`auth required pam_fprintd.so`. Nothing was installed.

What the journal showed, in order:

    22:36  sudo sed -i /pam_tpm_keyring_authtok\.so/d ...   (uninstall)
    22:41  sudo gpasswd -d dmitrii tss                      (uninstall)
    22:43  sudo usermod -aG tss dmitrii                     (install.sh, run 1)
    22:44  relogin
    (nothing after that)

`install.sh` run 1 did its one step - adding the user back to `tss` - and
exited by design, since group membership only applies to new sessions. Run 2,
the one that actually seals and installs, never happened. `tpm2_pcrread`
succeeds in the post-relogin session, so run 2 will go all the way through.

The prompt itself is the unfixed original gap, not a regression, and the login
that produced it says so exactly:

    gdm-password][4338]: gkr-pam: no password is available for user
    gdm-password][4338]: gkr-pam: gnome-keyring-daemon started properly

Two things to read there. First, "no password is available for user" on
*gdm-password*: with system-wide fprintd enabled, that stack can be satisfied
by a fingerprint, so no typed password ever reaches `PAM_AUTHTOK` - the whole
reason this project exists. Second, the success line is "started properly"
with **no** "and unlocked keyring" suffix, unlike a working login:

    gkr-pam: gnome-keyring-daemon started properly and unlocked keyring

That suffix is the quickest way to tell a working install from a
non-working one in the journal, and it is worth checking first next time
someone reports a keyring prompt.

Also worth remembering for anyone testing this: the PAM stack only runs at
login, so a session that started before the install keeps its locked keyring
until the next login, no matter what is on disk. "Installed but still
prompting" is expected until logout/login.

No code change from this - the uninstall/install cycle behaved as designed.
The one rough edge is that `install.sh`'s tss step exits with a message that
is easy to read as "done" rather than "half done"; left alone for now, noted
here in case it comes up again.

## One-run install: continue inside `sg tss` instead of stopping for a relogin (2026-09-14, last)

Prompted directly by the entry above - the install that "didn't work" was
really an install that stopped halfway by design, which is easy to misread as
finished. Removing the stop removes the failure mode.

### Why it stopped

`install.sh` adds the user to `tss` for passwordless TPM access, but a
process's supplementary group list is fixed when its session starts, so the
current shell can't use the group it was just granted. Every TPM step
afterwards (`tpm2_pcrread`, `bin/seal.sh`) would fail, so the script printed
"log out and back in, then re-run" and exited 0.

### The fix

`sg tss -c <command>` runs a command in a shell whose group list is read fresh
from the database, so the run continues in the same session. Only the two
TPM-touching steps go through it, via a `tpm_run()` wrapper; everything else
(package install, compile, `sudo install`, the `/etc/pam.d/` edits) runs
exactly as before.

Checked before relying on it, on this machine:

    $ script -qec "sg tss -c 'echo tty=$([ -t 0 ] && echo yes || echo no); \
        echo primary=$(id -gn); echo all=$(id -nG)'" /dev/null
    tty=yes
    primary=tss
    all=tss adm cdrom sudo dip plugdev users lpadmin docker dmitrii

Three things that mattered there:

- **tty=yes** - `seal.sh` reads the keyring password with `read -rsp`, which
  must come from a terminal, never a pipe. `sg` keeps it.
- **supplementary groups survive**, `sudo` among them, so the privileged steps
  later in the run still work.
- **primary group becomes `tss`**, which is the one real side effect: files
  created inside that shell would be group-owned by `tss`. `$DATA_DIR` is 700
  so nothing is exposed, but `bin/seal.sh` now sets an explicit `chmod 600` on
  `seal.pub`, `seal.priv`, `pcr.policy` and `primary.handle` rather than
  trusting the umask. Worth doing on its own merits.

`sg` is not an escalation: it grants a group the same run has just legitimately
added with the user's own `sudo`, and it cannot grant anything the group
database doesn't already say the user has.

### Guards

`USE_SG` is only set when a direct `tpm2_pcrread` fails **and** `sg` exists
**and** `id -nG "$USER"` already lists `tss` in the database. That last
condition matters for more than correctness: `sg` prompts for a *group
password* when the caller isn't a member, and a prompt there would hang the
installer. Requiring established membership means it never reaches that path.

If `sg` is missing or still can't read the PCRs, the old behaviour is the
fallback - explain, and ask for a logout plus a re-run - with a message that
now says explicitly that everything else is still pending, since "it exited 0"
reading as "it finished" is exactly what went wrong before.

### Test

`test/distro/test-packaging.sh` now checks the mechanic on all five distros,
because `sg` comes from shadow-utils and neither its presence nor its
behaviour is guaranteed to be identical everywhere.

> **Superseded the same day (see the security re-review entry, §8):** the
> first version of this test held an `su` shell open on a fifo to reproduce a
> stale group list, and hung the openSUSE and Debian containers. It was
> replaced with a `setpriv` version that builds the same state directly. The
> three questions it asks are unchanged:

    id -nG                           -> must NOT list the new group (stale, as expected)
    sg <group> -c 'id -nG'           -> must list it
    sg <group> -c 'id -nG'           -> must still list the user's other groups

Each `sg` call is wrapped in `timeout 10`, so a distro where it decides to
prompt fails the test instead of hanging the suite. A distro with no `sg` at
all prints a note rather than failing - the fallback path still works there,
it just costs the second run.

### Known limitation

`sg` runs its command through the user's login shell, and the command is
assembled with `printf %q`, which is POSIX-shell quoting. A user whose login
shell is `fish` could see that mis-parse. Not handled: the arguments involved
are a fixed command name and an absolute repo path, `sg` failing is caught by
the PCR re-check, and the fallback is the old relogin path. Noted here rather
than solved.

## Correction: `default=die` made a mismatch cost the whole stack; one line is now one scan (2026-09-14, last)

User feedback after running the real thing: "всё работает, но ретраев при
неправильном пальце нет" - the install works, but a wrong finger gets no
retries. Correct, and it was my design decision, made for a bad reason.

**Supersedes** the "default=die keeps a real mismatch behaving exactly as
before" reasoning in the attempt-stack entry above.

### What was wrong with it

The stack counted failures in two different places:

- a *bad scan* -> `PAM_AUTHINFO_UNAVAIL` -> `authinfo_unavail=ignore` ->
  one attempt line consumed;
- a *mismatch* -> retried **inside** one module call, because each line
  inherited pam_fprintd's own `max-tries` default of 3, and only after those
  three did the line return `PAM_MAXTRIES` -> `default=die` -> stack over.

So "three attempts" meant three different things depending on how you failed,
a mixed run could cost up to nine finger placements, and - what the user
actually hit - the `default=die` half made a mismatch end the conversation the
moment the module gave up, with the two remaining attempt lines never running.

### The rule now: one line = one scan = one attempt

    auth  [success=2 <fall through>]  pam_fprintd.so max-tries=1 timeout=-1
    auth  [success=1 <fall through>]  pam_fprintd.so max-tries=1 timeout=-1
    auth  required                    pam_fprintd.so max-tries=1 timeout=-1

with `<fall through>` = `authinfo_unavail=ignore auth_err=ignore
maxtries=ignore default=die`.

- `max-tries=1` takes the module's internal counter out of the picture, so the
  stack does all the counting and every failure kind is worth exactly one
  attempt.
- With `max-tries=1` a single `verify-no-match` returns `PAM_MAXTRIES` rather
  than `PAM_AUTH_ERR` (the counter hits zero on the first decrement), hence
  `maxtries=ignore`; `auth_err=ignore` covers the unrecognised-result and
  NULL-result paths, which return `PAM_AUTH_ERR`.
- `default=die` stays, now meaning only what it should: an aborted
  conversation, a system error, no enrolled prints - genuinely broken states
  that should not be retried three times over.

Total scans per prompt is 3, which is exactly what pam_fprintd's own
`max-tries=3` default allowed before any of this work. Nothing got looser;
what changed is that all failure kinds now count toward the same three.

Cost: `unharden` now has to strip `max-tries=1` as well as `timeout=-1`, so a
stack that shipped with its own explicit `max-tries` gets the module default
back rather than its original value. Same caveat as `timeout`, same answer -
the `.bak-<timestamp>` copy is the exact-restore path. Verified that
harden->unharden on the distro's bare line still returns it byte for byte, and
that hardening the *already-installed old shape* upgrades it cleanly (the old
attempt lines are dropped and regenerated, since they match
`PAM_FPRINTD_RETRY_LINE_RE` either way).

### Test

`test/fixtures/pam_flow_stub.c` gained `ret=maxtries` and `ret=abort`, and
`test/runtime-test.sh` now runs nine control-flow cases against real libpam,
all passing:

    match on the 1st attempt: succeeds and still reaches the keyring lines
    bad scan then match: 2nd attempt runs, stack still succeeds
    two bad scans then match: 3rd attempt runs, stack still succeeds
    three bad scans: stack fails (no unauthenticated success)
    mismatch (PAM_MAXTRIES) then match: 2nd attempt runs, stack succeeds
    unrecognised result (PAM_AUTH_ERR) then match: 2nd attempt runs
    mixed failures still cost one attempt each, and the 3rd can match
    three mismatches: all three attempts run, then the stack fails
    aborted conversation: dies on the spot, no further attempts

The last one is the guard that `default=die` still does its job; the two
"three failures" cases are the guard that no failure path can end in an
unauthenticated success.

### Note on the installed machine

The first version of the stack was already live on this machine when the
feedback came in. `install.sh` picks the upgrade up on its own: eligibility is
"hardening would change something", and the old attempt lines are regenerated
rather than appended to, so re-running it is enough - no uninstall needed.

## Security re-review of everything added today (2026-09-14, final)

Asked for explicitly after the stack was confirmed working on real hardware.
Re-checked the live machine, the whole diff, and the claims in the docs.
Findings, in order of how much they mattered.

### 1. A claim in this journal had gone stale (fixed)

Two earlier entries said `default=die` had fixed the "a failed fingerprint
still runs a pointless TPM unseal" side observation. That was true of the
first version of the attempt stack and **stopped being true** when failures
were made to fall through: the last attempt line is the distro's own
`required` one, and libpam keeps walking the stack after a `required` module
fails, so `pam_tpm_keyring_authtok.so` below it runs and performs an unseal
even when nobody authenticated. Both places are now marked superseded in
place, and the behaviour is documented in README's threat-model section
rather than left implicit.

Assessment, stated plainly: this is **not** a regression introduced by any of
today's work - it is exactly what `gdm-fingerprint` did before this tool ever
touched it (same `required` line, same optional module under it). The login
still fails, `PAM_AUTHTOK` is discarded, no session opens, and the unseal
happens inside gdm's root worker. What it does mean is that someone at a
locked screen can make the TPM perform an unseal by touching the sensor. The
seal's policy is bound to PCR7, i.e. to the machine's state, never to who is
standing there, so an unseal being *possible* at the lock screen is inherent
to the design, not a leak. Changing the distro's line to `requisite` would
avoid it; deliberately not done, since rewriting that control field is a
bigger change to someone else's file than this buys.

### 2. Dead code removed from bin/lib.sh

`pam_fprintd_set_unlimited_timeout`, `pam_fprintd_clear_unlimited_timeout`
and `_pam_fprintd_rewrite_timeout` - the first version of the fix, before the
attempt stack - were left behind with no callers anywhere. Removed (48 lines).
Worth doing rather than leaving tidy-looking dead weight: they perform a
*partial* transformation (timeout, no attempt lines), so a later edit calling
one of them by mistake would silently produce a stack that looks hardened and
isn't. `grep -rn --include='*.sh'` over the repo confirms harden/unharden are
now the only entry points.

### 3. Live machine audit

    /etc/pam.d/gdm-fingerprint          -rw-r--r-- root:root
    /etc/pam.d/*.bak-*                  -rw-r--r-- root:root
    /usr/local/sbin/tpm-keyring-unseal  -rwx------ root:root
    .../security/pam_tpm_keyring_authtok.so  -rw-r--r-- root:root
    ~/.local/share/tpm-keyring-unlock   drwx------ dmitrii:dmitrii
    ~/.local/share/.../seal.priv,.pub,pcr.policy,primary.handle
                                        -rw------- dmitrii:dmitrii

The PAM file kept the distro's own mode and owner, which is what writing with
`cp` *onto* the existing file (rather than replacing it) is for. Backups match
the originals. Sealed files are 600, from the explicit `chmod` added when
`sg tss` made the primary group non-obvious - and note the group is `dmitrii`,
not `tss`, meaning this install didn't need the `sg` path at all.

### 4. Can the stack ever authenticate nobody?

Walked the live file again. Only three lines can record a positive result -
the three `pam_fprintd.so` attempts. `pam_nologin` is `requisite`,
`pam_succeed_if` is `required` (so a root attempt leaves a negative that
nothing below can clear), and the two keyring modules are `optional`, which
never record anything. Every failure path therefore ends with either an
immediate abort or the last `required` line's failure. The container tests
assert the two exhaustion cases directly ("three bad scans" and "three
mismatches" -> stack fails). No path reaches success without a matching
finger.

Worst realistic breakage is the opposite direction: a malformed stack would
break *fingerprint* login, and the password path is a separate PAM service
(`gdm-password`), so it cannot lock anyone out.

### 5. Injection / tampering surface of the rewriter

The generated attempt lines copy the module options verbatim from the
service's own line. That text cannot contain a newline (awk works line at a
time), and it lands after the bracketed control, so it cannot forge a control
field - the worst it can do is pass bogus options to pam_fprintd, which logs
and ignores them. The write guard then refuses anything where a non-fprintd
line changed or the attempt count is off. And the input is a root-owned file
in the first place: anyone able to poison it already has root.

`tpm_run`'s `sg tss -c "$(printf '%q ' "$@")"` only ever receives a fixed
command name and `$REPO_DIR`, both `%q`-quoted.

### 6. The one thing that got looser, on purpose

`[y/N]` -> `[Y/n]` everywhere, at the user's explicit request. Enter now
accepts. Two places where that costs something are called out in the entry
above (tss removal, seal overwrite). EOF still declines, and all three scripts
refuse to run without a terminal, so nothing can be auto-approved by a pipe.

Everything else added today only tightens: 600 on the sealed files, the tty
guards, one pristine backup per run instead of a backup of a half-edited file,
and the installer no longer treating its own `.bak-*` files as services to
patch.

### 7. Documentation gaps found and filled

- README: the fprintd capability probe (the step is skipped entirely on
  fprintd older than 1.94, detected by probing the module binary for the
  `timeout=` option string, not by parsing a version).
- README threat model: the failed-attempt unseal described in §1.
- `test/README.md`: the `sg` mechanic test, including why an image without
  `sg` or without `su` skips rather than fails.
- This entry's §1 corrections, marked superseded in place per the rules at the
  top of the file.

No network access anywhere in the installed path, no `eval`, no secret
handling changed: `bin/seal.sh` still reads the password with `read -rsp` and
pipes it straight into `tpm2_create -i-`, and that code was not touched today
beyond the added `chmod`.

### 8. The `sg` test itself had to be rewritten (added during this review)

The cross-distro test written for the one-run install hung the suite twice,
which is worth recording because both failures were in the *test*, not the
thing under test.

First failure, openSUSE: `su: command not found` in that image. The `su` that
was supposed to hold a session open never started, so nothing ever opened the
fifo for reading, and `exec 9>"$fifo"` blocked forever - opening a fifo
write-only waits for a reader. Fixed two ways: skip when `su` is missing, and
open with `exec 9<>` (read-write never blocks).

Second failure, Debian: it hung anyway, at the same point, with `su` present.
Rather than keep chasing why a backgrounded `su` plus a fifo behaves
differently per image, the whole construction was dropped.

The property under test never actually needed the timing. What matters is
"a process whose supplementary groups lack X, while the group database says
the user is in X, can reach X through `sg`". `setpriv --reuid --regid
--groups` builds exactly that state in one call, deterministically, with no
background process and nothing to block on:

    setpriv --reuid "$SGUID" --regid "$SGGID" --groups "$SGOTHER_GID" sh -c '
      id -nG                    | grep -cx sgtest    # -> 0, stale list
      timeout 10 sg sgtest -c "id -nG" | grep -cx sgtest   # -> 1, sg sees it
      timeout 10 sg sgtest -c "id -nG" | grep -cx sgother  # -> 1, others kept
    '

Verified on Debian trixie and Ubuntu 24.04 - the two that hung - then across
the suite. An image without `setpriv` skips with a note, same as one without
`sg`.

Lesson worth keeping: a test that needs a race to set up its precondition can
usually be rewritten to construct the precondition instead, and the rewrite is
cheaper than debugging the race per distro. Also - a hang in a container test
reads exactly like a slow build, so `timeout` belongs around anything that
could prompt.

### 9. Which distros actually get the one-run install

Falling out of the rewritten test, across all five images:

| distro | `sg` | one-run install |
|---|---|---|
| Ubuntu 24.04 | yes | yes, verified |
| Debian trixie | yes | yes, verified |
| openSUSE Tumbleweed | yes | yes, verified |
| Fedora | yes | assumed - image has no `setpriv`, so the test skips its setup |
| Arch | **no** | no: falls back to logout + re-run |

Arch's `shadow` package genuinely does not ship `sg` (`pacman -Ql shadow`
lists `newgrp` only). `newgrp` can't help: it has no `-c`, so it can only
start an interactive shell. `setpriv` is present there but is no substitute -
*adding* a group you don't already hold needs CAP_SETGID, which is exactly
what the setuid-root `sg` provides and an unprivileged `setpriv` cannot.

Not fixed, deliberately, and noted in README's compatibility list instead. The
portable alternative would be `sudo -u "$USER" -- <command>`, which re-runs
`initgroups()` for the target user and so picks the new group up on any distro
with sudo - already a hard dependency here. Rejected for now because it
sanitises the environment (`bin/seal.sh` resolves `$DATA_DIR` from `$HOME`)
and because bolting a second group-borrowing mechanism on right before
shipping trades a clean graceful fallback for fresh untested risk. Worth
revisiting if Arch support matters later; the fallback path is correct today,
just costs a second run.

## Review of the `feat/fingerprint-attempt-stack` branch (2026-09-15)

Security-focused read of 1bb0d7e against `main`, with every claim below
reproduced by running `bin/lib.sh`'s functions against throwaway fixtures
(nothing under `/etc/pam.d/` was touched). Recording the findings here
because three of them are in the *safety* predicates, which is exactly the
kind of thing a diff doesn't show and a re-read six months from now would
have to re-derive.

### 1. `uninstall.sh` edits `/etc/pam.d/` files this tool never touched, without a backup

`uninstall.sh`'s new loop (1b, lines 49-77) runs `pam_fprintd_unharden`
over *every* file in `/etc/pam.d/` and rewrites any file whose content
changes. But `unharden` strips `max-tries=1` unconditionally, and Debian's
own `pam-auth-update` writes exactly that into `common-auth`:

    auth [success=3 default=ignore] pam_fprintd.so max-tries=1 timeout=10

Reproduced against `test/fixtures/pam.d/fprintd-shared` (that fixture *is*
the Debian shape) and against a full hand-written `common-auth`:

    $ source bin/lib.sh
    $ diff <(pam_fprintd_unharden <test/fixtures/pam.d/fprintd-shared) \
           test/fixtures/pam.d/fprintd-shared
    < auth [success=3 default=ignore] pam_fprintd.so timeout=10 # debug
    > auth [success=3 default=ignore] pam_fprintd.so max-tries=1 timeout=10 # debug

All four of the invariants the loop checks before writing pass on that
result (every non-fprintd line identical, exactly one fprintd auth line, no
generated lines, no `timeout=-1`), so it gets written. The prompt claims
"Found install.sh's fingerprint attempt stack in /etc/pam.d/common-auth",
which is false - `install.sh` refuses `common-auth` by design, and
`pam_auth_is_fingerprint_only` correctly says no for it. Worse, that loop
has no `backup_pam_file` equivalent: `install.sh` backs every PAM file up,
`uninstall.sh` does not, and the prompt now defaults to yes.

Root cause: `install.sh` gates on three predicates (single real fprintd
line, fingerprint-only stack, hardening would change something);
`uninstall.sh` gates only on "unharden changes something", which is a much
weaker and *differently shaped* condition. The un-install side has to be at
least as narrow as the install side, and the cheapest way to make it so is
to key off the generated attempt lines (`PAM_FPRINTD_RETRY_LINE_RE`) rather
than off "any diff", plus reuse `backup_pam_file`.

Same root cause, second symptom: a hand-written stack that happens to carry
its own `authinfo_unavail=ignore` on an fprintd auth line has that line
*deleted* by the same loop, because `unharden` treats it as generated.

### 2. The attempt stack changes the meaning of a `sufficient` fprintd line

`_pam_fprintd_rewrite_stack` gives every generated line `success=N`, a
relative jump that continues the stack. That is equivalent to the original
control only when the original was fall-through (`required`, `optional`).
For `sufficient` (i.e. `success=done`) it is not, and the difference is not
academic - the classic hand-rolled fingerprint-only stack is:

    auth sufficient pam_fprintd.so
    auth required   pam_deny.so

Both modules are on `PAM_AUTH_PASSIVE_MODULE_RE`, so
`pam_auth_is_fingerprint_only` accepts the file and `install.sh` rewrites
it. After the rewrite a match on attempt 1 jumps over attempts 2-3 and
lands on `pam_deny.so`: a good finger now *fails* the login. Only a match
on the third line (which keeps the distro's `sufficient`) still works.
Fails closed, so it is not an auth bypass - but it silently breaks
fingerprint login on a shape the eligibility check explicitly admits.
`test/runtime-test.sh`'s flow cases all use `required`, so nothing catches
it.

### 3. `-auth` lines are invisible to the fingerprint-only predicate

`pam_auth_is_fingerprint_only` matches `^[[:space:]]*auth[[:space:]]`. PAM
also accepts a leading `-` ("skip silently if the module is missing"), used
in the wild for `pam_systemd_home.so`, `pam_fscrypt.so` and friends. A
stack containing

    -auth [success=1 default=ignore] pam_systemd_home.so
    auth  required                   pam_fprintd.so

is reported fingerprint-only, which is exactly the misclassification the
predicate exists to prevent: there *is* another auth path in the same
serialised stack, and `timeout=-1` can keep it from ever being reached.

### 4. Relative jumps above the fprintd line silently change meaning

Hardening inserts two lines above the original, so any numeric jump on a
line *above* it (`auth [success=1 default=ignore] pam_succeed_if.so ...`,
the standard "this group skips fingerprint" idiom) now lands two modules
short of where it was aimed. `install.sh`'s invariant - every non-fprintd
line byte-for-byte identical - reads like it guarantees nothing else
changed, but a jump's meaning is positional, so identical bytes are not
identical semantics. In the plausible shapes this fails closed (someone who
was meant to skip the reader is now asked for a finger), but the predicate
should refuse files carrying numeric jumps above the fprintd line rather
than rely on that.

### 5. Prompts now default to yes on irreversible / login-critical steps

`confirm()` in both scripts became `[Y/n]`, and `bin/seal.sh`'s overwrite
prompt with it, so Enter now *destroys an existing seal* where it used to
decline. The answer test is `[[ ! "$ans" =~ ^[Nn][Oo]?$ ]]`, so anything
that isn't exactly n/N/no/No - "nope", "nah", a stray space - counts as
yes. Deliberate UX choice (see b6d19c7), and EOF correctly declines, but it
sits against this repo's own "default to whichever option is more careful
with data" rule for the two cases that are hard to reverse: overwriting a
working seal, and editing a PAM file.

### 6. The backup-file filter is narrower than the file zoo in `/etc/pam.d/`

`PAM_BACKUP_RE='\.bak-[0-9]+$'` covers this tool's own backups only.
`.pacnew` (Arch, routine), `.rpmnew` / `.rpmsave` (Fedora/openSUSE),
`.dpkg-old` / `.dpkg-dist` / `.ucf-old` (Debian) all sit in `/etc/pam.d/`,
all carry real auth lines, and all still get picked up by both the
gnome-keyring wiring loop and the new fprintd loops - the same bug class
the branch just fixed for `.bak-<ts>`. PAM only reads the file whose name
matches the service, so this is noise rather than danger, but it is the
same fix: skip anything that is not a plausible service name.

No change was made to the code as part of this review.

## Fixes for the branch review (2026-09-15, later)

Applied 1, 2, 3, 4 and 6 from the review entry above. 5 (prompts defaulting
to yes) was left as it is - deliberate UX call, see b6d19c7.

### `uninstall.sh` now reverts only stacks it can prove it wrote (fix 1)

New `pam_fprintd_stack_is_generated()` in `bin/lib.sh`, and that is what the
1b loop gates on instead of "unharden would change something". It proves
authorship by round trip: strip the file back down with `unharden`, build it
up again with the attempt count *read off the file*, require the result to
equal the file byte for byte. Reading the count off the file rather than
using `PAM_FPRINTD_ATTEMPTS` means changing that constant later doesn't
strand existing installs - there's a test for exactly that.

Evidence the loose gate was wrong, from this machine:

    $ grep fprintd /etc/pam.d/common-auth /usr/share/pam-configs/fprintd
    /etc/pam.d/common-auth:auth [success=3 default=ignore] pam_fprintd.so timeout=10 # debug
    /usr/share/pam-configs/fprintd: [success=end default=ignore] pam_fprintd.so max-tries=1 timeout=10 # debug

The shipped `pam-configs` snippet carries `max-tries=1`, so the next
`pam-auth-update` (any gdm/fprintd package update runs one) writes that into
`common-auth` - and `unharden` strips `max-tries=1` unconditionally, so from
that moment the old loop would have offered to "restore" `common-auth`, and
written it. All four of its invariants pass on that rewrite, so nothing
downstream would have stopped it. The `fprintd-shared` fixture is that exact
line; `test/unit-regex-test.sh` now asserts both halves (unharden alone still
changes it; the new gate refuses it).

Both PAM-editing loops in `uninstall.sh` also take a `.bak-<timestamp>` copy
now, via the same `backup_pam_file` helper `install.sh` has. Undoing an edit
to a login-critical file is still an edit to a login-critical file, and
CLAUDE.md asks for a backup before every one of those - the install side had
it, the uninstall side didn't.

### The rewrite refuses control fields it can't reproduce (fix 2)

`pam_fprintd_control_falls_through()`. The generated attempt lines use
`success=N` - a jump that records success and carries on. That matches
`required` / `requisite` / `optional` / `[…success=ok…]` and nothing else.
`sufficient` is `success=done`: it *ends* the stack. So on

    auth sufficient pam_fprintd.so
    auth required   pam_deny.so

- every module of which is on `PAM_AUTH_PASSIVE_MODULE_RE`, so it sailed
through `pam_auth_is_fingerprint_only()` - a match on attempt 1 or 2 would
jump over the remaining attempts and land on `pam_deny.so`: a *correct*
finger fails the login. Fails closed, so not a bypass, but it breaks
fingerprint login on a shape the eligibility check admitted. A bracketed
`success=<number>` is refused for the related reason: its jump distance was
measured from where that one line sat and can't be reproduced on three lines
in three places.

Refused rather than translated. Generating `success=done` for a `sufficient`
original would be faithful, but it is a login path, the runtime test only
covers `required`, and `gdm-fingerprint` - the service this feature exists
for - ships `auth required`. Not worth the risk for the little it buys. Worth
knowing this shape is real: `/etc/pam.d/sudo` on this machine is
`auth sufficient pam_fprintd.so` (it's refused earlier anyway, as a shared
stack).

### `-auth` lines are no longer invisible (fix 3)

`pam_auth_is_fingerprint_only()` matched `^\s*auth\s`, and PAM also accepts a
leading `-` ("skip silently if the module isn't installed"), used in the wild
for `pam_systemd_home.so` and `pam_fscrypt.so`. A stack with
`-auth [success=1 default=ignore] pam_systemd_home.so` above the reader was
reported fingerprint-only - the exact misclassification the predicate exists
to prevent, since that *is* a second auth path in the same serialised stack.
Now `-?auth`.

### Relative jumps above the reader are refused (fix 4)

`pam_auth_has_no_relative_jumps()`. Hardening inserts two lines above the
fprintd line, so a jump on any line above it - `auth [success=1
default=ignore] pam_succeed_if.so user ingroup nopasswdlogin`, the standard
"this group skips the reader" idiom - ends up aimed at attempt 2 instead of
past the reader.

The uncomfortable part is that `install.sh`'s write invariant (every
non-fprintd line byte-for-byte identical) *reads* like it rules this out. It
doesn't: a jump's meaning is positional, so identical bytes are not identical
semantics. Lines below the fprintd line are fine - nothing is inserted
between them and what they aim at - which is why the predicate stops at the
fprintd line rather than scanning the whole file.

### The non-service filter covers the whole zoo (fix 6)

`PAM_BACKUP_RE` (`\.bak-[0-9]+$`, this tool's own backups) became
`PAM_NON_SERVICE_RE` (`(^|/)[^/]*\.[^/]*$`, "the basename has a dot").
`.pacnew` is routine on Arch, `.rpmnew`/`.rpmsave` on Fedora and openSUSE,
`.dpkg-old`/`.dpkg-dist`/`.ucf-old` on Debian - all sit in `/etc/pam.d/`, all
carry real auth lines, all were still being scanned and patched. Same bug
class the branch had just fixed for its own backups. Matched on the basename
because the directory part contains a dot itself (`pam.d`) - there is a test
for that, and one asserting real service names with hyphens
(`common-session-noninteractive`, `sudo-i`, `runuser-l`) still get scanned.

Checked the dot rule against every service on this machine and every one the
five packaging containers install: none has a dot in its name.

### Also

- README's intro still said the installer stops after the `tss` group add and
  asks for a re-run. `sg` removed that a commit earlier; the plan text in
  `install.sh` already said so. Fixed, with the Arch (no `sg`) exception.
- New fixtures: `fprintd-sufficient`, `fprintd-jump`, `fprintd-dash-auth`,
  `fprintd-handrolled`. The last one is somebody's hand-written two-attempt
  stack carrying `authinfo_unavail=ignore` - `unharden` reads that line as one
  of ours and deletes it, which is the second symptom of the fix-1 root cause
  and is what the round-trip gate now refuses.
- `test/unit-regex-test.sh`: 26 new checks, whole suite green (55 checks).

## Uninstall completeness: exact restore, and no more silent skips (2026-09-15, later still)

Prompted by asking the plain question - "does uninstall.sh actually undo
everything?" - and walking install.sh's steps against it one by one. Two gaps
worth fixing came out of that; a third (packages are never removed, backups
are never cleaned) was left alone deliberately.

### The fingerprint line came back on module defaults, not as it was

`pam_fprintd_unharden` removes exactly the options `harden` adds. That is the
right inverse for the bare `auth required pam_fprintd.so` gdm ships, and the
wrong one for a stack that had its own explicit `timeout=`/`max-tries=`: those
values are simply gone, and nothing in the file records what they were. The
only place they still exist is the `.bak-<timestamp>` copy install.sh took.

New `pam_fprintd_exact_original()` in `bin/lib.sh` picks that copy, and
uninstall.sh restores it wholesale when it exists. The interesting part is
when a backup may be trusted, since restoring a stale one over newer content
would be its own bug:

- the backup holds exactly one pam_fprintd.so auth line and no generated
  attempt lines, so it is a pre-edit original rather than another hardened
  copy (install.sh re-runs can leave those around);
- `pam_fprintd_harden <backup>` reproduces the current file **byte for byte**.

The second condition is the load-bearing one. It can only hold if every
non-fprintd line in the backup already matches what is on disk, so a gdm
upgrade or an unrelated hand edit since the install makes the backup
un-restorable automatically - no need to reason about which lines changed.
That is also what makes copying the *whole* backup back safe rather than
having to splice the fprintd lines out of it.

Newest backup first. A re-run of install.sh on an already-hardened file takes
no new backup (it isn't a target), so every copy that passes both conditions
carries the same original line anyway.

Ordering detail that makes this work in practice: uninstall.sh's step 1
removes the `pam_tpm_keyring_authtok.so` line *before* step 1b runs, and
install.sh's single-backup-per-run rule means the backup predates both edits.
So by the time 1b looks, the file is exactly `harden(backup)` again. If the
user declines step 1, the round trip won't match and 1b falls back to module
defaults - correct, and it says which of the two it did.

Verified against this machine's real `/etc/pam.d/gdm-fingerprint` and its
three `.bak-*` copies, on throwaway duplicates: all three qualify, the newest
is picked, and the restored file is byte-identical to the pre-install backup.

### A file edited since the install was skipped without a word

The stricter gate added earlier today (`pam_fprintd_stack_is_generated`) is
right, but its failure mode was a silent `continue`: a `gdm-fingerprint` that
somebody had touched since - or that a gdm upgrade half-replaced - would carry
three fprintd lines forever while the uninstaller printed nothing and the user
concluded it had all been undone. Now the file is checked for our attempt
lines *first*, and a file that has them but fails the round trip gets an
explicit warning naming the file and pointing at the `.bak-<timestamp>` copy.

Silence is the worst option for that case specifically: not reverting is a
defensible choice, not *saying* so is not.

### Left alone on purpose

- **Packages.** `install.sh` may install `tpm2-tools`, `gcc`, `libpam0g-dev`
  and friends; `uninstall.sh` removes none of them. Uninstalling a compiler
  or `tpm2-tools` that may well have predated this tool is exactly the kind
  of irreversible-in-the-wrong-direction step this repo's rules say to avoid.
- **`.bak-<timestamp>` copies.** They accumulate (28 in `/etc/pam.d/` on this
  machine already), and now the uninstall side adds its own. Deleting a
  login-critical file's only backup to tidy up is a bad trade; leaving them is
  the safe default. Worth revisiting as a *listing* at the end of a run rather
  than a deletion.

Tests: 6 new checks for `pam_fprintd_exact_original` (found, newest wins, a
hardened backup isn't an original, a stale backup is refused, no backup at
all, and that unharden alone genuinely cannot bring a `timeout=45` back).
Whole regex suite green at 84 checks.

## Eligibility is now re-proved immediately before the write (2026-09-15, still later)

Found on a second, deliberately cold read of the branch. `install.sh` decides
which `/etc/pam.d/` files may be rewritten in section 1e, prints that plan,
and writes in section 3 - and section 3 begins with `apt install` /
`dnf install` / `pacman -Sy` / `zypper install`. On Debian and Ubuntu that
step can regenerate files under `/etc/pam.d/` all by itself:
`libpam-runtime`'s postinst runs `pam-auth-update`, and a `gdm` upgrade ships
its own `gdm-fingerprint`. Nothing in the branch is unusual here - it is the
ordinary shape of "plan, then act" - but the two moments are not the same
moment, and the gap contains a package manager.

The checks section 3 already did before writing are about *faithfulness*:
every non-fprintd line byte for byte identical, exactly N attempt lines, N-1
generated. They compare the rewrite against whatever is on disk at that
instant. They say nothing about whether that content is still a file this tool
may touch. Demonstrated on a copy of `test/fixtures/pam.d/fprintd-only` with
one line added:

    eligible before: yes
    eligible after:  no          # gained "auth required pam_unix.so"
    >>> write-time invariants ACCEPT this file

So the failure mode was: a target that turned into a shared stack between the
plan and the write gets `timeout=-1` anyway - the one outcome the whole
predicate apparatus exists to prevent (PAM is serialised; an unlimited
fingerprint wait in a stack that also holds `pam_unix` means `sudo` never
reaches its password prompt).

Fix: the eligibility rule moved into one function, `pam_fprintd_stack_is_eligible()`
in `bin/lib.sh`, and `install.sh` applies it twice - at plan time, and again
immediately before `sudo cp`. A file that no longer qualifies is named, with
the reason, and skipped rather than written. "Hardening would change
something" is deliberately left out of that function and asked separately at
both call sites, so "already in the target state" stays distinguishable from
"not eligible".

Verified end to end on throwaway copies, with the package update simulated
between the two phases:

    == plan: both files eligible ==
    == (file mutated) ==
    REFUSED: gdm-fingerprint - changed since the plan, left alone
    Rewritten: untouched
    gdm-fingerprint: 0 lines with timeout=-1
    untouched:       3 lines with timeout=-1

Second thing this fixed, quieter but worth recording: `test/unit-regex-test.sh`
had its own hand-copied list of the eligibility predicates. A test that
re-implements the rule it is testing cannot catch the rule changing in one
place and not the other - exactly the drift `bin/lib.sh` exists to prevent.
It now calls `pam_fprintd_stack_is_eligible()` itself, and there are two new
checks asserting the split: the write-time invariants alone *do* accept
`fprintd-shared`, and only the eligibility check refuses it. 86 checks green.

### Noted in the same pass, not fixed

- `pam/tpm-keyring-unseal.sh:26` opens `/run/lock/tpm-keyring-unseal.lock`,
  and `/run/lock` is world-writable + sticky (1777). Root creating a fixed
  name there is only safe because of `fs.protected_symlinks=1` /
  `fs.protected_regular=2` (both confirmed on in this machine's sysctls).
  Without them an unprivileged local user can plant a symlink and have root
  truncate an arbitrary file. `/run/tpm-keyring-unlock.lock` (the directory is
  root-owned 755) removes the dependency on a kernel default. Predates this
  branch.
- `pam/pam_tpm_keyring_authtok.c:179,188,198` - `memset()` on the password
  buffer is a dead store the compiler may legally remove; `explicit_bzero()`
  is the guaranteed form. Predates this branch.
- `install.sh:260` - `pacman -Sy --needed` without `-u` is the classic Arch
  partial-upgrade footgun. Predates this branch.

## Fixes from the multi-agent code review (2026-09-15, last pass)

A `/code-review max` pass over the branch turned up thirteen items. Nine were
real once reproduced by hand; the rest are recorded at the bottom with why
they were not acted on. Everything below was verified on fixtures before and
after the change.

### Backslash line continuations were a blind spot (bin/lib.sh)

PAM joins a line ending in `\` with the next one. Every scanning predicate
here read physical lines, so:

    auth \
    	required	pam_unix.so

was invisible to `pam_auth_is_fingerprint_only()` - the first physical line
has no module token to check, the second does not start with `auth` - and a
shared stack came back as fingerprint-only, `eligible=YES`. Exactly the hole
the leading-dash `-auth` form had a few hours earlier, from exactly the same
cause: treating a PAM config as if one line were one directive.

Fixed by reading through a new `_pam_logical_lines()` that folds continuations
the way libpam does; all three scanning predicates now iterate that instead of
the file.

### ...and the rewriter corrupted a continued fprintd line

Same feature, other half. `_pam_fprintd_rewrite_stack()` appends
`timeout=-1 max-tries=1` to the end of the physical `pam_fprintd.so` line. If
that line ends in a continuation, the options land *after* the backslash:

    auth	[success=2 ...]	pam_fprintd.so \ timeout=-1 max-tries=1
    	timeout=10          <- orphaned, unparseable

The backslash becomes a module argument and the line below becomes a stray
directive. install.sh's write invariant does not catch it: the orphan is a
non-fprintd line and is identical on both sides, so the count checks pass and
a login-critical file gets written broken, silently.

Rather than teach the awk to fold and unfold continuations, files carrying any
continuation are refused outright (`pam_config_has_no_line_continuations()`).
No distro ships one, and this is a login path - the reason not to guess here
is the same reason the `sufficient` control is refused rather than translated.

### `-auth` was half-recognised, which is worse than not at all

`pam_auth_is_fingerprint_only()` learned about `-auth` earlier today, but
`PAM_FPRINTD_AUTH_RE` - the regex that *counts* fingerprint lines and drives
the awk - did not. So a file with

    auth	required	pam_fprintd.so
    -auth	required	pam_fprintd.so

counted as "exactly one line to build on", passed eligibility, and was
rewritten into a three-attempt stack with the dash line left sitting directly
below it. A matched finger on attempt 1 jumps over attempts 2 and 3 - and
lands on that un-hardened line, so a *successful* scan is immediately asked to
scan again, with the module's 30s default, and a failure there fails the
login.

`PAM_FPRINTD_AUTH_RE` and `PAM_FPRINTD_RETRY_LINE_RE` now both accept `-?auth`
(and so do the awk's two copies of them), which makes the count 2 and the file
refused. While in there: the generated attempt lines now carry the same
`auth`/`-auth` prefix as the line they copy, since a dash means "skip silently
if the module is missing" and generating bare `auth` lines would start
erroring where the original was quiet.

### install claimed stacks uninstall refuses to claim

`pam_fprintd_has_single_auth_line()` counts any `authinfo_unavail=ignore` line
as one this tool generated. Right for our own output, wrong for a hand-written
retry stack that predates the tool - the repo even ships a fixture of one
(`fprintd-handrolled`). Result: `pam_fprintd_stack_is_generated()` said "not
ours, do not revert" while `pam_fprintd_stack_is_eligible()` said "fine,
rewrite it". The install side now defers to the same test: if marker lines are
present at all, they have to be provably ours.

### The uninstall gate had a silent hole of its own

Keying the revert loop on "has attempt lines" - yesterday's fix - skipped a
file whose attempt lines were gone but whose `timeout=-1 max-tries=1` were
still on the fprintd line. Silently, which is the exact failure the warning
beside it was added to prevent, and a regression against the committed gate,
which would have cleaned it.

`timeout=-1` is this tool's signature on its own (no distro ships it, and
unlike `max-tries=1` it cannot be confused with Debian's `common-auth`), so
the loop now enters on either signal and says which one it found.

### The warning itself was asserting things it could not know

For `fprintd-handrolled` the old text claimed "something has edited it since"
and pointed at a `.bak-<timestamp>` copy that was never created. Now it says
the marker matched but the file is not what install.sh would have written -
"either something edited it since, or it was somebody's own retry stack all
along" - and it lists backup copies only if any actually exist.

### The keyring-wiring loop never got the re-check the fprintd loop did

`install.sh`'s second write loop still walked the plan-time `candidates` list
with no existence check. A file removed or renamed by the package step (the
very race documented three lines above it) falls through `grep -q` into
`backup_pam_file` -> `sudo cp` on a missing path -> `set -e` aborts the whole
run, after the fprintd edits are already written, with nothing but cp's error
to explain it. Now re-checked, named, and skipped.

### Documentation that disagreed with the code

The doc block in `bin/lib.sh` and the block in `README.md` both showed
`pam_fprintd.so max-tries=1 timeout=-1`; the code emits `timeout=-1
max-tries=1`. Byte order matters here - `pam_fprintd_stack_is_generated()`
proves ancestry with `cmp`, and the tests assert literal strings - so the one
place a reader would trust to reconstruct the format by hand was the one place
that was wrong. Also: the test file's section header still named
`pam_fprintd_set/clear_unlimited_timeout`, renamed to `harden`/`unharden` in
this branch.

### Reported, not acted on

- **`bin/seal.sh`'s `[Y/n]` overwrite prompt.** Deliberate, and explicitly
  excluded when this was discussed. Not reopened.
- **`PAM_NON_SERVICE_RE` skipping a service whose name contains a dot.** True,
  and the trade is deliberate: no such service exists on any of the five
  distros the suite covers, while `.pacnew`/`.rpmsave`/`.dpkg-old` are
  everyday. A list of known suffixes fails in the dangerous direction (the
  next suffix gets scanned and patched); this rule fails in the safe one.
- **`confirm()`/`RUN_TS`/`backup_pam_file` duplicated between install.sh and
  uninstall.sh, and the write-time invariant hand-copied in three places.**
  Both fair, both the kind of drift `bin/lib.sh` exists to prevent, neither a
  defect today. Worth a cleanup pass of its own rather than being smuggled
  into this one.

Tests: 102 checks in the regex suite (was 86), including three new fixtures -
`fprintd-continuation`, `fprintd-continued-line`, `fprintd-dash-second` - and
assertions that the dash form is counted, that generated lines keep the dash,
and that install and uninstall now agree about `fprintd-handrolled`.

### Worth noting about the review itself

Two of its thirteen findings were wrong on the facts, and one of my own new
test assertions was wrong too (it counted a fixture's comment line and blamed
the code). Reproducing each claim by hand before believing it cost a few
minutes and changed the outcome three times. Worth doing that every time.

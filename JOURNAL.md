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
investigation there - see that branch's own JOURNAL.md entries) to avoid
any dependency between the two pieces of unmerged work.

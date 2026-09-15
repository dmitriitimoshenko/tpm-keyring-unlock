# Reporting a vulnerability

This project's whole job is to keep a keyring password out of reach, so a
report that it doesn't is the most useful thing you can send.

**Private reporting is enabled.** Use GitHub's
[Report a vulnerability](https://github.com/dmitriitimoshenko/tpm-keyring-unlock/security/advisories/new)
button (Security → Advisories). That opens a draft advisory only you and the
maintainer can see.

If that isn't available to you for any reason, open a normal issue and say up
front that you'd rather have discussed it privately — an issue that gets the
problem in front of someone who can fix it beats a finding that sits
unreported. That is a judgement call and it's yours to make; nobody will
treat a public report as a mistake.

## What's in scope, and what is known already

Read [the threat model](README.md#threat-model-honestly) first. Two things
there are deliberate and already documented, so they aren't findings:

- **Anyone with your running, logged-in machine can read the unsealed
  secret.** That is inherent to "unlock without asking".
- **Anyone with the powered-off machine can too.** PCR7 doesn't measure the
  kernel, initrd or kernel command line, the policy has no auth value, and
  this tool is for machines without full-disk encryption. The README explains
  why binding more PCRs isn't done.

Everything else is in scope, and these are especially worth reporting:

- anything that lets one local user reach another user's sealed secret, or
  authenticate as them
- anything that makes a PAM stack authenticate someone who didn't supply
  credentials
- anything that lets an unprivileged user stop keyring unlock working, or
  stall a login
- unvalidated data reaching a `tpm2_*` tool, or root reading and acting on a
  path an unprivileged user controls
- weaker file, directory or TPM-object permissions than the docs claim

## What to include

The distro and version, whether Secure Boot is on, which display manager, the
relevant `/etc/pam.d/` file, and the exact commands you ran. If it involves
the PAM stack, the file's contents matter more than a description of them —
ordering is usually the whole story.

You don't need a working exploit. A precise description of the mechanism is
enough, and is preferred over anything that would extract a real secret.

## What to expect

This is a single-maintainer hobby project, not a vendor with an on-call
rotation, so don't read silence as dismissal — ping the thread. Fixes land
with a `JOURNAL.md` entry explaining the reasoning and a regression test
where the failure can be reproduced in the VM or container layers; see
[`test/README.md`](test/README.md) for what each layer can actually cover.

Credit goes in the commit and the journal entry unless you'd rather it
didn't — say so and it won't.

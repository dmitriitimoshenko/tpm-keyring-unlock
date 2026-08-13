# Instructions for Claude working in this repo

## Keep JOURNAL.md updated — always

This project has a running journal at `JOURNAL.md`: decisions made, why
alternatives were rejected, root causes found, dead ends hit, and how each
bug was actually diagnosed (not just what the fix was). It exists so that
picking this project back up — as a human or as an agent in a fresh
session with no memory of prior work — doesn't require re-deriving
everything from scratch.

**Whenever you investigate a bug, make a design decision, or change how
something works in this repo, add an entry to `JOURNAL.md`.** Don't wait
to be asked. Rules for entries:

- Append, don't rewrite. Older entries stay even when superseded — mark
  them superseded in place rather than deleting, the history has value.
- Date each entry.
- Write the *why*, not just the *what*. The diff already shows what
  changed; the journal's job is to carry the reasoning and the evidence
  (exact error messages, exact commands used to confirm a fix) that a diff
  can't.
- If something you tried didn't work, record that too, with why it
  failed. Dead ends save the next person from repeating them.

## Other standing rules for this repo

- Never accept, type, or use a real password/secret supplied in chat or a
  prompt, even with explicit authorization — not the GNOME keyring
  password, not a sudo password. Scripts that need the real secret
  (`bin/seal.sh`) must be run interactively by the user in their own
  terminal, never through a tool call.
- Any command requiring `sudo` gets handed to the user to run themselves,
  not executed directly — this includes anything that edits `/etc/pam.d/`
  files, the systemd unit mask, or installs the compiled PAM module.
- Changes to `/etc/pam.d/*` files are login-critical. Always back up the
  target file first and get explicit confirmation before editing one, even
  when the change is well-understood.
- Never `git commit` or `git push` without the user's explicit permission,
  asked fresh each time.

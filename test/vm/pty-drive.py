#!/usr/bin/env python3
"""Drive an interactive command over a pty, answering prompts as they appear.

Why this exists instead of `printf '...' | ssh -tt`: sudo discards whatever is
already sitting in the terminal's input queue before it runs. That is a
deliberate anti-typeahead measure (so a password typed early cannot leak into
the echo of the next prompt), and it means every keystroke queued ahead of an
install step is gone by the time a later prompt asks for it. Demonstrated:

    printf 'answer\\n' | script -qec 'read -p "p: " v; echo [$v]'            -> [answer]
    printf 'answer\\n' | script -qec 'sudo true; read -p "p: " v; echo [$v]' -> []

install.sh runs sudo between its plan prompt and bin/seal.sh's prompts, so
pre-feeding cannot work there at all - it hung a CI run for an hour before
this was understood. See JOURNAL.md, 2026-09-16.

Usage:
    pty-drive.py --timeout SECS --log FILE
                 [--expect 'REGEX=ANSWER']...
                 -- COMMAND [ARG...]

Each --expect is consumed in order: the answer is written the moment its
regex matches the output seen so far. A regex prefixed with '*' stays active
for the rest of the run instead of being consumed once, which is how a script
whose every prompt takes the same answer (Enter) is driven.

Exit code: the command's own, or 124 on timeout (like timeout(1)).
"""
import argparse
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time


def parse_expects(raw):
    out = []
    for item in raw:
        pattern, sep, answer = item.partition("=")
        if not sep:
            raise SystemExit(f"--expect needs REGEX=ANSWER, got: {item!r}")
        repeat = pattern.startswith("*")
        if repeat:
            pattern = pattern[1:]
        out.append({"re": re.compile(pattern), "answer": answer, "repeat": repeat})
    return out


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--timeout", type=float, default=420.0)
    ap.add_argument("--log", required=True)
    ap.add_argument("--expect", action="append", default=[])
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise SystemExit("no command given")

    expects = parse_expects(args.expect)
    idx = 0

    master, slave = pty.openpty()
    proc = subprocess.Popen(
        command, stdin=slave, stdout=slave, stderr=slave,
        close_fds=True, start_new_session=True,
    )
    os.close(slave)

    deadline = time.monotonic() + args.timeout
    # Only the tail is matched against, so a prompt cannot be re-triggered by
    # its own echo scrolling past earlier in the transcript.
    buf = ""
    timed_out = False

    with open(args.log, "wb") as log:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            try:
                ready, _, _ = select.select([master], [], [], min(remaining, 1.0))
            except InterruptedError:
                continue
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            log.write(chunk)
            log.flush()
            buf += chunk.decode("utf-8", "replace")

            while idx < len(expects):
                entry = expects[idx]
                m = entry["re"].search(buf)
                if not m:
                    break
                os.write(master, (entry["answer"] + "\n").encode())
                buf = buf[m.end():]
                if not entry["repeat"]:
                    idx += 1
                else:
                    break
            if len(buf) > 65536:
                buf = buf[-4096:]

        if timed_out:
            log.write(b"\n[pty-drive] TIMEOUT after %.0fs" % args.timeout)
            if idx < len(expects):
                log.write(b" - still waiting for: %s"
                          % expects[idx]["re"].pattern.encode())
            log.write(b"\n")
            log.flush()

    if timed_out:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            pass
        proc.wait()
        os.close(master)
        return 124

    os.close(master)
    return proc.wait()


if __name__ == "__main__":
    sys.exit(main())

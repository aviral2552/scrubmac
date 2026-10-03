#!/usr/bin/env python3
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
"""ptyrun.py STARTED ACTIONS -- CMD... — run CMD on a real pty (its
controlling terminal, as in Terminal.app) and act on it like a person.

ACTIONS is a comma list: w = wait (max 10 s) until the file STARTED exists,
c = type Ctrl-C, h = hang up (close the terminal), sN = wait N seconds.
Prints everything CMD wrote, then "[ptyrun] exit status N" or
"[ptyrun] killed by signal N" (or "[ptyrun] still running")."""
import os
import pty
import select
import sys
import time

started, actions, cmd = sys.argv[1], sys.argv[2].split(","), sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

out = bytearray()


def pump(seconds):
    end = time.time() + seconds
    while True:
        left = end - time.time()
        if left <= 0:
            return
        try:
            ready, _, _ = select.select([fd], [], [], min(left, 0.05))
        except (OSError, ValueError):
            return
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            out.extend(chunk)


closed = False
for action in actions:
    if action == "w":
        for _ in range(200):
            if os.path.exists(started):
                break
            pump(0.05)
    elif action == "c":
        os.write(fd, b"\x03")
    elif action == "h":
        os.close(fd)
        closed = True
    elif action.startswith("s"):
        if closed:
            time.sleep(float(action[1:]))
        else:
            pump(float(action[1:]))

status = None
for _ in range(600):
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        break
    if closed:
        time.sleep(0.05)
    else:
        pump(0.05)
if not closed:
    pump(0.3)
sys.stdout.write(out.decode("utf-8", "replace").replace("\r", ""))
if status is None:
    print("\n[ptyrun] still running")
elif os.WIFEXITED(status):
    print("\n[ptyrun] exit status %d" % os.WEXITSTATUS(status))
else:
    print("\n[ptyrun] killed by signal %d" % os.WTERMSIG(status))

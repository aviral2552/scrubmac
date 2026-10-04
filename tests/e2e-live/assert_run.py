#!/usr/bin/env python3
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
"""Assert on a scrubmac --json run record in the live E2E workflow.

usage: assert_run.py RUN.json [--exit N] [--ok a,b,…] [--skip a,b,…]
                     [--status name=status,…] [--no-fail] [--mode MODE]
                     [--note name=substring]
"""
import argparse
import json
import sys


def csv(value):
    return [v for v in value.split(",") if v]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("record")
    ap.add_argument("--exit", type=int, dest="exit_code")
    ap.add_argument("--ok", type=csv, default=[])
    ap.add_argument("--skip", type=csv, default=[])
    ap.add_argument("--status", type=csv, default=[])
    ap.add_argument("--note", type=csv, default=[])
    ap.add_argument("--no-fail", action="store_true")
    ap.add_argument("--mode")
    args = ap.parse_args()

    with open(args.record, encoding="utf-8") as fh:
        run = json.load(fh)
    by_name = {c["name"]: c for c in run["cleaners"]}
    problems = []

    def expect(name, status):
        got = by_name.get(name, {}).get("status")
        if got != status:
            problems.append(f"{name}: expected {status}, got {got!r} {by_name.get(name, {}).get('notes', [])}")

    if args.exit_code is not None and run["exit_code"] != args.exit_code:
        problems.append(f"exit_code: expected {args.exit_code}, got {run['exit_code']}")
    if args.mode and run["mode"] != args.mode:
        problems.append(f"mode: expected {args.mode}, got {run['mode']}")
    for name in args.ok:
        expect(name, "ok")
    for name in args.skip:
        expect(name, "skip")
    for pair in args.status:
        name, _, status = pair.partition("=")
        expect(name, status)
    for pair in args.note:
        name, _, needle = pair.partition("=")
        notes = " | ".join(by_name.get(name, {}).get("notes", []))
        if needle not in notes:
            problems.append(f"{name}: no note containing {needle!r} (notes: {notes!r})")
    if args.no_fail:
        for c in run["cleaners"]:
            if c["status"] not in ("ok", "skip"):
                problems.append(f"{c['name']}: {c['status']} (exit {c['exit_code']}) {c['notes']}")

    totals = run["totals"]
    print(f"run: exit {run['exit_code']}, {totals['ok']} ok, {totals['skipped']} skipped, "
          f"{totals['failed']} failed, {run['duration_seconds']}s, mode {run['mode']}")
    for c in run["cleaners"]:
        print(f"  {c['status']:8} {c['name']:14} {c['seconds']:>5}s  {'; '.join(c['notes'])}")
    if problems:
        print("\nFAILED assertions:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        sys.exit(1)
    print("all assertions hold")


if __name__ == "__main__":
    main()

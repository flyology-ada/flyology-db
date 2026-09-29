#!/usr/bin/env python3
"""Run one profiler/panel process group and join it on failure or interruption."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


STOP_SIGNAL = None


def request_stop(signum, _frame):
    global STOP_SIGNAL
    STOP_SIGNAL = signum


def group_members(pgid):
    members = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if int(fields[2]) == pgid and fields[0] != "Z":
            members.append(int(entry.name))
    return members


def join_group(process):
    if process is None:
        return
    if group_members(process.pid):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 10
    while group_members(process.pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if group_members(process.pid):
        os.killpg(process.pid, signal.SIGKILL)
        deadline = time.monotonic() + 10
        while group_members(process.pid) and time.monotonic() < deadline:
            time.sleep(0.05)
    process.wait()
    if group_members(process.pid):
        raise RuntimeError("owned profiler process group did not join")


def main():
    if len(sys.argv) < 5:
        raise SystemExit("usage: run-owned.py STDOUT STDERR ARGV_JSON COMMAND...")
    stdout_path, stderr_path, argv_path = map(Path, sys.argv[1:4])
    argv = sys.argv[4:]
    if any(path.exists() for path in (stdout_path, stderr_path, argv_path)):
        raise RuntimeError("owned profiler output already exists")
    argv_path.write_text(json.dumps(argv, indent=2) + "\n")
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, request_stop)
    process = None
    status = None
    try:
        with stdout_path.open("x") as stdout, stderr_path.open("x") as stderr:
            process = subprocess.Popen(argv, stdout=stdout, stderr=stderr,
                                       start_new_session=True)
            deadline = time.monotonic() + 300
            while status is None:
                if STOP_SIGNAL is not None:
                    raise RuntimeError(f"profiler interrupted by signal {STOP_SIGNAL}")
                if time.monotonic() >= deadline:
                    raise RuntimeError("profiler deadline exceeded")
                try:
                    status = process.wait(timeout=0.2)
                except subprocess.TimeoutExpired:
                    pass
        if status != 0:
            raise RuntimeError(f"profiler/panel exited {status}")
        if group_members(process.pid):
            raise RuntimeError("profiler exited with live owned descendants")
    finally:
        join_group(process)
    print("Flyology.DB owned profiler family terminal", flush=True)


if __name__ == "__main__":
    main()

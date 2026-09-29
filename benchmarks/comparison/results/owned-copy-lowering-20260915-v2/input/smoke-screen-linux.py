#!/usr/bin/env python3
"""Native Linux literal process lifecycle checks, without benchmark execution."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

file = Path('/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-screen-copy.py')
spec = importlib.util.spec_from_file_location('screen', file)
screen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screen)
assert sys.platform == 'linux' and os.getuid() == 0
for expected in (0, 7):
    process = subprocess.Popen([sys.executable, '-c', 'import sys;sys.exit(' + str(expected) + ')'],
                               start_new_session=True)
    try:
        status = screen.wait_owned(process)
    finally:
        screen.join_owned_group(process)
    assert status == expected and not screen.group_alive(process.pid)
    print('NATIVE_OWNED_GROUP_TERMINAL', expected, flush=True)

child_code = ('import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);'
              'print("CHILD_READY",flush=True);time.sleep(60)')
parent_code = ('import signal,subprocess,sys,time;'
               'p=subprocess.Popen([sys.executable,"-c",' + repr(child_code) + '],'
               'stdout=subprocess.PIPE,text=True);assert p.stdout.readline().strip()=="CHILD_READY";'
               'signal.signal(signal.SIGTERM,signal.SIG_IGN);print("PARENT_READY",flush=True);'
               'time.sleep(60)')
process = subprocess.Popen([sys.executable, '-c', parent_code], start_new_session=True,
                           stdout=subprocess.PIPE, text=True)
try:
    assert process.stdout.readline().strip() == 'PARENT_READY'
    screen.request_stop(15, None)
    rejected = False
    try:
        screen.wait_owned(process)
    except RuntimeError:
        rejected = True
    assert rejected
finally:
    screen.join_owned_group(process)
assert process.returncode == -9 and not screen.group_alive(process.pid)
screen.stop_signal = None
screen.audit()
print('NATIVE_SIGNAL_DESCENDANT_ESCALATION_JOIN_OK', flush=True)
print('NATIVE_SCREEN_LIFECYCLE_SMOKE_OK', flush=True)

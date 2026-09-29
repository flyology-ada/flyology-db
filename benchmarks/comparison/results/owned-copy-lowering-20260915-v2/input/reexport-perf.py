#!/usr/bin/env python3
"""Read existing capture once; no benchmark, probe registration or rebuild."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess

ROOT = Path('/mnt/flyology-bench/experiments')
HELPER = ROOT / 'owned-copy-lowering-20260915-v2-screen-copy.py'
EXPORTER = ROOT / 'owned-copy-lowering-20260915-v2-export-perf-scalars.py'


def main():
    spec = importlib.util.spec_from_file_location('reviewed', HELPER)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.require(os.geteuid() == 0, 'root-owned interpretation required')
    m.require(m.sha(HELPER) == '753885bc4e9ff5c4c0af267e09713bb2872d6b9e0640168d45cbea0646f52147',
              'helper drift')
    m.require(m.sha(EXPORTER) == '514efd557759bd2566f4444a26a9afc345be55d50099345d73d5cbbfc5316e40',
              'exporter drift')
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, m.request_stop)
    capture = m.CAND.parent / 'natural-provider-profile'
    original = {str(f.relative_to(capture)): m.sha(f) for f in capture.rglob('*') if f.is_file()}
    m.require(m.sha(capture / 'perf.data')
              == 'f7c349dc709f96a68764633fa60a9095df5c328a079348f7f3a8ac84b4dc7bf6', 'capture drift')
    out = m.CAND.parent / 'natural-provider-typed-export-v1'
    m.require(not out.exists() and not out.is_symlink(), 'interpretation output exists')
    with open('/run/lock/flyology-db-aws-campaign.lock', 'a') as campaign:
        fcntl.flock(campaign, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with open('/run/lock/flyology-bench-host-cpu.lock', 'a') as cpu:
            fcntl.flock(cpu, fcntl.LOCK_EX | fcntl.LOCK_NB)
            m.audit()
            before = m.snapshot(m.CAND)
            m.require(before == json.loads((capture / 'source-after.json').read_text()), 'source drift')
            out.mkdir()
            m.write(out / 'source-before.json', before)
            m.write(out / 'original-inventory.json', original)
            commands = [
                ('typed', ['perf', 'script', '--show-lost-events', '-i', str(capture / 'perf.data'),
                           '-s', str(EXPORTER)]),
                ('inventory', ['perf', 'script', '--show-lost-events', '--ns', '-i', str(capture / 'perf.data'),
                               '-F', 'trace:comm,pid,tid,time,cpu,event,period',
                               '-F', 'sw:comm,pid,tid,time,event,period,ip,sym,dso']),
            ]
            try:
                for name, argv in commands:
                    m.write(out / (name + '-invocation.json'), argv)
                    with (out / (name + '.stdout')).open('x') as stdout:
                        with (out / (name + '.stderr')).open('x') as stderr:
                            m.require(m.stop_signal is None, 'interrupted before export')
                            process = subprocess.Popen(argv, stdout=stdout, stderr=stderr,
                                                       start_new_session=True)
                            try:
                                m.write(out / (name + '-active.json'), {'pid': process.pid, 'argv': argv})
                                print('REEXPORT_ACTIVE', name, process.pid, flush=True)
                                status = m.wait_owned(process)
                            finally:
                                m.join_owned_group(process)
                    m.write(out / (name + '-status.json'), {'exit_status': status})
                    m.require(status == 0 and not (out / (name + '.stderr')).read_bytes(),
                              'export status/diagnostic failure: ' + name)
            finally:
                after = m.snapshot(m.CAND)
                m.write(out / 'source-after.json', after)
                m.require(after == before, 'source closure drift during interpretation')
                actual = {str(f.relative_to(capture)): m.sha(f) for f in capture.rglob('*') if f.is_file()}
                m.require(actual == original, 'original failed capture artifacts changed')
                m.audit()
                print('SOURCE_AND_CAPTURE_EXACT RESOURCE_AUDIT_CLEAN FORMAL_AUDIT_CLEAN', flush=True)
    print('DB_TYPED_EXPORT_WINDOW_RELEASED', flush=True)


if __name__ == '__main__':
    main()

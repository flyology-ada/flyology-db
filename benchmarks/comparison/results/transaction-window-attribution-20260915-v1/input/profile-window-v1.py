#!/usr/bin/env python3
"""Bounded diagnostic only; raw instruction probes do not establish speedup."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path('/mnt/flyology-bench/experiments/transaction-window-attribution-20260915-v1-x86_64')
SOURCE = Path('/mnt/flyology-bench/experiments/pipelined-adaptive-natural-20260914-v5-x86_64/source')
BINARY = SOURCE / 'benchmarks/comparison/bin/flyology_db_benchmark'
EXPECTED = '6bc8b3175ffdaf64a52f059d9fbb329b08c07bf88e46f82229ba2b9f364f76dd'
GROUP = 'dbwindow20260915v1'
EVENTS = Path('/sys/kernel/tracing/uprobe_events')
assert os.geteuid() == 0
locks = []
for name in ('flyology-db-aws-campaign.lock', 'flyology-bench-host-cpu.lock'):
    lock = open('/run/lock/' + name, 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    locks.append(lock)
assert not ROOT.exists() and not ROOT.is_symlink(), 'owned output already exists'
assert hashlib.sha256(BINARY.read_bytes()).hexdigest() == EXPECTED
image = BINARY.read_bytes()
# readelf PT_LOAD has p_offset == p_vaddr for the executable segment.
assert image[0x26290c:0x262913] == bytes.fromhex('488985b8f6ffff')
assert image[0x26296d:0x262972] == bytes.fromhex('e89eeb8200')
assert GROUP not in EVENTS.read_text(), 'owned event namespace already exists'
processes = subprocess.check_output(['ps', '-eo', 'pid=,args='], text=True)
for row in processes.splitlines():
    fields = row.split()
    if len(fields) < 2 or int(fields[0]) == os.getpid():
        continue
    executable = Path(fields[1]).name
    assert executable not in ('perf', 'alr', 'gprbuild', 'gnatprove', 'tlapm',
                              'flyology_db_benchmark', 'flyology_db_benchmark_panel'), row
ROOT.mkdir()
(ROOT / 'processes-before.txt').write_text(processes)
(ROOT / 'binary-identity.json').write_text(json.dumps({
    'binary': str(BINARY), 'sha256': EXPECTED,
    'start_file_offset': '0x26290c', 'end_file_offset': '0x26296d',
    'boundary': 'post first Clock / pre last Clock; not exact Ada elapsed interval',
    'purpose': 'diagnostic CPU attribution; not promotion timing',
}, indent=2) + '\n')
detector = SOURCE.parent / 'input/check-power-profile.sh'
with open(ROOT / 'power-before.env', 'x') as out:
    power = subprocess.run(['bash', str(detector)], stdout=out, stderr=subprocess.STDOUT)
assert power.returncode in (0, 2), 'reduced performance or detector failure'
environment = os.environ.copy()
for name in list(environment):
    if name.startswith('FLYOLOGY_DB_BENCH_'):
        del environment[name]
environment.update({
    'FLYOLOGY_DB_BENCH_PIPELINE_DEPTH': '32',
    'FLYOLOGY_DB_BENCH_PREPARATION_WIDTH': '1',
    'FLYOLOGY_DB_BENCH_PACKED_ADMISSION': '0',
    'FLYOLOGY_DB_BENCH_PIPELINE_SCHEDULE': 'rolling',
    'FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_MEMBERS': '8',
    'FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_ENCODED_BYTES': '2159008',
    'FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_WAIT_US': '10000',
    'FLYOLOGY_DB_BENCH_ADAPTIVE_ADMISSION_DEPTH': '32',
    'FLYOLOGY_DB_BENCH_ADAPTIVE_PREPARATION_CONCURRENCY': '2',
    'FLYOLOGY_DB_BENCH_ADAPTIVE_PIPELINE_COHORTS': '2',
    'LD_LIBRARY_PATH': ':'.join(str(SOURCE / p) for p in (
        'benchmarks/comparison/slatedb/target/release',
        'oracles/adapters/tidesdb/build', 'oracles/adapters/tidesdb/build/upstream')),
})
(ROOT / 'configuration.json').write_text(json.dumps({
    key: value for key, value in environment.items() if key.startswith('FLYOLOGY_DB_BENCH_')
}, indent=2) + '\n')
registered = []
target = None
pending_signal = None
def event_write(line):
    with open(EVENTS, 'a') as out:
        out.write(line + '\n')

def interrupted(signum, frame):
    global pending_signal
    pending_signal = signum

def live_group(pgid):
    live = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
        except FileNotFoundError:
            continue
        if int(fields[2]) == pgid and fields[0] != 'Z':
            live.append(int(entry.name))
    return live

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)

try:
    for name, offset in (('window_start', '0x26290c'), ('window_end', '0x26296d')):
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
        try:
            event_write(f'p:{GROUP}/{name} {BINARY}:{offset}')
            registered.append(name)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    (ROOT / 'registered-events.txt').write_text(EVENTS.read_text())
    command = ['perf', 'record', '-o', str(ROOT / 'perf.data'), '--clockid', 'mono',
               '-e', 'cpu-clock/period=250000/u', '-e', GROUP + ':window_start',
               '-e', GROUP + ':window_end', '-e', 'syscalls:sys_enter_fsync',
               '-e', 'syscalls:sys_exit_fsync', '-e', 'syscalls:sys_enter_fdatasync',
               '-e', 'syscalls:sys_exit_fdatasync', '--', str(BINARY), 'local',
               str(ROOT / 'retained-db'), '8', '35', '16', '1024', '256']
    (ROOT / 'invocation.json').write_text(json.dumps(command, indent=2) + '\n')
    with open(ROOT / 'benchmark.stdout', 'x') as out, open(ROOT / 'benchmark.stderr', 'x') as err:
        assert pending_signal is None, 'interrupted before target launch'
        target = subprocess.Popen(command, cwd=SOURCE, env=environment, stdout=out,
                                  stderr=err, start_new_session=True)
        limit = time.monotonic() + 120
        while True:
            assert pending_signal is None, f'collector interrupted by signal {pending_signal}'
            assert time.monotonic() < limit, 'profile deadline exceeded'
            try:
                status = target.wait(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                pass
    (ROOT / 'terminal.json').write_text(json.dumps({'exit_status': status}) + '\n')
    assert status == 0, 'profile/benchmark failed; no retry'
    with open(ROOT / 'samples.txt', 'x') as out, open(ROOT / 'samples.stderr', 'x') as err:
        subprocess.run(['perf', 'script', '--ns', '-i', str(ROOT / 'perf.data'),
                        '-F', '+pid,+tid,+period'], stdout=out, stderr=err, check=True)
finally:
    # Stop only this owned process group on failure; join before deleting probes.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    if target is not None:
        try:
            os.killpg(target.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            target.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(target.pid, signal.SIGKILL)
            target.wait()
        limit = time.monotonic() + 10
        while live_group(target.pid) and time.monotonic() < limit:
            time.sleep(0.05)
        if live_group(target.pid):
            os.killpg(target.pid, signal.SIGKILL)
            limit = time.monotonic() + 10
            while live_group(target.pid) and time.monotonic() < limit:
                time.sleep(0.05)
        assert not live_group(target.pid), 'owned descendant still running; retain probes for diagnosis'
    cleanup_errors = []
    for name in reversed(registered):
        try:
            event_write(f'-:{GROUP}/{name}')
        except OSError as error:
            cleanup_errors.append(str(error))
    (ROOT / 'events-after.txt').write_text(EVENTS.read_text())
    assert not cleanup_errors, cleanup_errors
    assert GROUP not in EVENTS.read_text(), 'owned probe residue'
assert hashlib.sha256(BINARY.read_bytes()).hexdigest() == EXPECTED
(ROOT / 'processes-after.txt').write_text(
    subprocess.check_output(['ps', '-eo', 'pid=,args='], text=True))
print('DB_TRANSACTION_WINDOW_PROFILE_TERMINAL', flush=True)

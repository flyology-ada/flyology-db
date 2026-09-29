#!/usr/bin/env python3
"""Exact-candidate CPU/syscall diagnostic; instrumented times are not speedup evidence."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
from collections import Counter

HELPER = Path('/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-screen-copy.py')
PHASE = Path('/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-phase-screen.py')
EVENTS = Path('/sys/kernel/tracing/uprobe_events')
GROUP = 'dbnatural20260915v3'
# Exact optimized ELF call sites, not old W10 offsets. Both LOAD offset/VA bases are zero.
PROBES = (
    ('window_start', 0x27798c, '488985b8f6ffff'),
    ('window_end', 0x2779ed, 'e8de128900'),
    ('batch_put_start', 0x36358f, 'e82c1afcff'),
    ('batch_put_end', 0x363594, '4883c420'),
)

def load(file, name):
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def event_write(line):
    data = (line + '\n').encode('ascii')
    fd = os.open(EVENTS, os.O_WRONLY)
    try:
        require(os.write(fd, data) == len(data), 'partial tracefs command')
    finally:
        os.close(fd)

def validate_events(text, metrics):
    """Pair exact probes/syscalls before permitting a provider attribution report."""
    grammar = re.compile(r'^\s*\S+\s+(\d+)/(\d+)\s+(?:\[\d+\]\s+)?'
                         r'(\d+)\.(\d{9}):\s+(\d+)\s+(\S+):\s*(.*)$')
    records = []
    for line in text.splitlines():
        if not line.strip():
            continue
        match = grammar.fullmatch(line)
        require(match is not None, 'malformed or unsupported perf record: ' + line)
        pid, tid, seconds, nanos, period, event, body = match.groups()
        records.append((int(seconds) * 10**9 + int(nanos), int(pid), int(tid),
                        int(period), event, body))
    records.sort(key=lambda record: record[0])
    windows, batches, syscalls = [], [], []
    active_windows, active_batches, active_syscalls = {}, {}, {}
    for stamp, pid, tid, period, event, body in records:
        key = pid, tid
        if event == GROUP + ':window_start':
            require(pid not in active_windows, 'nested transaction window')
            active_windows[pid] = stamp, tid
        elif event == GROUP + ':window_end':
            require(pid in active_windows, 'unmatched window completion')
            start, owner = active_windows.pop(pid)
            require(owner == tid and stamp > start, 'window identity or duration mismatch')
            windows.append({'pid': pid, 'tid': tid, 'start': start, 'end': stamp})
        elif event == GROUP + ':batch_put_start':
            require(key not in active_batches, 'nested batch wrapper on one TID')
            active_batches[key] = stamp
        elif event == GROUP + ':batch_put_end':
            require(key in active_batches, 'unmatched batch normal continuation')
            start = active_batches.pop(key)
            require(stamp > start, 'invalid batch duration')
            batches.append({'pid': pid, 'tid': tid, 'start': start, 'end': stamp})
        elif event.startswith('syscalls:sys_enter_'):
            syscall = event.removeprefix('syscalls:sys_enter_')
            syscall_key = pid, tid, syscall
            require(syscall_key not in active_syscalls, 'nested syscall entry')
            active_syscalls[syscall_key] = stamp, body
        elif event.startswith('syscalls:sys_exit_'):
            syscall = event.removeprefix('syscalls:sys_exit_')
            syscall_key = pid, tid, syscall
            require(syscall_key in active_syscalls, 'unmatched syscall exit')
            start, arguments = active_syscalls.pop(syscall_key)
            require(stamp >= start and re.fullmatch(r'0x[0-9a-f]+', body),
                    'malformed syscall return or duration')
            value = int(body, 16)
            result = value - 2**64 if value >= 2**63 else value
            syscalls.append({'pid': pid, 'tid': tid, 'start': start, 'end': stamp,
                             'name': syscall, 'arguments': arguments, 'result': result})
        else:
            require(event == 'cpu-clock/period=250000/u', 'unexpected perf event: ' + event)
            require(period == 250000, 'unexpected CPU sample period')
    require(not active_windows and not active_batches and not active_syscalls, 'unjoined event intervals')
    configs = [row for row in metrics if row.get('kind') == 'flyology_db_execution_configuration']
    configs.sort(key=lambda row: row['execution_ordinal'])
    require(len(windows) == len(configs) > 0
            and [c['execution_ordinal'] for c in configs] == list(range(1, len(configs) + 1)),
            'window count does not match exact execution inventory')
    require(len({(w['pid'], w['tid']) for w in windows}) == 1, 'ambiguous primary owner')
    report = []
    for window, config in zip(windows, configs):
        contained = [batch for batch in batches if batch['pid'] == window['pid']
                     and window['start'] <= batch['start'] and batch['end'] <= window['end']]
        crossing = [batch for batch in batches if batch['pid'] == window['pid']
                    and batch['start'] < window['end'] and batch['end'] > window['start']]
        require(contained == crossing, 'batch wrapper crosses primary window boundary')
        require(len(contained) == config['batch_publications'] == config['head_publications'],
                'batch probes do not reproduce actual publications')
        batch_cpu, batch_periods, syscall_counts, syscall_elapsed = Counter(), 0, Counter(), Counter()
        for batch in contained:
            for stamp, pid, tid, period, event, body in records:
                if (pid, tid) == (batch['pid'], batch['tid']) and batch['start'] <= stamp <= batch['end']:
                    if event == 'cpu-clock/period=250000/u':
                        # Flat symbol/IP ranking only. Unknown symbols are retained, not dropped.
                        parts = body.split()
                        require(len(parts) >= 2, 'malformed CPU symbol record')
                        batch_cpu[parts[1].split('+')[0]] += 1
                        batch_periods += period
            for syscall in syscalls:
                if (syscall['pid'], syscall['tid']) != (batch['pid'], batch['tid']):
                    continue
                overlaps = syscall['start'] < batch['end'] and syscall['end'] > batch['start']
                if overlaps:
                    require(batch['start'] <= syscall['start'] and syscall['end'] <= batch['end'],
                            'syscall crosses batch wrapper boundary')
                    require(syscall['result'] >= 0, 'failed publication syscall')
                    if syscall['name'] in ('fsync', 'fdatasync', 'rename', 'renameat', 'renameat2'):
                        require(syscall['result'] == 0, 'unexpected publication syscall result')
                    syscall_counts[syscall['name']] += 1
                    syscall_elapsed[syscall['name']] += syscall['end'] - syscall['start']
        report.append({'execution_ordinal': config['execution_ordinal'], 'participant': config['participant'],
                       'window': window, 'batch_spans': contained, 'batch_symbol_sample_counts': batch_cpu,
                       'sample_period_sum_ns_not_total_cpu': batch_periods,
                       'batch_syscall_counts': syscall_counts,
                       'batch_syscall_elapsed_ns_includes_scheduling': syscall_elapsed})
    return {'classification': 'batch_wrapper_diagnostic_not_removable_cpu_io_partition',
            'executions': report, 'all_batch_invocations_including_warmup': len(batches),
            'omissions': ['Outside-batch events are not HEAD attribution.',
                         'Flat user CPU samples omit kernel CPU and are not complete stack attribution.',
                         'Sample periods and syscall elapsed may not be subtracted from wall time.']}

def main():
    require(os.geteuid() == 0, 'root-owned capture required')
    require(not os.environ.get('LD_PRELOAD') and not os.environ.get('LD_AUDIT'), 'loader injection')
    require(hashlib.sha256(HELPER.read_bytes()).hexdigest()
            == '753885bc4e9ff5c4c0af267e09713bb2872d6b9e0640168d45cbea0646f52147', 'helper drift')
    require(hashlib.sha256(PHASE.read_bytes()).hexdigest()
            == 'e843bf60711bb2f50e53a9346ab48978d6d36be697b589b6cda3fa1593fe2308', 'phase validator drift')
    m, phase = load(HELPER, 'reviewed'), load(PHASE, 'phase')
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, m.request_stop)
    with open('/run/lock/flyology-db-aws-campaign.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        subprocess.check_call(['flock', '-n', '/run/lock/flyology-bench-host-cpu.lock', 'true'])
        tree, benchmark = m.CAND, m.CAND / 'benchmarks/comparison'
        binary = benchmark / 'bin/flyology_db_benchmark_panel'
        before = m.snapshot(tree)
        require(before == json.loads((tree.parent / 'natural-phase-screen/source-before.json').read_text()),
                'candidate no longer matches phase receipt')
        image = binary.read_bytes()
        require(hashlib.sha256(image).hexdigest() == m.PANEL_HASHES[tree], 'panel drift')
        # Validate ELF64 little-endian and an executable PT_LOAD mapping every probe identically.
        require(image[:6] == b'\x7fELF\x02\x01', 'unsupported ELF format')
        headers = [struct.unpack_from('<IIQQQQQQ', image,
                   struct.unpack_from('<Q', image, 32)[0] + i * 56)
                   for i in range(struct.unpack_from('<H', image, 56)[0])]
        for name, offset, code in PROBES:
            require(image[offset:offset + len(bytes.fromhex(code))] == bytes.fromhex(code),
                    'probe instruction drift: ' + name)
            require(any(h[0] == 1 and h[1] & 1 and h[2] == h[3] == 0
                        and offset + len(bytes.fromhex(code)) <= h[5] for h in headers),
                    'probe is not identically mapped executable bytes: ' + name)
        require(GROUP not in EVENTS.read_text(), 'owned probe namespace already exists')
        m.audit()
        out = tree.parent / 'natural-provider-profile'
        require(not out.exists() and not out.is_symlink(), 'output already exists')
        out.mkdir()
        scratch = out / 'scratch'
        scratch.mkdir()
        m.write(out / 'source-before.json', before)
        detector = tree / '.agents/skills/performance-testing/scripts/check-power-profile.sh'
        require(m.sha(detector) == 'f0a0b961b3c4d849bce37dbeb0857450fdd974a8d2e546c59c09f157bc467a16',
                'detector drift')
        power = subprocess.run(['sh', str(detector)], capture_output=True, text=True)
        (out / 'power.env').write_text(power.stdout)
        m.write(out / 'power-status.json', {'exit_status': power.returncode})
        require(power.returncode in (0, 2) and not power.stderr, 'reduced or failed detector')
        env = {k: v for k, v in os.environ.items() if not k.startswith('FLYOLOGY_DB_')}
        env.update(FLYOLOGY_DB_BENCH_WARMUP='8', FLYOLOGY_DB_BENCH_SCRATCH_ROOT=str(scratch),
                   TMPDIR=str(scratch), FLYOLOGY_BENCH_LOCK_PATH='/run/lock/flyology-bench-host-cpu.lock',
                   LD_LIBRARY_PATH=':'.join(map(str, [benchmark / 'slatedb/target/release',
                       tree / 'oracles/adapters/tidesdb/build', tree / 'oracles/adapters/tidesdb/build/upstream'])))
        registered, process = [], None
        try:
            for name, offset, code in PROBES:
                mask = signal.pthread_sigmask(signal.SIG_BLOCK,
                                              {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
                try:
                    event_write(f'p:{GROUP}/{name} {binary}:0x{offset:x}')
                    registered.append(name)
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, mask)
            (out / 'events-before.txt').write_text(EVENTS.read_text())
            argv = ['perf', 'record', '-o', str(out / 'perf.data'), '--clockid', 'mono',
                    '-e', 'cpu-clock/period=250000/u']
            for name, offset, code in PROBES:
                argv += ['-e', GROUP + ':' + name]
            for syscall in ('write', 'pwrite64', 'fsync', 'fdatasync', 'rename', 'renameat', 'renameat2'):
                for boundary in ('enter', 'exit'):
                    argv += ['-e', f'syscalls:sys_{boundary}_{syscall}']
            argv += ['--', str(binary), phase.DB, phase.DIAG, '16', '1024', '256', '35',
                     str(out / 'comparison.json'), str(out / 'metrics.ndjson')]
            m.write(out / 'invocation.json', argv)
            m.write(out / 'probe-boundaries.json', {
                'probes': PROBES, 'window': 'post first Clock / pre last Clock; approximate Ada interval',
                'batch': 'Put_Create call / normal return, excludes key construction and result mapping',
                'omissions': 'Outside-batch events are not HEAD attribution; flat CPU samples are ranking only',
                'classification': 'diagnostic_only_no_timing_promotion'})
            with (out / 'panel.stdout').open('x') as stdout, (out / 'perf.stderr').open('x') as stderr:
                require(m.stop_signal is None, 'interrupted before launch')
                process = subprocess.Popen(argv, env=env, stdout=stdout, stderr=stderr,
                                           start_new_session=True)
                try:
                    m.write(out / 'active.json', {'pid': process.pid, 'argv': argv})
                    print('NATURAL_PROVIDER_PROFILE_ACTIVE', process.pid, flush=True)
                    status = m.wait_owned(process)
                finally:
                    m.join_owned_group(process)
            m.write(out / 'status.json', {'exit_status': status})
            require(status == 0 and (out / 'panel.stdout').read_bytes() == b'', 'perf or panel failure')
            expected_log = (
                r'\[ perf record: Woken up [0-9]+ times to write data \]',
                r'\[ perf record: Captured and wrote [0-9]+\.[0-9]+ MB '
                + re.escape(str(out / 'perf.data')) + r' \([0-9]+ samples\) \]',
            )
            require(all(any(re.fullmatch(pattern, line) for pattern in expected_log)
                        for line in (out / 'perf.stderr').read_text().splitlines()),
                    'unexpected perf or benchmark diagnostic')
            require(not list(scratch.iterdir()), 'scratch residue')
            loader = load(benchmark / 'run_realistic_campaign.py', 'retained_loader')
            m.write(out / 'validated.json', phase.validate(loader, out / 'comparison.json',
                                                          out / 'metrics.ndjson'))
            with (out / 'samples.txt').open('x') as stdout, (out / 'samples.stderr').open('x') as stderr:
                require(m.stop_signal is None, 'interrupted before sample export')
                exporter = subprocess.Popen(['perf', 'script', '--show-lost-events', '--ns',
                                             '-i', str(out / 'perf.data'), '-F', '+pid,+tid,+period'],
                                            stdout=stdout, stderr=stderr, start_new_session=True)
                try:
                    m.write(out / 'active-exporter.json', {'pid': exporter.pid})
                    export_status = m.wait_owned(exporter)
                finally:
                    m.join_owned_group(exporter)
                require(export_status == 0, 'perf sample export failed')
            require((out / 'samples.stderr').read_bytes() == b'', 'perf script diagnostic')
            require(not re.search(r'PERF_RECORD_LOST|LOST [0-9]+ events',
                                  (out / 'samples.txt').read_text()), 'lost perf events')
            metrics = [json.loads(line) for line in (out / 'metrics.ndjson').read_text().splitlines()
                       if line.strip()]
            m.write(out / 'provider-attribution.json', validate_events((out / 'samples.txt').read_text(),
                                                                      metrics))
        except BaseException as error:
            m.write(out / 'failure.json', {'error': repr(error)})
            raise
        finally:
            cleanup_errors = []
            for name in reversed(registered):
                try:
                    event_write('-:' + GROUP + '/' + name)
                except Exception as error:
                    cleanup_errors.append({'event': name, 'error': repr(error)})
            (out / 'events-after.txt').write_text(EVENTS.read_text())
            m.write(out / 'cleanup-errors.json', cleanup_errors)
            after = m.snapshot(tree)
            m.write(out / 'source-after.json', after)
            require(not cleanup_errors and GROUP not in EVENTS.read_text(), 'owned probe cleanup failure')
            require(after == before, 'candidate input drift')
        require(m.stop_signal is None, 'interrupted capture')
        m.audit()
        print('DB_NATURAL_PROVIDER_PROFILE_TERMINAL', flush=True)

if __name__ == '__main__':
    main()

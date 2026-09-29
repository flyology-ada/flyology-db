#!/usr/bin/env python3
"""Generate diagnostic attribution from retained perf-script output."""
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
lines = (root / 'samples.txt').read_text().splitlines()
assert not any('LOST' in line.upper() for line in lines)
assert not (root / 'samples.stderr').read_text().strip()
grammar = re.compile(
    r'^\s*(\S+)\s+(\d+)/(\d+)\s+(?:\[(\d+)\]\s+)?'
    r'(\d+)\.(\d{9}):\s+(\d+)\s+(\S+):\s+(.*)$')
events = []
for line in lines:
    if not line.strip():
        continue
    match = grammar.fullmatch(line)
    assert match, line
    comm, pid, tid, cpu, second, fraction, period, event, body = match.groups()
    events.append({'pid': int(pid), 'tid': int(tid), 'time_ns': int(second) * 10**9 + int(fraction),
                   'period': int(period), 'event': event, 'body': body})
starts = [event for event in events if event['event'].endswith(':window_start')]
ends = [event for event in events if event['event'].endswith(':window_end')]
assert len(starts) == len(ends) == 1
start, end = starts[0], ends[0]
assert start['pid'] == end['pid'] and start['tid'] == end['tid']
assert start['time_ns'] < end['time_ns']
window = [event for event in events if event['pid'] == start['pid']
          and start['time_ns'] <= event['time_ns'] <= end['time_ns']]
symbols = Counter()
per_thread = defaultdict(Counter)
for event in window:
    if event['event'].startswith('cpu-clock/'):
        parts = event['body'].split(' ', 1)
        assert len(parts) == 2
        symbol = re.sub(r'\+0x[0-9a-f]+(?= |$)', '', parts[1])
        symbols[symbol] += 1
        per_thread[event['tid']][symbol] += 1
sync = []
pending = {}
for event in events:
    if event['event'].startswith('syscalls:sys_enter_'):
        name = event['event'].removeprefix('syscalls:sys_enter_')
        key = (event['tid'], name)
        assert key not in pending, event
        pending[key] = event
    elif event['event'].startswith('syscalls:sys_exit_'):
        name = event['event'].removeprefix('syscalls:sys_exit_')
        key = (event['tid'], name)
        assert key in pending, event
        enter = pending.pop(key)
        if start['time_ns'] <= enter['time_ns'] <= event['time_ns'] <= end['time_ns']:
            sync.append({'tid': event['tid'], 'name': name,
                         'elapsed_ns': event['time_ns'] - enter['time_ns'],
                         'result': event['body']})
assert not pending
stdout = (root / 'benchmark.stdout').read_text()
assert 'verified_keys= 11008\n' in stdout
assert 'state_sha256=090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb\n' in stdout
report = {
    'classification': 'single instrumented diagnostic; CPU shares are not removable wall-time shares',
    'samples_sha256': hashlib.sha256((root / 'samples.txt').read_bytes()).hexdigest(),
    'marker_window_ns': end['time_ns'] - start['time_ns'],
    'ada_elapsed_ns': int(re.search(r'elapsed_nanoseconds=\s*(\d+)', stdout).group(1)),
    'caller_tid': start['tid'], 'cpu_samples': sum(symbols.values()),
    'top_symbols': symbols.most_common(30),
    'threads': {tid: {'samples': sum(counts.values()), 'top': counts.most_common(12)}
                for tid, counts in per_thread.items()},
    'sync_count': len(sync), 'sync_sum_ns_not_wall_share': sum(row['elapsed_ns'] for row in sync),
    'sync_calls': sync,
}
output = root / 'window-analysis.json'
assert not output.exists()
output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

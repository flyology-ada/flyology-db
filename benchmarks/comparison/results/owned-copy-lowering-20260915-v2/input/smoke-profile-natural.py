#!/usr/bin/env python3
"""Literal event/parser controls, no perf/tracefs/benchmark invocation."""
import importlib.util
from pathlib import Path

file = Path(__file__).with_name('profile-natural.py')
spec = importlib.util.spec_from_file_location('profile', file)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
group = module.GROUP
rows = [
    f' bench 10/10 [001] 1.000000000: 1 {group}:window_start: (0x100)',
    f' bench 10/11 [001] 1.001000000: 1 {group}:batch_put_start: (0x200)',
    ' bench 10/11 1.002000000: 250000 cpu-clock/period=250000/u: abcd gnat__md5__update+0x4 (binary)',
    ' bench 10/11 [001] 1.003000000: 1 syscalls:sys_enter_fsync: fd: 0x3',
    ' bench 10/11 [001] 1.004000000: 1 syscalls:sys_exit_fsync: 0x0',
    f' bench 10/11 [002] 1.005000000: 1 {group}:batch_put_end: (0x205)',
    f' bench 10/10 [001] 1.006000000: 1 {group}:window_end: (0x105)',
]
configs = [{'kind': 'flyology_db_execution_configuration', 'execution_ordinal': 1,
            'participant': 'literal', 'batch_publications': 1, 'head_publications': 1}]
result = module.validate_events('\n'.join(rows), configs)
entry = result['executions'][0]
assert entry['batch_syscall_counts'] == {'fsync': 1}
assert entry['batch_syscall_elapsed_ns_includes_scheduling'] == {'fsync': 1000000}
assert entry['batch_symbol_sample_counts'] == {'gnat__md5__update': 1}
assert entry['sample_period_sum_ns_not_total_cpu'] == 250000
assert entry['window']['end'] - entry['window']['start'] == 6000000

cases = [
    ('missing_window_end', rows[:-1], configs),
    ('missing_batch_end', rows[:5] + rows[6:], configs),
    ('wrong_batch_tid', rows[:5] + [rows[5].replace('10/11', '10/12')] + rows[6:], configs),
    ('nested_window', [rows[0]] + rows, configs),
    ('nested_batch', rows[:2] + [rows[1]] + rows[2:], configs),
    ('missing_syscall_exit', rows[:4] + rows[5:], configs),
    ('missing_syscall_entry', rows[:3] + rows[4:], configs),
    ('negative_syscall', rows[:4] + [rows[4].replace('0x0', '0xffffffffffffffff')] + rows[5:], configs),
    ('malformed_syscall_result', rows[:4] + [rows[4].replace('0x0', 'garbage')] + rows[5:], configs),
    ('short_timestamp', [rows[0].replace('1.000000000', '1.0')] + rows[1:], configs),
    ('wrong_sample_period', rows[:2] + [rows[2].replace('250000 cpu', '125000 cpu')] + rows[3:], configs),
    ('unknown_event', rows + [' bench 10/10 1.007000000: 1 unexpected: value'], configs),
    ('lost_record', rows + ['LOST 100 events'], configs),
    ('wrong_batch_count', rows, [{**configs[0], 'batch_publications': 2, 'head_publications': 2}]),
    ('duplicate_config', rows, configs + configs),
    ('crossed_window', [rows[0].replace('1.000000000', '1.001500000')] + rows[1:], configs),
]
for name, text, inventory in cases:
    try:
        module.validate_events('\n'.join(text), inventory)
    except RuntimeError:
        continue
    raise AssertionError('forbidden literal accepted: ' + name)
print('NATURAL_PROFILE_LITERAL_SMOKE_OK', len(cases), 'fail-closed controls')

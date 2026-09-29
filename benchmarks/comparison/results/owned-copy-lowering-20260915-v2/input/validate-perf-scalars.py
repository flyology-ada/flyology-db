#!/usr/bin/env python3
"""Cross-check typed export against payload-free native inventory before attribution."""
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import statistics
import sys

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = ROOT / 'artifacts/x86_64/natural-provider-typed-export-v1/natural-provider-typed-export-v1'
CAPTURE = ROOT / 'artifacts/x86_64/natural-provider-receipt/natural-provider-profile'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def pairs(values):
    result = {}
    for key, value in values:
        require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def identity(row):
    return tuple(row[key] for key in ('pid', 'tid', 'time', 'period', 'event'))


def crosscheck(rows, inventory):
    grammar = re.compile(r'^\s*\S+\s+(\d+)/(\d+)\s+(?:\[\d+\]\s+)?'
                         r'(\d+)\.(\d{9}):\s+(\d+)\s+(\S+):\s*(.*)$')
    records = []
    for line in inventory.splitlines():
        require(line.strip(), 'unexpected empty inventory line')
        match = grammar.fullmatch(line)
        require(match is not None, 'lost, malformed or unexpected inventory record: ' + line)
        pid, tid, sec, ns, period, event, body = match.groups()
        if event == 'cpu-clock/period=250000/u':
            require(re.fullmatch(r'[0-9a-f]+ \S+ \(\S+\)', body) is not None,
                    'malformed CPU inventory body')
        else:
            require(not body, 'inventory includes trace payload or diagnostic')
        records.append((int(pid), int(tid), int(sec) * 10**9 + int(ns), int(period), event))
    require(Counter(map(identity, rows)) == Counter(records), 'typed/native sample inventory mismatch')
    require(len(rows) > 0, 'empty capture')


def canonical(rows):
    lines = []
    for row in rows:
        event = row['event']
        common = {'pid', 'tid', 'time', 'period', 'event'}
        extra = {'ip', 'symbol', 'dso'} if event == 'cpu-clock/period=250000/u' else {'arguments'}
        require(set(row) == common | extra, 'unexpected typed schema')
        for key in common - {'event'}:
            require(type(row[key]) is int and 0 <= row[key] < 2**64, 'invalid typed numeric field')
        require(row['pid'] > 0 and row['tid'] > 0 and row['period'] > 0, 'invalid identity/period')
        if event == 'cpu-clock/period=250000/u':
            require(type(row['ip']) is int and 0 <= row['ip'] < 2**64, 'invalid CPU IP')
            require(all(type(row[k]) is str and row[k] and not any(c.isspace() for c in row[k])
                        for k in ('symbol', 'dso')), 'invalid CPU symbol/DSO')
            body = f"{row['ip']:x} {row['symbol']} ({row['dso']})"
        else:
            arguments = row['arguments']
            require(type(arguments) is dict, 'invalid typed argument object')
            if event.startswith('syscalls:sys_exit_'):
                require(set(arguments) == {'ret'}, 'invalid syscall exit fields')
                value = arguments['ret']
                require(type(value) is int and -(2**63) <= value < 2**63, 'invalid syscall result')
                body = f'0x{value % 2**64:x}'
            else:
                name = event.removeprefix('syscalls:sys_enter_')
                expected = {'fd'} if name in ('fsync', 'fdatasync') else set()
                if name in ('write', 'pwrite64'):
                    expected = {'fd', 'count'} | ({'pos'} if name == 'pwrite64' else set())
                require(set(arguments) == expected, 'invalid syscall/probe fields')
                for key, value in arguments.items():
                    minimum = -(2**63) if key == 'pos' else 0
                    require(type(value) is int and minimum <= value < 2**64, 'invalid argument scalar')
                body = ' '.join(f'{k}={v}' for k, v in sorted(arguments.items()))
        sec, ns = divmod(row['time'], 10**9)
        lines.append(f"typed {row['pid']}/{row['tid']} {sec}.{ns:09d}: {row['period']} {event}: {body}")
    return '\n'.join(lines)


def main():
    rows = [json.loads(line, object_pairs_hook=pairs) for line in (RECEIPT / 'typed.stdout').read_text().splitlines()]
    inventory = (RECEIPT / 'inventory.stdout').read_text()
    crosscheck(rows, inventory)
    # Real retained-data negative controls, not another native export/capture.
    changed = [dict(row) for row in rows]
    changed[0]['tid'] += 1
    for name, candidate, text in (
            ('deletion', rows[1:], inventory), ('duplication', rows + rows[:1], inventory),
            ('identity', changed, inventory),
            ('lost', rows, inventory.rstrip('\n') + '\nPERF_RECORD_LOST 1\n')):
        try:
            crosscheck(candidate, text)
        except RuntimeError as error:
            require('PERF_RECORD_LOST 1' in str(error) if name == 'lost'
                    else 'inventory mismatch' in str(error), 'negative control failed for wrong reason')
        else:
            raise AssertionError('accepted completeness failure: ' + name)
    require(all((RECEIPT / (name + '-status.json')).read_text().strip() == '{\n  "exit_status": 0\n}'
                and not (RECEIPT / (name + '.stderr')).read_bytes() for name in ('typed', 'inventory')),
            'native export failure or warning')
    parser = ROOT / 'input/profile-natural.py'
    require(hashlib.sha256(parser.read_bytes()).hexdigest()
            == 'a09f74f5eb3239d8baf9f6d93b3afaacf4f8fece590f4cc266a99e7e70d1d7b9', 'interval parser drift')
    spec = importlib.util.spec_from_file_location('intervals', parser)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    metrics = [json.loads(line, object_pairs_hook=pairs)
               for line in (CAPTURE / 'metrics.ndjson').read_text().splitlines() if line.strip()]
    report = module.validate_events(canonical(rows), metrics)
    samples = [r for r in metrics if r.get('schema') == 'flyology.db.benchmark.paired_primary_sample.v1']
    require(len(samples) == 10 and {r['sample'] for r in samples} == set(range(1, 11)),
            'unexpected paired sample inventory')
    measured_keys = []
    for sample in samples:
        for role in ('reference', 'contender'):
            ordinal = sample[role + '_execution_ordinal']
            require(type(ordinal) in (int, float) and ordinal == int(ordinal), 'invalid measured ordinal')
            measured_keys.append((int(ordinal), sample[role]))
    require(len(set(measured_keys)) == 20, 'duplicate measured execution')
    executions = {(r['execution_ordinal'], r['participant']): r for r in report['executions']}
    require(set(measured_keys) < set(executions) and len(executions) == 22,
            'measured/warmup inventory mismatch')
    measured = [executions[key] for key in measured_keys]
    cpu = Counter()
    for execution in measured:
        cpu.update(execution['batch_symbol_sample_counts'])
    report['typed_native_records'] = len(rows)
    report['completeness_negative_controls'] = ['deletion', 'duplication', 'identity', 'lost']
    report['measured_batch_cpu_ranking'] = cpu.most_common(25)
    report['measured_marginal_medians_not_additive'] = {
        'window_ms': statistics.median((r['window']['end'] - r['window']['start']) / 1e6 for r in measured),
        'batch_wrapper_ms': statistics.median(sum(b['end'] - b['start'] for b in r['batch_spans']) / 1e6
                                            for r in measured),
        'syscall_counts': {},
        'syscall_elapsed_ms_includes_scheduling': {},
    }
    summary = report['measured_marginal_medians_not_additive']
    names = sorted({name for r in measured for name in r['batch_syscall_counts']})
    summary['syscall_counts'] = {name: statistics.median(r['batch_syscall_counts'].get(name, 0) for r in measured)
                                 for name in names}
    summary['syscall_elapsed_ms_includes_scheduling'] = {
        name: statistics.median(r['batch_syscall_elapsed_ns_includes_scheduling'].get(name, 0) / 1e6
                                for r in measured) for name in names}
    report['measured_by_participant'] = {}
    for participant in sorted({r['participant'] for r in measured}):
        selected = [r for r in measured if r['participant'] == participant]
        ranking = Counter()
        for execution in selected:
            ranking.update(execution['batch_symbol_sample_counts'])
        report['measured_by_participant'][participant] = {
            'executions': len(selected), 'batch_cpu_sample_count': sum(ranking.values()),
            'batch_symbol_ranking': ranking.most_common(25),
            'window_median_ms': statistics.median((r['window']['end'] - r['window']['start']) / 1e6
                                                for r in selected),
            'batch_wrapper_median_ms': statistics.median(sum(b['end'] - b['start'] for b in r['batch_spans'])
                                                        / 1e6 for r in selected),
            'batch_symbol_ranking_is_not_a_removable_wall_time_fraction': True,
        }
    output = ROOT / 'artifacts/x86_64/natural-provider-typed-export-v1/validated-attribution-v2.json'
    require(not output.exists(), 'attribution output already exists')
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print('TYPED_NATIVE_INVENTORY_AND_INTERVALS_OK', len(rows))
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(json.dumps(cpu.most_common(12), indent=2))


if __name__ == '__main__':
    main()

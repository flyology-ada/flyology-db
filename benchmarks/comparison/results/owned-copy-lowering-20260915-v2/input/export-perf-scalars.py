#!/usr/bin/env python3
"""Installed perf Python callbacks; never export application buffers or raw records."""
import json

GROUP = 'dbnatural20260915v3'
CPU = 'cpu-clock/period=250000/u'
SYSCALLS = ('write', 'pwrite64', 'fsync', 'fdatasync', 'rename', 'renameat', 'renameat2')
PROBES = ('window_start', 'window_end', 'batch_put_start', 'batch_put_end')
EVENTS = {GROUP + ':' + name for name in PROBES}
EVENTS.update('syscalls:sys_' + boundary + '_' + name
              for name in SYSCALLS for boundary in ('enter', 'exit'))


def integer(mapping, key, minimum=0, maximum=2**64 - 1):
    value = mapping[key]
    if type(value) is not int or not minimum <= value <= maximum:
        raise RuntimeError('invalid typed scalar: ' + key)
    return value


def base(data):
    sample = data['sample']
    return {'event': data['ev_name'], 'pid': integer(sample, 'pid', 1),
            'tid': integer(sample, 'tid', 1), 'time': integer(sample, 'time'),
            'period': integer(sample, 'period', 1)}


def emit(record):
    print(json.dumps(record, sort_keys=True, separators=(',', ':')))


def trace_unhandled(event_name, context, fields, data):
    record = base(data)
    event = record['event']
    if event not in EVENTS or event_name != event.replace(':', '__', 1):
        raise RuntimeError('unexpected typed tracepoint: ' + str(event))
    if integer(fields, 'common_pid', 1) != record['tid']:
        raise RuntimeError('typed tracepoint TID mismatch')
    if integer(fields, 'common_s') * 10**9 + integer(fields, 'common_ns', 0, 999999999) != record['time']:
        raise RuntimeError('typed tracepoint timestamp mismatch')
    arguments = {}
    if event.startswith('syscalls:sys_exit_'):
        arguments['ret'] = integer(fields, 'ret', -(2**63), 2**63 - 1)
    elif event.startswith('syscalls:sys_enter_'):
        name = event.removeprefix('syscalls:sys_enter_')
        if name in ('write', 'pwrite64', 'fsync', 'fdatasync'):
            arguments['fd'] = integer(fields, 'fd')
        if name in ('write', 'pwrite64'):
            arguments['count'] = integer(fields, 'count')
        if name == 'pwrite64':
            arguments['pos'] = integer(fields, 'pos', -(2**63), 2**63 - 1)
    record['arguments'] = arguments
    emit(record)


def process_event(data):
    record = base(data)
    if record['event'] != CPU or record['period'] != 250000:
        raise RuntimeError('unexpected typed CPU event')
    record['ip'] = integer(data['sample'], 'ip')
    for key in ('symbol', 'dso'):
        value = data.get(key, '[unknown]')
        if type(value) is not str or not value or any(c.isspace() for c in value):
            raise RuntimeError('invalid typed CPU ' + key)
        record[key] = value
    emit(record)

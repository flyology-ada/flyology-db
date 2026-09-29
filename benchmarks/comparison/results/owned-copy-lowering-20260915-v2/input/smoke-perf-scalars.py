#!/usr/bin/env python3
"""Literal callback smoke: typed whitelist, identities and failure behavior only."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('exporter', Path(__file__).with_name('export-perf-scalars.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
data = {'ev_name': 'syscalls:sys_enter_pwrite64',
        'sample': {'pid': 41, 'tid': 42, 'time': 1000000007, 'period': 1},
        'raw_buf': b'private\nforged event header'}
fields = {'common_pid': 42, 'common_s': 1, 'common_ns': 7,
          'fd': 3, 'count': 192, 'pos': 0, '__buf_val': b'private\nforged event header'}


def invoke(d, f):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.trace_unhandled(d['ev_name'].replace(':', '__', 1), None, f, d)
    rows = out.getvalue().splitlines()
    assert len(rows) == 1 and 'private' not in rows[0] and 'raw_buf' not in rows[0]
    return json.loads(rows[0])


assert invoke(data, fields)['arguments'] == {'fd': 3, 'count': 192, 'pos': 0}
for value in (-5, 0, 192):
    d, f = copy.deepcopy(data), copy.deepcopy(fields)
    d['ev_name'], f['ret'] = 'syscalls:sys_exit_pwrite64', value
    assert invoke(d, f)['arguments'] == {'ret': value}
for name, location, key, value in (
        ('tid', 'fields', 'common_pid', 43), ('time', 'fields', 'common_ns', 8),
        ('bool', 'fields', 'count', True), ('missing', 'fields', 'count', None),
        ('negative', 'fields', 'count', -1), ('event', 'data', 'ev_name', 'unexpected'),
        ('pid', 'sample', 'pid', 0)):
    d, f = copy.deepcopy(data), copy.deepcopy(fields)
    target = f if location == 'fields' else (d['sample'] if location == 'sample' else d)
    if value is None:
        del target[key]
    else:
        target[key] = value
    try:
        invoke(d, f)
    except (RuntimeError, KeyError):
        pass
    else:
        raise AssertionError('negative control accepted: ' + name)
cpu = {'ev_name': m.CPU, 'sample': {**data['sample'], 'period': 250000, 'ip': 123},
       'symbol': 'MD5Transform', 'dso': 'lib.so', 'raw_buf': b'private'}
out = io.StringIO()
with contextlib.redirect_stdout(out):
    m.process_event(cpu)
assert json.loads(out.getvalue())['symbol'] == 'MD5Transform' and 'private' not in out.getvalue()
print('TYPED_PERF_LITERAL_SMOKE_OK: payload exclusion, identities, numeric and failure controls')

#!/usr/bin/env python3
"""Literal campaign-contract checks; no executable benchmark is launched."""
import copy
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('screen', HERE / 'screen-copy.py')
screen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screen)

comparison = {'reference_iterations': 1, 'contender_iterations': 1}
metrics = [{'kind': 'custom', 'axis': 'primary_time'}]
for sample in range(1, 11):
    first, second = 2 * sample - 1, 2 * sample
    left, right = (first, second) if sample % 2 else (second, first)
    metrics.append({'schema': 'flyology.db.benchmark.paired_primary_sample.v1',
                    'sample': sample, 'reference_iterations': 1, 'contender_iterations': 1,
                    'transactions_per_operation': 35,
                    'reference_execution_ordinal': left, 'contender_execution_ordinal': right})
    for participant, ordinal in ((screen.SLATE, left), (screen.DB, right)):
        metrics.append({'schema': 'flyology.db.benchmark.state_verification.v1',
                        'participant': participant, 'execution_ordinal': ordinal,
                        'warmup_transactions': 8, 'transactions': 35,
                        'mutations_per_transaction': 256, 'verified_keys': 11008,
                        'state_sha256': screen.STATE, 'expected_state_sha256': screen.STATE})
    metrics.append({'kind': 'flyology_db_execution_configuration', 'participant': screen.DB,
                    'execution_ordinal': right, 'caller_pipeline_depth': 32,
                    'caller_preparation_width': 1, 'runtime_preparation_concurrency': 1,
                    'runtime_pipeline_depth': 1, 'transactions': 35,
                    'manifest_publications': 0, 'batch_publications': 14, 'head_publications': 14})

class LiteralLoader:
    def __init__(self, compare, rows):
        self.compare, self.rows = compare, rows

    def load_pair(self, *args):
        return self.compare, self.rows

def exercise(name, change):
    compare, rows = copy.deepcopy(comparison), copy.deepcopy(metrics)
    change(compare, rows)
    try:
        screen.validate(LiteralLoader(compare, rows), Path('unused'), Path('unused'))
    except (RuntimeError, KeyError):
        print('SCREEN_CONTRACT_REJECTED', name)
        return
    raise RuntimeError('accepted forbidden campaign: ' + name)

screen.validate(LiteralLoader(comparison, metrics), Path('unused'), Path('unused'))
print('SCREEN_CONTRACT_SUCCESS')
exercise('calibration', lambda c, r: c.update(reference_iterations=2))
exercise('sample-count', lambda c, r: r.pop(1))
exercise('sample-work', lambda c, r: r[1].update(transactions_per_operation=34))
exercise('sample-iterations', lambda c, r: r[1].update(contender_iterations=2))
exercise('warmup', lambda c, r: r[2].update(warmup_transactions=1))
exercise('mutations', lambda c, r: r[2].update(mutations_per_transaction=128))
exercise('key-count', lambda c, r: r[2].update(verified_keys=8960))
exercise('digest', lambda c, r: r[2].update(state_sha256='0' * 64))
exercise('expected-digest', lambda c, r: r[2].update(expected_state_sha256='0' * 64))
exercise('reopen-missing', lambda c, r: r.pop(2))
exercise('adjacency', lambda c, r: r[1].update(reference_execution_ordinal=1000))
exercise('depth', lambda c, r: r[4].update(caller_pipeline_depth=35))
exercise('prepare-width', lambda c, r: r[4].update(caller_preparation_width=2))
exercise('runtime-width', lambda c, r: r[4].update(runtime_preparation_concurrency=2))
exercise('runtime-depth', lambda c, r: r[4].update(runtime_pipeline_depth=2))
exercise('manifest-write', lambda c, r: r[4].update(manifest_publications=1))
exercise('batch-min', lambda c, r: r[4].update(batch_publications=4, head_publications=4))
exercise('batch-max', lambda c, r: r[4].update(batch_publications=36, head_publications=36))
exercise('head-count', lambda c, r: r[4].update(head_publications=15))
exercise('primary-ambiguity', lambda c, r: r.append({'kind': 'custom', 'axis': 'primary_time'}))
print('SCREEN_CONTRACT_SMOKE_OK')

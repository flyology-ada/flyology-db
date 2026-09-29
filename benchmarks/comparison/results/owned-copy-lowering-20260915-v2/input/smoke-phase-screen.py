#!/usr/bin/env python3
"""Disposable literal metadata through the actual retained loader; no benchmark."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile

HERE = Path(__file__).resolve().parent
def load(file, name):
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

p = load(HERE / 'phase-screen.py', 'phase')
repository = HERE.parents[4]
loader = load(repository / 'benchmarks/comparison/run_realistic_campaign.py', 'loader')
comparison = {'type': 'comparison', 'reference': p.DB, 'contender': p.DIAG, 'samples': 10,
              'reference_iterations': 1, 'contender_iterations': 1}
rows = [{'kind': 'custom', 'axis': 'primary_time', 'reference': p.DB, 'contender': p.DIAG,
         'available': True, 'status': 'collected', 'timing_source': 'engine_adapter_monotonic_clock',
         'reference_median': 37000000, 'contender_median': 37000000}]
for sample in range(1, 11):
    a, b = 2 * sample - 1, 2 * sample
    left, right = (a, b) if sample % 2 else (b, a)
    rows.append({'schema': 'flyology.db.benchmark.paired_primary_sample.v1', 'sample': sample,
                 'reference': p.DB, 'contender': p.DIAG, 'reference_iterations': 1,
                 'contender_iterations': 1, 'transactions_per_operation': 35,
                 'reference_execution_ordinal': left, 'contender_execution_ordinal': right,
                 'contender_primary_ns_per_operation': 37000000})
    for participant, ordinal in ((p.DB, left), (p.DIAG, right)):
        rows.append({'schema': 'flyology.db.benchmark.state_verification.v1',
                     'participant': participant, 'execution_ordinal': ordinal,
                     'warmup_transactions': 8, 'transactions': 35, 'mutations_per_transaction': 256,
                     'verified_keys': 11008, 'state_sha256': p.STATE, 'expected_state_sha256': p.STATE})
        rows.append({'schema': 'flyology.db.benchmark.execution_configuration.v1',
                     'kind': 'flyology_db_execution_configuration', 'participant': participant,
                     'execution_ordinal': ordinal, 'transactions': 35, 'batch_publications': 6,
                     'head_publications': 6, 'manifest_publications': 0, 'caller_pipeline_depth': 32,
                     'caller_preparation_width': 1, 'runtime_preparation_concurrency': 1,
                     'runtime_pipeline_depth': 1})
    diag = {'kind': 'flyology_db_commit_diagnostics',
            'schema': 'flyology.db.benchmark.commit_diagnostics.v1', 'execution_ordinal': right,
            'attribution': 'elapsed_per_cohort_nonadditive_with_unattributed_gap',
            'worker_span_semantics': 'provider_inclusive_per_cohort_nonadditive',
            'caller_span_semantics': 'overlaps_worker_completion_includes_driver',
            'transactions': 35, 'member_total': 35, 'cohort_total': 6, 'phase_cohort_total': 6,
            'batch_publications': 6, 'head_publications': 6, 'manifest_publications': 0,
            'encoded_bytes': 6 * 160 + 35 * 32 + 35 * 256 * (14 + 16 + 1024),
            'width_counts': {str(w): (1 if w in (1, 2) else 4 if w == 8 else 0) for w in range(1, 9)},
            'precompletion_ns': 8000000, 'pipeline_unattributed_ns': 1000000}
    diag.update({field: 1000000 for field in p.PHASES})
    diag.update({field: 8000000 for field in p.CALLER})
    diag['prepublication_ns'] = diag['caller_preparation_wait_ns'] = 0
    rows.append(diag)

with tempfile.TemporaryDirectory(prefix='phase-contract-', dir=HERE) as temporary:
    directory = Path(temporary)
    compare_file, metric_file = directory / 'comparison.json', directory / 'metrics.ndjson'
    def exercise(name, change=None):
        c, r = copy.deepcopy(comparison), copy.deepcopy(rows)
        if change:
            change(c, r)
        compare_file.write_text(json.dumps(c))
        metric_file.write_text('\n'.join(json.dumps(x) for x in r) + '\n')
        try:
            result = p.validate(loader, compare_file, metric_file)
        except (RuntimeError, KeyError):
            assert change, 'valid literal campaign failed'
            print('PHASE_CONTRACT_REJECTED', name)
            return
        assert not change, 'accepted forbidden campaign: ' + name
        assert len(result['diagnostic_samples']) == 10
        print('PHASE_CONTRACT_SUCCESS')
    def diagnostic(r):
        return next(x for x in r if x.get('kind') == 'flyology_db_commit_diagnostics')
    exercise('valid')
    exercise('calibration', lambda c, r: c.update(reference_iterations=2))
    exercise('missing-diagnostic', lambda c, r: r.remove(diagnostic(r)))
    exercise('duplicate-diagnostic', lambda c, r: r.append(copy.deepcopy(diagnostic(r))))
    exercise('wire-byte-ledger', lambda c, r: diagnostic(r).update(encoded_bytes=9440000))
    exercise('member-ledger', lambda c, r: diagnostic(r).update(member_total=34))
    exercise('phase-ledger', lambda c, r: diagnostic(r).update(phase_cohort_total=5))
    exercise('width-ledger', lambda c, r: diagnostic(r)['width_counts'].update({'8': 3}))
    exercise('malformed-phase', lambda c, r: diagnostic(r).update(build_ns='1000000'))
    exercise('negative-phase', lambda c, r: diagnostic(r).update(build_ns=-1))
    exercise('worker-sum', lambda c, r: diagnostic(r).update(build_ns=37000000))
    exercise('worker-window', lambda c, r: diagnostic(r).update(precompletion_ns=38000000))
    exercise('caller-window', lambda c, r: diagnostic(r).update(caller_preparation_ns=37000000))
    exercise('attribution', lambda c, r: diagnostic(r).update(attribution='additive'))
    exercise('wrong-path', lambda c, r: diagnostic(r).update(prepublication_ns=1))
    exercise('parallel-wait', lambda c, r: diagnostic(r).update(caller_preparation_wait_ns=1))
    exercise('wrong-digest', lambda c, r: r[2].update(state_sha256='0' * 64))
    exercise('duplicate-config', lambda c, r: r.append(copy.deepcopy(r[3])))
    exercise('duplicate-verification', lambda c, r: r.append(copy.deepcopy(r[2])))
print('PHASE_CONTRACT_SMOKE_OK_AND_DISPOSABLE_ROOT_REMOVED')

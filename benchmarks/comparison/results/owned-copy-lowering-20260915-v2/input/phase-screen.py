#!/usr/bin/env python3
"""Existing diagnostic mode perturbation/phase capture, not speedup qualification."""
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import time

HELPER = Path('/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-screen-copy.py')
DB = 'flyology-db-files-adaptive-cohort-members8-bytes2159008-wait-us1000-depth32-workers1-cohorts1'
DIAG = DB + '-diagnostics'
PHASES = ('prepublication_ns', 'build_ns', 'validation_ns', 'batch_put_ns',
          'head_encode_ns', 'head_put_ns', 'installation_ns')
CALLER = ('caller_preparation_ns', 'caller_preparation_wait_ns',
          'caller_admission_ns', 'caller_completion_drive_ns')
STATE = '090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb'

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def load(file, name):
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def validate(loader, comparison_file, metrics_file):
    comparison, metrics = loader.load_pair(comparison_file, metrics_file, DB, DIAG)
    require(comparison['reference_iterations'] == comparison['contender_iterations'] == 1,
            'calibrated workload changed')
    samples = [r for r in metrics if r.get('schema')
               == 'flyology.db.benchmark.paired_primary_sample.v1']
    require(len(samples) == 10 and {r['sample'] for r in samples} == set(range(1, 11)),
            'sample inventory mismatch')
    configs = {(r['participant'], r['execution_ordinal']): r for r in metrics
               if r.get('kind') == 'flyology_db_execution_configuration'}
    states = {(r['participant'], r['execution_ordinal']): r for r in metrics
              if r.get('schema') == 'flyology.db.benchmark.state_verification.v1'}
    diagnostics = {}
    for row in metrics:
        if row.get('kind') == 'flyology_db_commit_diagnostics':
            require(row['schema'] == 'flyology.db.benchmark.commit_diagnostics.v1',
                    'diagnostic schema mismatch')
            ordinal = row['execution_ordinal']
            require(type(ordinal) is int and ordinal not in diagnostics, 'duplicate diagnostic')
            diagnostics[ordinal] = row
    retained, plain_rows, first = [], [], 0
    for sample in samples:
        require(sample['reference_iterations'] == sample['contender_iterations'] == 1
                and sample['transactions_per_operation'] == 35, 'sample workload changed')
        left, right = sample['reference_execution_ordinal'], sample['contender_execution_ordinal']
        require(abs(left - right) == 1, 'paired ordinals not adjacent')
        first += int(left < right)
        for participant, ordinal in ((DB, left), (DIAG, right)):
            state, config = states[(participant, ordinal)], configs[(participant, ordinal)]
            require(state['warmup_transactions'] == 8 and state['transactions'] == 35
                    and state['mutations_per_transaction'] == 256 and state['verified_keys'] == 11008
                    and state['state_sha256'] == state['expected_state_sha256'] == STATE,
                    'exact reopen verification mismatch')
            require(config['caller_pipeline_depth'] == 32 and config['caller_preparation_width'] == 1
                    and config['runtime_preparation_concurrency'] == config['runtime_pipeline_depth'] == 1
                    and config['transactions'] == 35 and config['manifest_publications'] == 0
                    and type(config['batch_publications']) is int
                    and 5 <= config['batch_publications'] <= 35
                    and config['head_publications'] == config['batch_publications'], 'profile mismatch')
        require(left not in diagnostics, 'plain execution unexpectedly instrumented')
        row = diagnostics[right]
        require(row['attribution'] == 'elapsed_per_cohort_nonadditive_with_unattributed_gap'
                and row['worker_span_semantics'] == 'provider_inclusive_per_cohort_nonadditive'
                and row['caller_span_semantics'] == 'overlaps_worker_completion_includes_driver',
                'diagnostic attribution mismatch')
        window = sample['contender_primary_ns_per_operation']
        require(type(window) in (int, float) and math.isfinite(window) and window > 0,
                'malformed primary window')
        count = configs[(DIAG, right)]['batch_publications']
        fields = PHASES + CALLER + ('precompletion_ns', 'pipeline_unattributed_ns', 'encoded_bytes',
                                    'transactions', 'member_total', 'cohort_total', 'phase_cohort_total',
                                    'batch_publications', 'manifest_publications', 'head_publications')
        require(all(type(row[field]) is int and row[field] >= 0 for field in fields),
                'missing/malformed diagnostic number')
        require(row['transactions'] == row['member_total'] == 35
                and row['cohort_total'] == row['phase_cohort_total'] == count
                and row['batch_publications'] == row['head_publications'] == count
                and row['manifest_publications'] == 0, 'diagnostic publication mismatch')
        require(set(row['width_counts']) == set(map(str, range(1, 9))), 'width inventory mismatch')
        require(all(type(n) is int and n >= 0 for n in row['width_counts'].values()),
                'invalid width count')
        require(sum(row['width_counts'].values()) == count
                and sum(int(w) * n for w, n in row['width_counts'].items()) == 35,
                'width/member ledger mismatch')
        # Existing batch-v1: header/trailer 156+4, transaction prefix 32,
        # mutation prefix 14; all 35*256 mutations are Put(16-byte key, 1024-byte value).
        require(row['encoded_bytes'] == count * 160 + 35 * 32 + 35 * 256 * (14 + 16 + 1024),
                'encoded byte ledger mismatch')
        worker_sum, caller_sum = sum(row[p] for p in PHASES), sum(row[p] for p in CALLER)
        require(worker_sum <= row['precompletion_ns'] + 16 * count
                and row['precompletion_ns'] <= window + 16 * count
                and caller_sum <= window + 2 * (4 * 35 + 1), 'diagnostic spans exceed their window')
        require(row['prepublication_ns'] == 0 and row['caller_preparation_wait_ns'] == 0,
                'unexpected non-pipeline or parallel preparation phase')
        retained.append({'sample': sample['sample'], 'window_ns': window, 'diagnostic': row,
                         'summed_worker_phases_ns': worker_sum, 'exclusive_caller_spans_ns': caller_sum})
        plain_rows.append(configs[(DB, left)])
    require(first == 5, 'unbalanced paired order')
    primary = [r for r in metrics if r.get('kind') == 'custom' and r.get('axis') == 'primary_time']
    require(len(primary) == 1, 'ambiguous primary metric')
    return {'classification': 'instrumented_phase_attribution_not_speedup_or_wall_additivity',
            'primary': primary[0], 'plain_configuration_rows': plain_rows,
            'diagnostic_samples': retained, 'inner_pairs': samples}

def main():
    require(os.geteuid() == 0, 'root-owned experiment required')
    require(not os.environ.get('LD_PRELOAD') and not os.environ.get('LD_AUDIT'), 'loader injection')
    require(hashlib.sha256(HELPER.read_bytes()).hexdigest()
            == '753885bc4e9ff5c4c0af267e09713bb2872d6b9e0640168d45cbea0646f52147', 'helper drift')
    m = load(HELPER, 'reviewed_screen')
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, m.request_stop)
    with open('/run/lock/flyology-db-aws-campaign.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        subprocess.check_call(['flock', '-n', '/run/lock/flyology-bench-host-cpu.lock', 'true'])
        tree, benchmark = m.CAND, m.CAND / 'benchmarks/comparison'
        output = tree.parent / 'natural-phase-screen'
        require(not output.exists() and not output.is_symlink(), 'output already exists')
        before = m.snapshot(tree)
        require(before == json.loads((m.OUT / 'source-before.json').read_text())[str(tree)],
                'candidate no longer matches completed copy screen')
        require(m.sha(benchmark / 'bin/flyology_db_benchmark_panel') == m.PANEL_HASHES[tree], 'panel drift')
        loader = load(benchmark / 'run_realistic_campaign.py', 'retained_loader')
        output.mkdir()
        m.write(output / 'source-before.json', before)
        m.audit()
        scratch = output / 'scratch'
        scratch.mkdir()
        detector = tree / '.agents/skills/performance-testing/scripts/check-power-profile.sh'
        require(m.sha(detector) == 'f0a0b961b3c4d849bce37dbeb0857450fdd974a8d2e546c59c09f157bc467a16',
                'power detector drift')
        power = subprocess.run(['sh', str(detector)], capture_output=True, text=True)
        (output / 'power.env').write_text(power.stdout)
        require(power.returncode in (0, 2) and not power.stderr, 'reduced/failed power detector')
        m.write(output / 'power-status.json', {'exit_status': power.returncode})
        env = {k: v for k, v in os.environ.items() if not k.startswith('FLYOLOGY_DB_')}
        env.update(FLYOLOGY_DB_BENCH_WARMUP='8', FLYOLOGY_DB_BENCH_SCRATCH_ROOT=str(scratch),
                   TMPDIR=str(scratch), FLYOLOGY_BENCH_LOCK_PATH='/run/lock/flyology-bench-host-cpu.lock',
                   LD_LIBRARY_PATH=':'.join(map(str, [benchmark / 'slatedb/target/release',
                       tree / 'oracles/adapters/tidesdb/build',
                       tree / 'oracles/adapters/tidesdb/build/upstream'])))
        argv = [str(benchmark / 'bin/flyology_db_benchmark_panel'), DB, DIAG, '16', '1024', '256', '35',
                str(output / 'comparison.json'), str(output / 'metrics.ndjson')]
        try:
            with (output / 'panel.log').open('x') as log:
                require(m.stop_signal is None, 'interrupted before launch')
                process = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                try:
                    m.write(output / 'active-panel.json', {'pid': process.pid, 'argv': argv,
                                                           'started_unix': time.time()})
                    print('NATURAL_PHASE_PANEL_ACTIVE', process.pid, flush=True)
                    status = m.wait_owned(process)
                finally:
                    m.join_owned_group(process)
            m.write(output / 'status.json', {'exit_status': status})
            require(status == 0, 'diagnostic panel failed')
            require(not list(scratch.iterdir()) and (output / 'panel.log').read_bytes() == b'',
                    'unexpected log/scratch residue')
            result = validate(loader, output / 'comparison.json', output / 'metrics.ndjson')
            require(m.snapshot(tree) == before, 'candidate input drift')
            m.audit()
            m.write(output / 'validated.json', result)
        except BaseException as error:
            m.write(output / 'failure.json', {'error': repr(error)})
            raise
        finally:
            after = m.snapshot(tree)
            m.write(output / 'source-after.json', after)
            require(after == before, 'final candidate input drift')
        require(m.stop_signal is None, 'collector interrupted')
        print('DB_NATURAL_COPY_PHASE_SCREEN_TERMINAL', flush=True)

if __name__ == '__main__':
    main()

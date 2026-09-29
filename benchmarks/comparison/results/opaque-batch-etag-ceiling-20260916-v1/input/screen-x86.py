#!/usr/bin/env python3
"""Exploratory paired Files screen; do not infer power-qualified or cross-arch speed."""

import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path('/mnt/flyology-bench/experiments/opaque-batch-etag-ceiling-20260916-v1-x86_64')
BASE = ROOT / 'baseline'
CAND = ROOT / 'candidate'
OUT = ROOT / 'screen'
SLATE = 'slatedb-1ms-depth32'
DB = 'flyology-db-files-adaptive-cohort-members8-bytes2159008-wait-us1000-depth32-workers1-cohorts1'
STATE = '090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb'
SOURCES = {
    BASE: ('1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac',
           'dae8fd3566ccec9516c109712707f40c2562cd74fafa5ff1a5c9d11994879af4'),
    CAND: ('2fdbe17943c10d74b86baa2b0669090de0525728d7cc0a6d0019ba868d1a0f97',
           '1877168fcf63a47abf4e530ea49ad14754287f862d9faa100bb54f5cfcc35115'),
}
FILES_BODY = Path('benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src/'
                  'flyology-object_storage-backends-files.adb')
stopping = None


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def source_closure(tree):
    roots = ['src', 'config', 'benchmarks/comparison/src',
             'benchmarks/comparison/.deps/flyology_db-fca74780/src',
             'benchmarks/comparison/.deps/flyology_object_storage_0.1.0_5eaf79cf/src']
    files = [path for root in roots for path in (tree / root).rglob('*')
             if path.is_file() and path.suffix in {'.adb', '.ads', '.gpr', '.c', '.h'}]
    files += [tree / name for name in ('flyology_db.gpr', 'alire.toml',
                                       'benchmarks/comparison/flyology_db_benchmark.gpr',
                                       'benchmarks/comparison/alire.toml')]
    for root in (tree / '.deps', tree / 'benchmarks/comparison/.deps'):
        for dependency in root.iterdir():
            if dependency.is_dir():
                files.extend(dependency.glob('*.gpr'))
                files.extend((dependency / 'config').glob('*.gpr'))
    require(all(path.is_file() for path in files), 'source or project input missing')
    require(not any(path.is_symlink() for path in files), 'source closure contains symlink')
    return {str(path.relative_to(tree)): digest(path) for path in sorted(files)}


def native_libraries(tree):
    bench = tree / 'benchmarks/comparison'
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = ':'.join(map(str, [bench / 'slatedb/target/release',
        tree / 'oracles/adapters/tidesdb/build',
        tree / 'oracles/adapters/tidesdb/build/upstream']))
    output = subprocess.check_output(['ldd', str(bench / 'bin/flyology_db_benchmark_panel')],
                                     env=env, text=True)
    actual = {}
    for line in output.splitlines():
        words = line.split()
        if len(words) >= 3 and words[1] == '=>':
            require(words[0] not in actual, 'duplicate dynamic library')
            actual[words[0]] = Path(words[2]).resolve(strict=True)
    expected = {
        'libflyology_db_slatedb_benchmark.so':
            bench / 'slatedb/target/release/libflyology_db_slatedb_benchmark.so',
        'libflyology_tidesdb_oracle.so':
            tree / 'oracles/adapters/tidesdb/build/libflyology_tidesdb_oracle.so',
        'libtidesdb.so.9': tree / 'oracles/adapters/tidesdb/build/upstream/libtidesdb.so.9',
    }
    for name, path in expected.items():
        require(actual.get(name) == path.resolve(strict=True), 'native library substitution: ' + name)
    return {name: digest(path) for name, path in expected.items()}


def snapshot(tree):
    bench = tree / 'benchmarks/comparison'
    body_sha, files_sha = SOURCES[tree]
    require(digest(tree / 'src/flyology-db.adb') == body_sha, 'DB body drift')
    require(digest(tree / FILES_BODY) == files_sha, 'Files body drift')
    require(digest(tree / 'alire/alire.lock') ==
            '5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3',
            'root lock drift')
    require(digest(bench / 'alire/alire.lock') ==
            '440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc',
            'benchmark lock drift')
    receipt = ROOT / ('explicit-baseline-build' if tree == BASE else 'explicit-root-build')
    require(json.loads((receipt / 'status.json').read_text()) == {'exit_status': 0},
            'explicit-source build did not pass')
    resolved = (receipt / 'resolved-sources.txt').read_text().splitlines()
    require(resolved.count(str(tree / 'src/flyology-db.adb')) == 1,
            'explicit DB source not unique')
    require(resolved.count(str(tree / FILES_BODY)) == 1, 'Files source not unique')
    panel = bench / 'bin/flyology_db_benchmark_panel'
    require((receipt / 'panel.sha256').read_text().split()[0] == digest(panel),
            'panel binary drift')
    files = [tree / 'src/flyology-db.adb', tree / FILES_BODY, panel,
             tree / 'alire/alire.lock', bench / 'alire/alire.lock',
             bench / 'run_realistic_campaign.py', bench / 'src/flyology_db_benchmark_panel.adb',
             bench / 'src/flyology_db_benchmark_flyology.adb',
             bench / 'slatedb/target/release/libflyology_db_slatedb_benchmark.so']
    return {'files': {str(path.relative_to(tree)): digest(path) for path in files},
            'sources': source_closure(tree), 'native_libraries': native_libraries(tree),
            'git_diff_sha256': hashlib.sha256(subprocess.check_output(
                ['git', '-C', str(tree), 'diff', '--binary', 'HEAD', '--'])).hexdigest()}


def audit():
    names = {'perf', 'java', 'alr', 'gprbuild', 'gprbind', 'gnat1', 'gnatbind',
             'gnatlink', 'gcc', 'cc1', 'cargo', 'rustc', 'tlapm', 'gnatprove',
             'flyology_db_benchmark', 'flyology_db_benchmark_panel', 'flyology-db-tests'}
    for line in command('/bin/ps', '-eo', 'pid=,args=').splitlines():
        words = line.split()
        if len(words) > 1:
            require(Path(words[1]).name not in names, 'occupied benchmark lane: ' + line)


def signal_stop(number, frame):
    global stopping
    stopping = number


def group_alive(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def join_group(process):
    require(process.pid > 1 and process.pid != os.getpgrp(), 'invalid owned process group')
    if group_alive(process.pid):
        os.killpg(process.pid, signal.SIGTERM)
        until = time.monotonic() + 10
        while group_alive(process.pid) and time.monotonic() < until:
            time.sleep(0.1)
        if group_alive(process.pid):
            os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    until = time.monotonic() + 10
    while group_alive(process.pid) and time.monotonic() < until:
        time.sleep(0.1)
    require(not group_alive(process.pid), 'panel process residue')


def validate(loader, comparison_file, metrics_file):
    comparison, metrics = loader.load_pair(comparison_file, metrics_file, SLATE, DB)
    require(comparison['reference_iterations'] == comparison['contender_iterations'] == 1,
            'calibrated work changed')
    samples = [m for m in metrics if m.get('schema') ==
               'flyology.db.benchmark.paired_primary_sample.v1']
    require(len(samples) == 10 and {m['sample'] for m in samples} == set(range(1, 11)),
            'paired sample geometry changed')
    configs = {(m['participant'], m['execution_ordinal']): m for m in metrics
               if m.get('kind') == 'flyology_db_execution_configuration'}
    verifications = {(m['participant'], m['execution_ordinal']): m for m in metrics
                     if m.get('schema') == 'flyology.db.benchmark.state_verification.v1'}
    counts, reference_first = [], 0
    for sample in samples:
        left, right = sample['reference_execution_ordinal'], sample['contender_execution_ordinal']
        require(abs(left - right) == 1 and sample['transactions_per_operation'] == 35,
                'unpaired or unequal transaction window')
        reference_first += int(left < right)
        for participant, ordinal in ((SLATE, left), (DB, right)):
            row = verifications[(participant, ordinal)]
            require(row['warmup_transactions'] == 8 and row['transactions'] == 35
                    and row['mutations_per_transaction'] == 256 and row['verified_keys'] == 11008
                    and row['state_sha256'] == row['expected_state_sha256'] == STATE,
                    'reopen state mismatch')
        row = configs[(DB, right)]
        require(row['caller_pipeline_depth'] == 32 and row['caller_preparation_width'] == 1
                and row['runtime_preparation_concurrency'] == row['runtime_pipeline_depth'] == 1
                and row['transactions'] == 35 and row['manifest_publications'] == 0
                and isinstance(row['batch_publications'], int)
                and 5 <= row['batch_publications'] <= 35
                and row['head_publications'] == row['batch_publications'],
                'publication geometry mismatch')
        counts.append({'batch': row['batch_publications'], 'head': row['head_publications']})
    require(reference_first == 5, 'internal paired order unbalanced')
    primary = [m for m in metrics if m.get('kind') == 'custom' and m.get('axis') == 'primary_time']
    require(len(primary) == 1, 'primary metric missing or ambiguous')
    return {'primary': primary[0], 'publications': counts}


def main():
    require(os.getuid() == 0, 'root-owned experiment required')
    require(not OUT.exists() and not OUT.is_symlink(), 'screen output already exists')
    require(not os.environ.get('LD_PRELOAD') and not os.environ.get('LD_AUDIT'),
            'loader injection')
    campaign_lock = open('/run/lock/flyology-db-aws-campaign.lock', 'a')
    fcntl.flock(campaign_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, signal_stop)
    before = {str(tree): snapshot(tree) for tree in (BASE, CAND)}
    shared = ['src/flyology_db_benchmark_panel.adb',
              'src/flyology_db_benchmark_flyology.adb', 'run_realistic_campaign.py',
              'slatedb/src/lib.rs', 'slatedb/Cargo.lock', 'flyology_db_benchmark.gpr']
    for path in shared:
        require(digest(BASE / 'benchmarks/comparison' / path) ==
                digest(CAND / 'benchmarks/comparison' / path), 'shared input drift: ' + path)
    expected_sources = dict(before[str(BASE)]['sources'])
    actual_sources = dict(before[str(CAND)]['sources'])
    for path in ('src/flyology-db.adb', str(FILES_BODY)):
        require(expected_sources.pop(path) != actual_sources.pop(path),
                'experiment source unchanged: ' + path)
    require(expected_sources == actual_sources, 'other source closure differs')
    require(before[str(BASE)]['native_libraries'] == before[str(CAND)]['native_libraries'],
            'native libraries differ')
    require(before[str(BASE)]['files']['benchmarks/comparison/run_realistic_campaign.py'] ==
            before[str(CAND)]['files']['benchmarks/comparison/run_realistic_campaign.py'],
            'loader differs')
    loader_file = CAND / 'benchmarks/comparison/run_realistic_campaign.py'
    spec = importlib.util.spec_from_file_location('retained_loader', loader_file)
    loader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loader)
    OUT.mkdir()
    write_json(OUT / 'source-before.json', before)
    retained, power_before = [], None
    try:
        for name, tree in [('B1', BASE), ('C1', CAND), ('C2', CAND), ('B2', BASE)]:
            require(stopping is None, 'collector interrupted')
            audit()
            subprocess.run(['flock', '-n', '/run/lock/flyology-bench-host-cpu.lock', 'true'],
                           check=True)
            require(snapshot(tree) == before[str(tree)], 'source drift before panel')
            bench = tree / 'benchmarks/comparison'
            detector = tree / '.agents/skills/performance-testing/scripts/check-power-profile.sh'
            power = subprocess.run(['sh', str(detector)], capture_output=True, text=True)
            require(power.returncode in (0, 2) and not power.stderr,
                    'reduced or failed power profile')
            require(power_before in (None, power.stdout), 'detectable power profile changed')
            power_before = power.stdout
            (OUT / (name + '-power.env')).write_text(power.stdout, encoding='utf-8')
            scratch = OUT / (name + '-scratch')
            scratch.mkdir()
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith('FLYOLOGY_DB_')}
            env.update(FLYOLOGY_DB_BENCH_WARMUP='8', FLYOLOGY_DB_BENCH_SCRATCH_ROOT=str(scratch),
                       TMPDIR=str(scratch),
                       FLYOLOGY_BENCH_LOCK_PATH='/run/lock/flyology-bench-host-cpu.lock',
                       LD_LIBRARY_PATH=':'.join(map(str, [bench / 'slatedb/target/release',
                           tree / 'oracles/adapters/tidesdb/build',
                           tree / 'oracles/adapters/tidesdb/build/upstream'])))
            argv = [str(bench / 'bin/flyology_db_benchmark_panel'), SLATE, DB,
                    '16', '1024', '256', '35', str(OUT / (name + '.json')),
                    str(OUT / (name + '.ndjson'))]
            with (OUT / (name + '.log')).open('w') as log:
                process = subprocess.Popen(argv, env=env, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    write_json(OUT / 'active-panel.json', {'name': name, 'pid': process.pid,
                                                           'argv': argv, 'start': time.time()})
                    print('OPAQUE_TAG_SCREEN_ACTIVE', name, process.pid, flush=True)
                    until = time.monotonic() + 900
                    while process.poll() is None:
                        require(stopping is None and time.monotonic() < until,
                                'panel hang or collector interruption')
                        time.sleep(1)
                    status = process.returncode
                    left_child = group_alive(process.pid)
                finally:
                    join_group(process)
            write_json(OUT / (name + '-status.json'), {'exit_status': status})
            require(status == 0, 'panel failed: ' + name)
            require(not left_child, 'successful panel left a child: ' + name)
            require(not (OUT / (name + '.log')).read_bytes(), 'panel diagnostic: ' + name)
            require(not list(scratch.iterdir()), 'panel scratch residue: ' + name)
            result = validate(loader, OUT / (name + '.json'), OUT / (name + '.ndjson'))
            require(snapshot(tree) == before[str(tree)], 'source drift after panel')
            audit()
            retained.append({'name': name, 'power_status': power.returncode,
                             'power': power.stdout, **result})
            write_json(OUT / (name + '-validated.json'), retained[-1])
            print('OPAQUE_TAG_SCREEN_VALID', name, flush=True)
        require({str(tree): snapshot(tree) for tree in (BASE, CAND)} == before,
                'full source drift')
        write_json(OUT / 'screen.json', {'classification': 'exploratory_unknown_power_two_outer_blocks',
                                        'panels': retained})
        print('OPAQUE_BATCH_ETAG_SCREEN_TERMINAL', flush=True)
    except BaseException as error:
        write_json(OUT / 'failure.json', {'error': repr(error)})
        raise
    finally:
        write_json(OUT / 'source-after.json',
                   {str(tree): snapshot(tree) for tree in (BASE, CAND)})


if __name__ == '__main__':
    main()

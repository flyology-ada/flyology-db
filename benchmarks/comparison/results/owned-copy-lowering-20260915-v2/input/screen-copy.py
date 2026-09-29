#!/usr/bin/env python3
"""Four-panel exploratory screen; inner S/A intervals are not B/C intervals."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

BASE = Path('/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v1-x86_64/baseline')
CAND = Path('/mnt/flyology-bench/experiments/owned-copy-lowering-20260915-v2-x86_64/candidate')
OUT = CAND.parent / 'copy-screen'
SLATE = 'slatedb-1ms-depth32'
DB = 'flyology-db-files-adaptive-cohort-members8-bytes2159008-wait-us1000-depth32-workers1-cohorts1'
STATE = '090e348abcc1353f6cb651a378cbafc890ee7a9c50fd707c9ab9667ee12ccbbb'
PANEL_HASHES = {
    BASE: '2419663a3e5c447c7dc2afc7074d437b74ea7b65ec99c7aa3f51d02e0f3a6190',
    CAND: '4226f2149562ef803caedf8107f1332da83b1bdd9295ddd937d411e78aabf70a',
}
BODY_HASHES = {
    BASE: '46d430be91f2ab987836600490399db784b8330840672b84c9d04bf7d48e97cb',
    CAND: '1874bc5adda2ae7dd8227f36b361fa3d9cba7ca8fc7d2e433d622a0d01f036ac',
}
stop_signal = None

def request_stop(number, frame):
    global stop_signal
    stop_signal = number

def group_alive(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False

def join_owned_group(process):
    group = process.pid  # start_new_session makes this exact owned PID its PGID.
    require(group > 1 and group != os.getpgrp(), 'invalid owned process group')
    if group_alive(group):
        os.killpg(group, signal.SIGTERM)
        limit = time.monotonic() + 10
        while group_alive(group) and time.monotonic() < limit:
            process.poll()
            time.sleep(0.1)
        if group_alive(group):
            os.killpg(group, signal.SIGKILL)
    process.wait()
    limit = time.monotonic() + 10
    while group_alive(group) and time.monotonic() < limit:
        time.sleep(0.1)
    require(not group_alive(group), 'owned process-group residue')

def wait_owned(process):
    # Diagnostic hang guard, not a benchmark or database deadline. The maintained
    # panel caps sampling at 180 seconds; allow 900 for admission/calibration too.
    limit = time.monotonic() + 900
    while process.poll() is None:
        require(stop_signal is None, 'collector received signal: ' + str(stop_signal))
        require(time.monotonic() < limit, 'owned panel exceeded diagnostic hang guard')
        time.sleep(1)
    require(not group_alive(process.pid), 'panel left an owned child process')
    return process.returncode

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def sha(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

def write(file, data):
    file.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')

def capture(argv):
    return subprocess.check_output(argv, text=True).strip()

def native_libraries(tree):
    benchmark = tree / 'benchmarks/comparison'
    environment = dict(os.environ)
    environment['LD_LIBRARY_PATH'] = ':'.join(map(str, [benchmark / 'slatedb/target/release',
        tree / 'oracles/adapters/tidesdb/build', tree / 'oracles/adapters/tidesdb/build/upstream']))
    output = subprocess.check_output(['ldd', str(benchmark / 'bin/flyology_db_benchmark_panel')],
                                     env=environment, text=True)
    libraries = {}
    for line in output.splitlines():
        words = line.split()
        if len(words) >= 3 and words[1] == '=>':
            file = Path(words[2]).resolve(strict=True)
            require(words[0] not in libraries, 'duplicate native library resolution')
            libraries[words[0]] = {'file': str(file), 'sha256': sha(file)}
        elif words and words[0].startswith('/'):
            file = Path(words[0]).resolve(strict=True)
            libraries['dynamic_loader'] = {'file': str(file), 'sha256': sha(file)}
    for name, file in [
        ('libflyology_db_slatedb_benchmark.so',
         benchmark / 'slatedb/target/release/libflyology_db_slatedb_benchmark.so'),
        ('libflyology_tidesdb_oracle.so',
         tree / 'oracles/adapters/tidesdb/build/libflyology_tidesdb_oracle.so'),
        ('libtidesdb.so.9', tree / 'oracles/adapters/tidesdb/build/upstream/libtidesdb.so.9')]:
        require(libraries[name]['file'] == str(file.resolve(strict=True)), 'native library substitution')
    return libraries

def audit():
    programs = {
        'perf', 'java', 'alr', 'gprbuild', 'gprbind', 'gnat1', 'gnatbind', 'gnatlink',
        'gcc', 'cc1', 'clang', 'cargo', 'rustc', 'tlapm', 'gnatprove', 'gnatdoc',
        'flyology_db_benchmark', 'flyology_db_benchmark_panel', 'flyology-db-tests',
    }
    scripts = {'test.sh', 'test-s3-matrix.sh', 'check-tla.sh', 'prove.sh', 'build-api-docs.sh'}
    for line in capture(['/bin/ps', '-eo', 'pid=,args=']).splitlines():
        words = line.split()
        if len(words) < 2:
            continue
        executable = Path(words[1]).name
        resource = executable in programs
        maintained = executable in {'sh', 'bash', 'dash'} and len(words) > 2
        maintained = maintained and Path(words[2]).name in scripts
        require(not resource and not maintained, 'occupied executable lane: ' + line)

def snapshot(tree):
    benchmark = tree / 'benchmarks/comparison'
    require({f.name for f in (tree / 'config').iterdir()}
            == {'flyology_db_config.ads', 'flyology_db_config.gpr', 'flyology_db_config.h'},
            'configuration inventory drift')
    require(sha(tree / 'alire/alire.lock')
            == '5a2254eb8ba78324629142bc240b6e3e7b54017b54cbf26448139c6cf97b05e3', 'root lock drift')
    require(sha(benchmark / 'alire/alire.lock')
            == '440618a86c6b6bd440152ac1938e532c608450d3693722e511ad5bde30b35bbc', 'bench lock drift')
    dependencies = {}
    for name, head, tree_hash, origin in [
        ('flyology-object-storage', 'f65afbf28108bb9d81fac6dc15496857dc710796',
         '5b68b2b4d7fd11ecfd85b8256823776577ce1612',
         'https://github.com/flyology-ada/flyology-object-storage.git'),
        ('slatedb', 'e0161973d8d7ffdede7c44725729838811674e99',
         '317d112e1706b04f07fb229e27658fb0ee46c038', 'https://github.com/slatedb/slatedb.git'),
        ('tidesdb', '23a67a6531bc6c0b537d3696758c7879586dcfce',
         '8988e80b36a9ef7277e3396f88e46fd315fe9bab', 'https://github.com/tidesdb/tidesdb.git')]:
        directory = tree / '.deps' / name
        require(capture(['git', '-C', str(directory), 'status', '--porcelain']) == '',
                'dirty retained dependency: ' + name)
        actual = capture(['git', '-C', str(directory), 'rev-parse', 'HEAD'])
        require(actual == head, 'retained dependency revision drift: ' + name)
        dependencies[name] = {'head': actual,
            'tree': capture(['git', '-C', str(directory), 'rev-parse', 'HEAD^{tree}']),
            'origin': capture(['git', '-C', str(directory), 'remote', 'get-url', 'origin'])}
        require(dependencies[name]['tree'] == tree_hash and dependencies[name]['origin'] == origin,
                'retained dependency tree/origin drift: ' + name)
    digest_script = benchmark / 'aws/source-tree-digest.py'
    require(sha(digest_script)
            == '248fd6471595e291946d82e5b78ffb057e1c8326c4a7036917a850cc02c38ab8', 'digest tool drift')
    indexed = benchmark / '.deps/flyology_object_storage_0.1.0_5eaf79cf'
    indexed_digest = capture(['python3', str(digest_script), str(indexed)])
    require(indexed_digest == '97e048bb7fa42eee3aeca832548859c8b39e64a1a8c7a2326c435398a866a172',
            'indexed Object Storage source drift')
    files = list((tree / 'src').glob('*')) + list((benchmark / 'src').glob('*'))
    files += list((tree / 'config').glob('*'))
    files += [tree / 'alire/alire.lock', benchmark / 'alire/alire.lock', tree / 'alire.toml',
              tree / 'flyology_db.gpr', benchmark / 'flyology_db_benchmark.gpr',
              benchmark / 'run_realistic_campaign.py', benchmark / 'slatedb/src/lib.rs',
              benchmark / 'slatedb/Cargo.lock',
              benchmark / 'slatedb/target/release/libflyology_db_slatedb_benchmark.so',
              benchmark / 'bin/flyology_db_benchmark_panel']
    return {
        'dependencies': dependencies, 'indexed_object_storage_source': indexed_digest,
        'native_libraries': native_libraries(tree),
        'files': {str(f.relative_to(tree)): sha(f) for f in files if f.is_file()},
        'head': capture(['git', '-C', str(tree), 'rev-parse', 'HEAD']),
        'diff': hashlib.sha256(subprocess.check_output(
            ['git', '-C', str(tree), 'diff', '--binary', 'HEAD', '--'])).hexdigest(),
    }

def validate(loader, comparison_file, metrics_file):
    comparison, metrics = loader.load_pair(comparison_file, metrics_file, SLATE, DB)
    require(comparison.get('reference_iterations') == 1
            and comparison.get('contender_iterations') == 1, 'calibrated workload changed')
    samples = [m for m in metrics if m.get('schema')
               == 'flyology.db.benchmark.paired_primary_sample.v1']
    require({m.get('sample') for m in samples} == set(range(1, 11)), 'sample index mismatch')
    configurations = {(m['participant'], m['execution_ordinal']): m for m in metrics
                      if m.get('kind') == 'flyology_db_execution_configuration'}
    verifications = {(m['participant'], m['execution_ordinal']): m for m in metrics
                     if m.get('schema') == 'flyology.db.benchmark.state_verification.v1'}
    counts = []
    reference_first = 0
    for sample in samples:
        require(sample['reference_iterations'] == sample['contender_iterations'] == 1
                and sample['transactions_per_operation'] == 35, 'sample workload changed')
        left, right = (sample['reference_execution_ordinal'], sample['contender_execution_ordinal'])
        require(abs(left - right) == 1, 'paired ordinals not adjacent')
        reference_first += int(left < right)
        for participant, ordinal in ((SLATE, left), (DB, right)):
            row = verifications[(participant, ordinal)]
            require(row['warmup_transactions'] == 8 and row['transactions'] == 35
                    and row['mutations_per_transaction'] == 256
                    and row['verified_keys'] == 11008
                    and row['state_sha256'] == row['expected_state_sha256'] == STATE,
                    'exact-state verification mismatch')
        row = configurations[(DB, right)]
        require(row['caller_pipeline_depth'] == 32 and row['caller_preparation_width'] == 1
                and row['runtime_preparation_concurrency'] == row['runtime_pipeline_depth'] == 1
                and row['transactions'] == 35 and row['manifest_publications'] == 0
                and type(row['batch_publications']) is int
                and 5 <= row['batch_publications'] <= 35
                and row['head_publications'] == row['batch_publications'], 'publication mismatch')
        counts.append(row)
    require(reference_first == 5, 'unbalanced paired order')
    primary = [m for m in metrics if m.get('kind') == 'custom' and m.get('axis') == 'primary_time']
    require(len(primary) == 1, 'primary metric ambiguous')
    return {'primary': primary[0], 'publication_rows': counts, 'inner_pairs': samples}

def main():
    require(os.getuid() == 0, 'root-owned experiment required')
    require(not os.environ.get('LD_PRELOAD') and not os.environ.get('LD_AUDIT'), 'loader injection')
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, request_stop)
    require(not OUT.exists() and not OUT.is_symlink(), 'screen output already exists')
    require(json.loads((CAND.parent / 'engine-capacity-repaired/status.json').read_text())
            == {'exit_status': 0}, 'correctness gate not green')
    before = {}
    for tree in (BASE, CAND):
        benchmark = tree / 'benchmarks/comparison'
        require(sha(benchmark / 'bin/flyology_db_benchmark_panel') == PANEL_HASHES[tree], 'panel drift')
        require(sha(tree / 'src/flyology-db.adb') == BODY_HASHES[tree], 'runtime drift')
        require(sha(benchmark / 'slatedb/target/release/libflyology_db_slatedb_benchmark.so')
                == 'd61eb0795be17619809eba50b3cccd4af2dad5c9c520d0dc931c67b94d3749bf', 'Slate drift')
        before[str(tree)] = snapshot(tree)
    common = ['src/flyology_db_benchmark_panel.adb', 'src/flyology_db_benchmark_flyology.adb',
              'run_realistic_campaign.py', 'slatedb/src/lib.rs', 'slatedb/Cargo.lock',
              'flyology_db_benchmark.gpr']
    for name in common:
        require(sha(BASE / 'benchmarks/comparison' / name)
                == sha(CAND / 'benchmarks/comparison' / name), 'common input mismatch: ' + name)
    loader_file = CAND / 'benchmarks/comparison/run_realistic_campaign.py'
    require(sha(loader_file)
            == '8ea5867e82f69b7198f514e3fa2f7ea357cff2f0ee31d996a5b5760ce8250a01', 'loader drift')
    spec = importlib.util.spec_from_file_location('retained_loader', loader_file)
    loader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loader)
    OUT.mkdir()
    write(OUT / 'source-before.json', before)
    retained, power_reference = [], None
    try:
        for name, tree in [('B1', BASE), ('C1', CAND), ('C2', CAND), ('B2', BASE)]:
            require(stop_signal is None, 'collector received signal: ' + str(stop_signal))
            audit()
            require(snapshot(tree) == before[str(tree)], 'input drift before panel')
            scratch = OUT / (name + '-scratch')
            scratch.mkdir()
            benchmark = tree / 'benchmarks/comparison'
            detector = tree / '.agents/skills/performance-testing/scripts/check-power-profile.sh'
            require(sha(detector)
                    == 'f0a0b961b3c4d849bce37dbeb0857450fdd974a8d2e546c59c09f157bc467a16',
                    'power detector drift')
            power = subprocess.run(['sh', str(detector)], capture_output=True, text=True)
            require(power.returncode in (0, 2) and not power.stderr, 'power detector failed/reduced')
            (OUT / (name + '-power.env')).write_text(power.stdout)
            require(power_reference in (None, power.stdout), 'detectable power conditions changed')
            power_reference = power.stdout
            environment = {k: v for k, v in os.environ.items() if not k.startswith('FLYOLOGY_DB_')}
            environment.update(FLYOLOGY_DB_BENCH_WARMUP='8', FLYOLOGY_DB_BENCH_SCRATCH_ROOT=str(scratch),
                               TMPDIR=str(scratch),
                               FLYOLOGY_BENCH_LOCK_PATH='/run/lock/flyology-bench-host-cpu.lock',
                               LD_LIBRARY_PATH=':'.join(map(str, [benchmark / 'slatedb/target/release',
                                   tree / 'oracles/adapters/tidesdb/build',
                                   tree / 'oracles/adapters/tidesdb/build/upstream'])))
            argv = [str(benchmark / 'bin/flyology_db_benchmark_panel'), SLATE, DB,
                    '16', '1024', '256', '35', str(OUT / (name + '.json')),
                    str(OUT / (name + '.ndjson'))]
            with (OUT / (name + '.log')).open('w') as log:
                process = subprocess.Popen(argv, env=environment, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    write(OUT / 'active-panel.json', {'name': name, 'pid': process.pid,
                                                     'argv': argv, 'started_unix': time.time()})
                    print('COPY_SCREEN_ACTIVE', name, process.pid, flush=True)
                    status = wait_owned(process)
                finally:
                    join_owned_group(process)
            write(OUT / (name + '-status.json'), {'exit_status': status})
            require(status == 0, 'panel failed: ' + name)
            require(not list(scratch.iterdir()), 'panel scratch residue: ' + name)
            result = validate(loader, OUT / (name + '.json'), OUT / (name + '.ndjson'))
            require(snapshot(tree) == before[str(tree)], 'input drift after panel')
            audit()
            retained.append({'name': name, 'binary': PANEL_HASHES[tree], 'power_status': power.returncode,
                             'power': power.stdout, **result})
            write(OUT / (name + '-validated.json'), retained[-1])
            print('COPY_SCREEN_PANEL_VALID', name, flush=True)
        require({str(t): snapshot(t) for t in (BASE, CAND)} == before, 'full input-map drift')
        write(OUT / 'screen.json', {'classification': 'exploratory_two_outer_blocks_not_BC_CI',
                                   'panels': retained})
        print('DB_DIRECT_COPY_SCREEN_TERMINAL', flush=True)
    except BaseException as error:
        write(OUT / 'failure.json', {'error': repr(error)})
        raise
    finally:
        write(OUT / 'source-after.json', {str(t): snapshot(t) for t in (BASE, CAND)})

if __name__ == '__main__':
    main()

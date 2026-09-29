#!/usr/bin/env python3
"""Report nonadditive diagnostic phase ranking, never an optimization projection."""
import hashlib
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / 'artifacts/x86_64/natural-phase-receipt/natural-phase-screen/validated.json'
data = json.loads(RAW.read_text())
assert data['classification'] == 'instrumented_phase_attribution_not_speedup_or_wall_additivity'
samples = data['diagnostic_samples']
assert len(samples) == len(data['inner_pairs']) == len(data['plain_configuration_rows']) == 10
fields = ('build_ns', 'validation_ns', 'batch_put_ns', 'head_encode_ns', 'head_put_ns',
          'installation_ns', 'precompletion_ns', 'pipeline_unattributed_ns',
          'caller_preparation_ns', 'caller_admission_ns', 'caller_completion_drive_ns')
report = {
    'classification': 'exploratory_provider_inclusive_phase_ranking_not_removable_wall_shares',
    'source_sha256': hashlib.sha256(RAW.read_bytes()).hexdigest(),
    'paired_primary_metric': data['primary'],
    'measured_reopen_verifications': 20,
    'diagnostic_window_median_ns': statistics.median(s['window_ns'] for s in samples),
    'plain_window_median_ns': statistics.median(
        s['reference_primary_ns_per_operation'] for s in data['inner_pairs']),
    'plain_publications': [s['batch_publications'] for s in data['plain_configuration_rows']],
    'diagnostic_publications': [s['diagnostic']['batch_publications'] for s in samples],
    'marginal_phase_medians_ns_do_not_sum': {
        field: statistics.median(s['diagnostic'][field] for s in samples) for field in fields},
    'per_sample_elapsed_ratios_not_critical_path_shares': [
        {'sample': s['sample'], 'batch_put_over_window': s['diagnostic']['batch_put_ns'] / s['window_ns'],
         'build_over_window': s['diagnostic']['build_ns'] / s['window_ns']} for s in samples],
    'limitations': [
        'Publication occupancy differs between paired executions; observer perturbation cannot be excluded.',
        'Caller preparation includes driver fixture generation and overlaps worker execution.',
        'Batch PUT includes provider CPU, file I/O, barriers and scheduling; no disk-only claim.',
        'Marginal medians and overlapping spans are not additive or maximum removable wall shares.',
        'Unknown power profile; x86-only exploratory evidence, not final performance qualification.'],
    'next_question': 'Split batch PUT into provider CPU and publication syscalls on the exact candidate.',
}
print(json.dumps(report, indent=2, sort_keys=True))

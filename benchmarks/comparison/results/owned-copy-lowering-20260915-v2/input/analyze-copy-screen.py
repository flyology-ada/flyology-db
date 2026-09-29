#!/usr/bin/env python3
"""Describe two outer contrasts without manufacturing a B/C confidence interval."""
import hashlib
import json
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
screen = json.loads((root / 'screen.json').read_text())
assert screen['classification'] == 'exploratory_two_outer_blocks_not_BC_CI'
assert [p['name'] for p in screen['panels']] == ['B1', 'C1', 'C2', 'B2']
assert json.loads((root / 'source-before.json').read_text()) == json.loads(
    (root / 'source-after.json').read_text())
panels = {}
for panel in screen['panels']:
    name = panel['name']
    assert json.loads((root / (name + '-status.json')).read_text()) == {'exit_status': 0}
    samples = panel['inner_pairs']
    assert len(samples) == 10
    slate = statistics.median(s['reference_primary_ns_per_operation'] for s in samples)
    db = statistics.median(s['contender_primary_ns_per_operation'] for s in samples)
    assert slate == panel['primary']['reference_median']
    assert db == panel['primary']['contender_median']
    publications = [r['batch_publications'] for r in panel['publication_rows']]
    panels[name] = {'db_median_ms': db / 1e6, 'slate_median_ms': slate / 1e6,
                    'db_over_slate': db / slate,
                    'batch_head_publications': publications,
                    'publication_min_median_max': [min(publications),
                        statistics.median(publications), max(publications)],
                    'power_status': panel['power_status'], 'power': panel['power']}
contrasts = []
for baseline, candidate in [('B1', 'C1'), ('B2', 'C2')]:
    b, c = panels[baseline], panels[candidate]
    contrasts.append({'baseline': baseline, 'candidate': candidate,
        'candidate_over_baseline': c['db_median_ms'] / b['db_median_ms'],
        'db_window_reduction_percent': 100 * (1 - c['db_median_ms'] / b['db_median_ms']),
        'slate_anchor_candidate_over_baseline': c['slate_median_ms'] / b['slate_median_ms'],
        'anchor_normalized_ratio_diagnostic_only': c['db_over_slate'] / b['db_over_slate']})
result = {'classification': screen['classification'], 'promotion_qualified': False,
          'BC_confidence_interval': None, 'architectural_goal_achieved': False,
          'panels': panels, 'outer_contrasts': contrasts,
          'screen_sha256': hashlib.sha256((root / 'screen.json').read_bytes()).hexdigest()}
print(json.dumps(result, indent=2, sort_keys=True))

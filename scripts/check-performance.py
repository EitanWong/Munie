#!/usr/bin/env python3
"""Capture provenance and fail closed on incomplete, malformed or slow core measurements."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import sys

OPERATIONS = {'list', 'save', 'delete'}
RECORD_COUNTS = {100, 1000}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, label, minimum=0):
    try:
        valid = type(value) in (int, float) and math.isfinite(value) and value >= minimum
    except OverflowError:
        valid = False
    require(valid, f'{label} must be finite and >= {minimum}')
    return value


def integer(value, label, minimum):
    require(type(value) is int and value >= minimum, f'{label} must be an integer >= {minimum}')
    return value


def load_json(path):
    def reject_constant(value):
        raise ValueError(f'Invalid JSON constant: {value}')

    def reject_duplicate_keys(items):
        result = {}
        for key, value in items:
            require(key not in result, f'Duplicate JSON key: {key}')
            result[key] = value
        return result

    return json.loads(Path(path).read_text(encoding='utf-8'), parse_constant=reject_constant,
                      object_pairs_hook=reject_duplicate_keys)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate(report, budgets, expected_budget_sha256=None):
    require(type(report) is dict and type(budgets) is dict, 'Report and budgets must be objects')
    require(type(report['schemaVersion']) is int and report['schemaVersion'] == 1,
            'Unsupported report schema')
    require(type(budgets['schemaVersion']) is int and budgets['schemaVersion'] == 1,
            'Unsupported budget schema')
    require(report['configuration'] == budgets['configuration'] == 'release',
            'Performance measurements must use Release')
    minimum_samples = integer(budgets['minimumSamples'], 'minimumSamples', 20)
    minimum_warmups = integer(budgets['minimumWarmups'], 'minimumWarmups', 3)
    sample_count = integer(report['sampleCount'], 'sampleCount', minimum_samples)
    integer(report['warmupCount'], 'warmupCount', minimum_warmups)
    require(type(report['textUTF8Bytes']) is int and
            report['textUTF8Bytes'] == budgets['textUTF8Bytes'] == 248,
            'Synthetic text must have the fixed 248-byte workload')
    environment = report['environment']
    require(type(environment) is dict and type(environment['operatingSystem']) is str and
            bool(environment['operatingSystem'].strip()), 'Missing operating system provenance')
    integer(environment['processorCount'], 'processorCount', 1)
    provenance = report['provenance']
    require(type(provenance) is dict, 'Missing provenance')
    require(type(provenance['sourceRevision']) is str and
            re.fullmatch(r'[0-9a-f]{40}', provenance['sourceRevision']), 'Invalid source revision')
    require(type(provenance['workingTreeDirty']) is bool, 'Missing working-tree provenance')
    for key in ('sourceSHA256', 'budgetSHA256', 'executableSHA256', 'runnerSHA256'):
        require(type(provenance[key]) is str and re.fullmatch(r'[0-9a-f]{64}', provenance[key]),
                f'Invalid {key}')
    if expected_budget_sha256 is not None:
        require(provenance['budgetSHA256'] == expected_budget_sha256,
                'Report was captured against different budgets')
    for key in ('toolchain', 'architecture', 'capturedAtUTC'):
        require(type(provenance[key]) is str and bool(provenance[key].strip()),
                f'Missing {key} provenance')
    limits = budgets['p95MillisecondsByRecordCount']
    require(type(limits) is dict and set(limits) == {str(count) for count in RECORD_COUNTS},
            'Budgets must cover exactly 100 and 1000 records')
    workloads = report['workloads']
    require(type(workloads) is list and len(workloads) == len(RECORD_COUNTS),
            'Report must cover each workload once')
    seen = set()
    summaries = []
    for workload in workloads:
        require(type(workload) is dict, 'Workload must be an object')
        count = integer(workload['recordCount'], 'recordCount', 1)
        require(count in RECORD_COUNTS and count not in seen, 'Missing, duplicate or unknown workload')
        seen.add(count)
        integer(workload['fixtureBytes'], 'fixtureBytes', count * 248)
        require(workload['roundTripVerified'] is True, 'Reopened-store correctness was not verified')
        operations = workload['operations']
        require(type(operations) is dict and set(operations) == OPERATIONS,
                f'{count}: list, save and delete must all be measured')
        require(type(limits[str(count)]) is dict and set(limits[str(count)]) == OPERATIONS,
                f'{count}: missing operation budgets')
        for operation in sorted(OPERATIONS):
            measurement = operations[operation]
            require(type(measurement) is dict, f'{count}/{operation}: measurement must be an object')
            samples = measurement['samplesMilliseconds']
            require(type(samples) is list and len(samples) == sample_count,
                    f'{count}/{operation}: sample count mismatch')
            ordered = sorted(number(value, 'sampleMilliseconds') for value in samples)
            for percentile, fraction in (('p50Milliseconds', .50), ('p95Milliseconds', .95)):
                actual = number(measurement[percentile], percentile)
                expected = ordered[math.ceil(sample_count * fraction) - 1]
                require(math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-9),
                        f'{count}/{operation}: {percentile} does not match raw samples')
            limit = number(limits[str(count)][operation], 'p95 budget', minimum=0.001)
            p95 = measurement['p95Milliseconds']
            require(p95 <= limit, f'{count}/{operation}: p95 {p95:.3f} ms exceeds {limit:.3f} ms')
            summaries.append(f'{count}/{operation}: p95 {p95:.3f} ms <= {limit:.3f} ms')
    require(seen == RECORD_COUNTS, 'Missing workload')
    return summaries


def capture(raw, budgets, executable, output, root):
    report = load_json(raw)

    def command(*args):
        return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.STDOUT).strip()

    source_paths = sorted((root / 'packages/MunieCore/Sources').rglob('*.swift'))
    source_paths.append(root / 'packages/MunieCore/Package.swift')
    source_digest = hashlib.sha256()
    for path in sorted(source_paths):
        source_digest.update(str(path.relative_to(root)).encode() + b'\0' + path.read_bytes() + b'\0')
    runner_digest = hashlib.sha256()
    for name in ('scripts/check-performance.py', 'scripts/benchmark-core.sh'):
        runner_digest.update(name.encode() + b'\0' + (root / name).read_bytes() + b'\0')
    report['provenance'] = {
        'sourceRevision': command('git', 'rev-parse', 'HEAD'),
        'workingTreeDirty': bool(command('git', 'status', '--porcelain', '--untracked-files=normal')),
        'sourceSHA256': source_digest.hexdigest(),
        'budgetSHA256': sha256(budgets),
        'executableSHA256': sha256(executable),
        'runnerSHA256': runner_digest.hexdigest(),
        'toolchain': command('swift', '--version'),
        'architecture': platform.machine(),
        'capturedAtUTC': datetime.now(timezone.utc).isoformat(),
    }
    # Keep even rejected measurements for diagnosis; never replace raw samples with a pass flag.
    output.write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n',
                      encoding='utf-8')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('budgets', type=Path)
    parser.add_argument('--capture', action='store_true', help='Add actual local build provenance')
    parser.add_argument('--executable', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.capture:
        require(args.executable is not None and args.output is not None,
                '--capture requires --executable and --output')
        root = Path(__file__).resolve().parent.parent
        report = capture(args.report, args.budgets, args.executable, args.output, root)
    else:
        require(args.executable is None and args.output is None,
                '--executable/--output require --capture')
        report = load_json(args.report)
    summaries = validate(report, load_json(args.budgets), sha256(args.budgets))
    print('\n'.join(summaries))
    print('Core performance budgets passed; host measurements do not establish device UX acceptance.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Performance gate failed: {error}')

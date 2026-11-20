#!/usr/bin/env python3
"""Summarises measure.sh output: which vCPUs lose time to the hypervisor, at which second of the minute, and for how long."""
import collections
import glob
import os
import re
import statistics
import sys

MIN_GAP_US = 15_000
SKIP_S = 15  # gap detectors start up and shut down in the first and last seconds


def load_steal(path):
    rows = []
    for line in open(path):
        parts = line.split()
        rows.append((float(parts[0]), {int(c): int(v) for c, v in (p.split(':') for p in parts[1:])}))
    per_cpu = collections.defaultdict(collections.Counter)
    for (_, before), (t, after) in zip(rows, rows[1:]):
        for cpu, ticks in after.items():
            delta = ticks - before.get(cpu, 0)
            if delta > 0:
                per_cpu[cpu][int(t) % 60] += delta
    return per_cpu, len(rows)


def load_gaps(out):
    gaps = []
    for path in glob.glob(os.path.join(out, 'gaps-*.txt')) + glob.glob(os.path.join(out, 'spin-[0-9]*.txt')):
        cpu = int(re.search(r'-(\d+)\.txt$', path).group(1))
        for line in open(path):
            parts = line.split()
            if len(parts) == 2:
                end, us = float(parts[0]), int(parts[1])
                gaps.append((end - us / 1e6, cpu, us))
    return gaps


def load_cores(out):
    path = os.path.join(out, 'lscpu-e.txt')
    if not os.path.exists(path):
        return {}
    cores = {}
    for line in open(path).readlines()[1:]:
        parts = line.split()
        cores[int(parts[0])] = (parts[2], parts[1])  # (socket, core)
    return cores


def main(out):
    per_cpu, seconds = load_steal(os.path.join(out, 'steal.txt'))
    stamps = [float(line.split()[0]) for line in open(os.path.join(out, 'steal.txt'))]
    t0, t1 = stamps[0] + SKIP_S, stamps[-1] - SKIP_S
    cores = load_cores(out)
    print(f'{out}: {seconds} s of steal data')

    print('\nvCPUs with the most steal (ticks of 10 ms):')
    totals = sorted(per_cpu.items(), key=lambda kv: -sum(kv[1].values()))[:6]
    for cpu, by_second in totals:
        second, ticks = by_second.most_common(1)[0]
        core = f' socket/core {"/".join(cores[cpu])}' if cpu in cores else ''
        print(f'  vCPU {cpu:3d}{core}: {sum(by_second.values()):3d} ticks, {ticks} of them at :{second:02d}')

    big = [g for g in load_gaps(out) if g[2] >= MIN_GAP_US and t0 < g[0] < t1]
    by_second = collections.defaultdict(lambda: collections.defaultdict(list))
    for start, cpu, us in big:
        by_second[round(start) % 60][int(start // 60)].append((cpu, us))
    print(f'\nGaps of {MIN_GAP_US // 1000} ms or more (excluding the first and last {SKIP_S} s), '
          'grouped by the second of the minute in which they start:')
    if not by_second:
        print('  none')
    for second, minutes in sorted(by_second.items(), key=lambda kv: -len(kv[1])):
        lengths = [us / 1000 for hits in minutes.values() for _, us in hits]
        stolen = any(per_cpu[cpu][second] for hits in minutes.values() for cpu, _ in hits)
        cpus_each = ' | '.join('+'.join(str(c) for c in sorted({c for c, _ in hits})) for _, hits in sorted(minutes.items()))
        print(f'  :{second:02d}  {len(minutes)} minute(s), median {statistics.median(lengths):.1f} ms, '
              f'{"STEAL" if stolen else "no steal"}; vCPUs per minute: {cpus_each}')

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')

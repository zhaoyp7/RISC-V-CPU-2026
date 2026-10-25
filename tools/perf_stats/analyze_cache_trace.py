#!/usr/bin/env python3
"""Replay baseline demand timing through small read-cache tag models.

This measures hit availability on a fixed baseline trace, not CPU IPC. Fills
occur at actual response edges; store issue/drain invalidate and cancel old
pending fills. Same-cycle fills are visible only to the next cycle's lookup.
"""
import argparse
from collections import Counter, OrderedDict, deque
from itertools import groupby
import json
from pathlib import Path
import re


class ReadCache:
    def __init__(self, entries, ways=1, write_allocate=False):
        assert entries >= ways and entries % ways == 0
        self.sets = entries // ways
        assert self.sets & (self.sets - 1) == 0
        self.entries, self.ways = entries, ways
        self.write_allocate = write_allocate
        self.lines = [OrderedDict() for _ in range(self.sets)]
        self.epochs = Counter()
        self.pending = {}
        self.invalidated = set()
        self.issued_stores = set()
        self.store_port_used = False
        self.counts = Counter()

    def start_cycle(self):
        self.invalidated.clear()
        self.issued_stores.clear()
        self.store_port_used = False

    def invalidate(self, address, kind='S'):
        if address >= 0x10000000:
            return
        word = address >> 2
        self.epochs[word] += 1
        self.invalidated.add(word)
        if kind == 'S':
            self.issued_stores.add(word)
        self.lines[word & (self.sets - 1)].pop(word, None)
        self.counts['invalidations'] += 1

    def request(self, sequence, address):
        assert sequence not in self.pending
        self.counts['requests'] += 1
        word = address >> 2
        cacheable = address < 0x10000000
        lines = self.lines[word & (self.sets - 1)]
        hit = cacheable and word in lines
        if hit:
            self.counts['hits'] += 1
            lines.move_to_end(word)
        elif cacheable:
            self.counts['misses'] += 1
        else:
            self.counts['uncacheable'] += 1
        fill = cacheable and not hit and word not in self.invalidated
        self.pending[sequence] = (word, self.epochs[word], fill, hit, lines.get(word))

    def fill(self, word, data):
        lines = self.lines[word & (self.sets - 1)]
        lines[word] = data
        lines.move_to_end(word)
        if len(lines) > self.ways:
            lines.popitem(last=False)
            self.counts['replacements'] += 1

    def drain_write(self, address, mask, data):
        if (self.write_allocate and address < 0x10000000 and mask == 15
                and address >> 2 not in self.issued_stores):
            self.fill(address >> 2, data)
            self.store_port_used = True
            self.counts['store_allocations'] += 1

    def response(self, sequence, keep, data=None):
        word, epoch, fill, hit, hit_data = self.pending.pop(sequence)
        self.counts['responses'] += 1
        if hit and keep:
            self.counts['kept_hits'] += 1
            if data is not None and hit_data is not None:
                assert hit_data == data, ('cached data differs from real response',
                                          sequence, hex(word << 2), hit_data, data)
                self.counts['data_checked_hits'] += 1
        if not fill:
            return
        if not keep:
            self.counts['canceled_fills'] += 1
        elif self.epochs[word] != epoch or word in self.invalidated:
            self.counts['invalidated_fills'] += 1
        elif self.store_port_used:
            self.counts['busy_fill_port'] += 1
        else:
            self.fill(word, data)
            self.counts['fills'] += 1

    def result(self):
        c = self.counts
        assert c['requests'] == c['hits'] + c['misses'] + c['uncacheable']
        return dict(entries=self.entries, ways=self.ways, bytes=self.entries * 4,
                    policy='write_allocate' if self.write_allocate else 'read_fill',
                    **{k: c[k] for k in ('requests', 'responses', 'hits', 'misses',
                       'uncacheable', 'fills', 'canceled_fills', 'invalidated_fills',
                       'replacements', 'invalidations', 'store_allocations',
                       'busy_fill_port', 'kept_hits', 'data_checked_hits')},
                    hit_pct=100 * c['hits'] / max(c['requests'], 1),
                    pending=len(self.pending))


def parse_trace(path):
    previous = -1
    with path.open() as stream:
        for line in stream:
            if not line.startswith('[DTRACE] '):
                continue
            fields = dict(re.findall(r'(\w+)=(\w+)', line))
            event = {'kind': fields['kind'], 'cycle': int(fields['cycle'])}
            for key in ('seq', 'keep', 'mask'):
                if key in fields:
                    event[key] = int(fields[key])
            if 'addr' in fields:
                event['addr'] = int(fields['addr'], 16)
            if 'data' in fields:
                event['data'] = int(fields['data'], 16)
            assert event['cycle'] >= previous
            previous = event['cycle']
            yield event


def replay(events, models):
    pending, order, latency, counts, words = {}, deque(), Counter(), Counter(), set()
    for cycle, group in groupby(events, key=lambda e: e['cycle']):
        group = list(group)
        for model in models:
            model.start_cycle()
        for event in group:
            if event['kind'] in ('S', 'D'):
                counts[event['kind']] += 1
                for model in models:
                    model.invalidate(event['addr'], event['kind'])
        for event in group:
            if event['kind'] == 'L':
                seq, address = event['seq'], event['addr']
                assert seq not in pending
                pending[seq] = cycle
                order.append(seq)
                counts['L'] += 1
                words.add(address >> 2)
                for model in models:
                    model.request(seq, address)
        for event in group:
            if event['kind'] == 'D':
                for model in models:
                    model.drain_write(event['addr'], event.get('mask', 0), event.get('data'))
        for event in group:
            if event['kind'] == 'R':
                seq = event['seq']
                assert order.popleft() == seq, 'response order changed'
                latency[cycle - pending.pop(seq)] += 1
                counts['R'] += 1
                for model in models:
                    model.response(seq, event['keep'], event.get('data'))
    assert counts['L'] - counts['R'] == len(pending) <= 8
    return dict(requests=counts['L'], responses=counts['R'], stores=counts['S'],
                drains=counts['D'], unique_words=len(words), pending=len(pending),
                response_latency_histogram=dict(sorted(latency.items())),
                caches=[m.result() for m in models])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--results', type=Path, required=True, help='collect.py capture directory')
    ap.add_argument('--baseline', type=Path, required=True, help='baseline statistics results.json')
    ap.add_argument('--entries', type=int, nargs='+', default=[4, 8, 16, 32, 64])
    ap.add_argument('--ways', type=int, nargs='+', default=[1, 2])
    ap.add_argument('--policies', nargs='+', choices=['read_fill', 'write_allocate'],
                    default=['read_fill', 'write_allocate'])
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    captured = json.loads((args.results / 'results.json').read_text())
    baseline = json.loads(args.baseline.read_text())
    assert captured['source_inputs'] == baseline['source_inputs']
    rows = []
    for row, old in zip(captured['benchmarks'], baseline['benchmarks']):
        assert row == old, 'passive tracing changed an existing counter/cycle'
        models = [ReadCache(n, w, p == 'write_allocate') for n in args.entries
                  for w in args.ways for p in args.policies if n >= w]
        result = replay(parse_trace(args.results / (row['case'] + '-stats.stderr')), models)
        assert result['requests'] == row['counters']['BE']['ld_issue']
        assert result['responses'] == row['counters']['BE']['ld_resp']
        assert result['drains'] == row['counters']['BE']['st_issue']
        rows.append(dict(case=row['case'], **result))
        print(row['case'], 'requests', result['requests'], 'unique words', result['unique_words'],
              'hits', [(m.entries, m.ways, m.result()['policy'], round(m.result()['hit_pct'], 2))
                       for m in models if m.entries in (8, 16)])
    assert len(rows) == len(baseline['benchmarks']) == 6
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(dict(benchmarks=rows,
        note='Fixed-trace availability, not end-to-end IPC or measured hardware cache hits. LRU within sets. Surviving read fills, issue+drain invalidation, full-word committed drain allocation, store priority on a shared fill port, no same-cycle fill forwarding. Kept hit values checked against actual baseline response data when available.'), indent=2) + '\n')


if __name__ == '__main__':
    main()

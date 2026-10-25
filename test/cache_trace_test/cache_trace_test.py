#!/usr/bin/env python3
"""Independent event scenarios for the passive cache opportunity model."""
import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('cache_trace',Path(__file__).resolve().parents[2]/'tools/perf_stats/analyze_cache_trace.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def event(cycle,kind,**fields):return dict(cycle=cycle,kind=kind,**fields)
def load(c,seq,addr=0):return event(c,'L',seq=seq,addr=addr)
def response(c,seq,data=7,keep=1):return event(c,'R',seq=seq,data=data,keep=keep)
def store(c,kind='S',addr=0,data=9,mask=15):return event(c,kind,addr=addr,data=data,mask=mask)
def run(events,ways=1,write=False):
    cache=m.ReadCache(4,ways,write);m.replay(events,[cache]);return cache.result()
class Scenarios(unittest.TestCase):
    def test_fill_then_hit(self):
        r=run([load(0,0),response(2,0),load(3,1),response(5,1)])
        self.assertEqual((r['hits'],r['data_checked_hits']),(1,1))
    def test_store_cancels_pending_fill(self):
        r=run([load(0,0),store(1),response(2,0),load(3,1),response(5,1,data=9)])
        self.assertEqual((r['hits'],r['invalidated_fills']),(0,1))
    def test_store_invalidates_resident(self):
        r=run([load(0,0),response(1,0),store(2),load(3,1),response(4,1,data=9)])
        self.assertEqual(r['hits'],0)
    def test_drain_invalidates_an_older_fill(self):
        r=run([store(0),load(1,0),response(2,0),store(3,'D'),load(4,1),response(6,1,data=9)])
        self.assertEqual(r['hits'],0)
    def test_fill_not_visible_at_same_edge(self):
        r=run([load(0,0),load(2,1),response(2,0),load(3,2),response(4,1),response(5,2)])
        self.assertEqual(r['hits'],1)
    def test_associativity(self):
        e=[load(0,0),response(1,0),load(2,1,16),response(3,1),load(4,2),response(5,2)]
        self.assertEqual(run(e)['hits'],0);self.assertEqual(run(e,ways=2)['hits'],1)
    def test_full_store_allocates_after_edge(self):
        e=[store(0),store(1,'D'),load(2,0),response(4,0,data=9)]
        self.assertEqual(run(e)['hits'],0)
        self.assertEqual(run(e,write=True)['data_checked_hits'],1)
    def test_partial_store_does_not_allocate(self):
        r=run([store(0),store(1,'D',mask=1),load(2,0),response(4,0,data=9)],write=True)
        self.assertEqual(r['hits'],0)
    def test_detect_stale_cached_value(self):
        with self.assertRaises(AssertionError):
            run([load(0,0),response(1,0),load(2,1),response(3,1,data=8)])
    def test_canceled_response_does_not_fill(self):
        r=run([load(0,0),response(1,0,keep=0),load(2,1),response(3,1)])
        self.assertEqual((r['hits'],r['canceled_fills']),(0,1))
    def test_store_has_shared_fill_port_priority(self):
        r=run([load(0,0,16),store(2,'D'),response(2,0),load(3,1,16),response(5,1)],write=True)
        self.assertEqual((r['hits'],r['busy_fill_port']),(0,1))
    def test_same_cycle_issue_prevents_drain_allocation(self):
        r=run([store(0),store(0,'D'),load(1,0),response(3,0,data=9)],write=True)
        self.assertEqual((r['hits'],r['store_allocations']),(0,0))
    def test_mmio_never_cached(self):
        e=[store(0,'D',addr=0x80000000),load(1,0,0x80000000),response(2,0),
           load(3,1,0x80000000),response(4,1)]
        r=run(e,write=True)
        self.assertEqual((r['uncacheable'],r['hits'],r['store_allocations']),(2,0,0))
if __name__=='__main__':unittest.main()

// Direct tests of LSQ query snapshots and committed-store drain arbitration.
#include "Vlsq.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

struct Harness {
    Vlsq& d;
    unsigned checks = 0, fails = 0;
    void check(bool ok, const char* what) {
        ++checks;
        if (!ok) { ++fails; std::printf("FAIL: %s\n", what); }
    }
    void tick() { d.clk=0; d.eval(); d.clk=1; d.eval(); d.clk=0; d.eval(); }
    void reset() {
        d.reset=1; d.alloc_valid=0; d.alloc_fire=0; d.alloc_id=0;
        d.alloc_rob=0; d.alloc_is_store=0; d.seq_base=0;
        d.fill_valid=0; d.fill_id=0; d.fill_addr=0; d.fill_wdata=0;
        d.fill_wstrb=0; d.fill_is_store=1;
        d.prefill_valid=0; d.prefill_id=0; d.prefill_addr=0;
        d.commit_valid=0; d.commit_is_store=0; d.commit_is_load=0;
        d.commit_id=0; d.squash_valid=0; d.squash_seq=0;
        d.drain_fire=0; d.store_resp_valid=0; d.query_valid=0;
        d.query_seq=0; d.query_addr=0; d.query_resp_ready=0; d.query_flush=0;
        tick(); d.reset=0; d.eval();
    }
    void alloc(unsigned id, unsigned seq) {
        d.alloc_valid=1; d.alloc_id=id; d.alloc_is_store=1;
        d.seq_base=seq; d.alloc_fire=1; d.eval();
        check(d.alloc_ready, "allocate store"); tick();
        d.alloc_fire=0; d.alloc_valid=0; d.eval();
    }
    void fill(unsigned id, uint32_t addr, uint32_t data, unsigned mask=15) {
        d.fill_valid=1; d.fill_id=id; d.fill_addr=addr;
        d.fill_wdata=data; d.fill_wstrb=mask; tick();
        d.fill_valid=0; d.eval();
    }
    void query(unsigned seq, uint32_t addr) {
        d.query_seq=seq; d.query_addr=addr; d.query_valid=1; d.eval();
        check(d.query_ready, "query accepted"); tick();
        d.query_valid=0; d.eval(); check(d.query_resp_valid, "snapshot valid");
    }
    void response(bool blocked, bool fwd, uint32_t data=0) {
        d.eval(); check(d.query_resp_valid, "response remains valid");
        check(bool(d.query_blocked)==blocked, "blocked result");
        check(bool(d.query_fwd_valid)==fwd, "forwarding result");
        if (fwd) check(d.query_fwd_data==data, "forwarding data");
    }
    void commit_store(unsigned id, int id2=-1) {
        d.commit_valid=(id2>=0)?3:1; d.commit_is_store=d.commit_valid;
        d.commit_id=id | ((id2>=0?unsigned(id2):0) << ((TB_DEPTH==16)?4:3));
        tick(); d.commit_valid=0; d.commit_is_store=0; d.eval();
    }
    void drain(unsigned id, uint32_t base, uint32_t data_base, unsigned mask) {
        d.eval(); check(d.drain_valid,"committed store drain valid");
        check(d.drain_id==id,"oldest store id");
        check(d.drain_addr==base+4*id,"store drain address");
        check(d.drain_wdata==data_base+id,"store drain data");
        check(d.drain_wstrb==mask,"store drain byte enables");
    }
    void consume() { d.query_resp_ready=1; tick(); d.query_resp_ready=0; d.eval(); }
};

int main(int argc, char** argv) {
    VerilatedContext context; context.threads(1); context.commandArgs(argc,argv);
    Vlsq dut{&context}; Harness h{dut}; auto& d=dut;
    h.reset();
    // Empty lookup and byte offsets within the same word.
    h.query(100,0x100); h.response(false,false); h.consume();
    h.check(!d.query_resp_valid,"consumed snapshot clears");
    // Physical slot order differs from dispatch age; tree must pick max seq.
    for (unsigned i=0;i<TB_DEPTH;++i) {
        unsigned slot=(i*5)%TB_DEPTH;
        h.alloc(slot,10+i); h.fill(slot,0x100,0xa000+i);
    }
    for (unsigned i=0;i<TB_DEPTH;++i) {
        h.query(11+i,0x103); h.response(false,true,0xa000+i); h.consume();
    }
    // A held response must not be replaced by another query under backpressure.
    h.query(100,0x100); d.query_valid=1; d.query_seq=1; d.query_addr=0x200; d.eval();
    h.check(!d.query_ready,"backpressure rejects replacement");
    for(unsigned i=0;i<4;++i) { h.tick(); h.response(false,true,0xa000+TB_DEPTH-1); }
    // Consume old and capture new on one edge, with no response bubble.
    d.query_resp_ready=1; d.eval(); h.check(d.query_ready,"consume permits capture");
    h.tick(); d.query_resp_ready=0; d.query_valid=0; h.response(false,false);
    // Flush plus capture: new snapshot must survive the flush of old metadata.
    d.query_flush=1; h.query(100,0x100); d.query_flush=0;
    h.response(false,true,0xa000+TB_DEPTH-1);
    d.query_flush=1; h.tick(); d.query_flush=0; d.eval();
    h.check(!d.query_resp_valid,"flush clears snapshot");

    h.reset(); h.alloc(0,10); h.fill(0,0x100,0x12345678); h.alloc(1,20);
    h.query(30,0x100); h.response(true,false);
    h.fill(1,0x200,0x55555555); h.response(true,false); // unknown captured
    h.consume(); h.query(30,0x100); h.response(false,true,0x12345678); h.consume();
    // Newest partial match blocks even though an older full match exists.
    h.fill(1,0x100,0xab,1); h.query(30,0x100); h.response(true,false);
    h.fill(1,0x100,0xabcdef01); h.response(true,false); // full flag captured
    h.consume(); h.query(30,0x100); h.response(false,true,0xabcdef01); h.consume();

    // Store can drain, free and reuse its LSQ slot while response is held.
    h.reset(); h.alloc(3,10); h.fill(3,0x100,0x11223344);
    h.query(50,0x100); h.response(false,true,0x11223344);
    d.commit_valid=1; d.commit_is_store=1; d.commit_id=3; h.tick(); d.commit_valid=0;
    d.eval(); h.check(d.drain_valid && d.drain_id==3,"old store drains");
    d.drain_fire=1; h.tick(); d.drain_fire=0;
    d.store_resp_valid=1; h.tick(); d.store_resp_valid=0;
    h.alloc(3,30); h.fill(3,0x100,0x55667788);
    h.response(false,true,0x11223344); // no live slot dereference
    h.consume(); h.query(50,0x100); h.response(false,true,0x55667788);
    h.consume(); h.query(20,0x100); h.response(false,false); // younger store excluded
    h.consume();
    // Store squash changes live table but not an older captured response.
    d.squash_valid=1; d.squash_seq=20; h.tick(); d.squash_valid=0;
    h.query(50,0x100); h.response(false,false);
    // Fill all physical slots in permuted age order; hold write ready low
    // while committing. No store may appear before its commit edge.
    for (unsigned round=0; round<2; ++round) {
        h.reset();
        unsigned order[TB_DEPTH];
        for (unsigned age=0; age<TB_DEPTH; ++age) {
            unsigned id=(5*age+3)%TB_DEPTH;
            h.alloc(id,0x90000000u+(round?0:age));
            h.fill(id,0x2000+4*id,0xc3000000u+id,(id%15)+1);
            h.check(!d.drain_valid,"uncommitted stores never drain");
            order[age]=round?age:id; // same seq uses ascending physical id
        }
        for (unsigned age=0; age<TB_DEPTH; age+=TB_W) {
            unsigned id=(5*age+3)%TB_DEPTH;
            int id2=(TB_W==2)?int((5*(age+1)+3)%TB_DEPTH):-1;
            h.commit_store(id,id2);
        }
        for (unsigned pos=0; pos<TB_DEPTH; ++pos) {
            unsigned id=order[pos];
            for (unsigned stall=0; stall<3; ++stall) {
                h.drain(id,0x2000,0xc3000000u,(id%15)+1);
                h.tick(); // ready low: winner and payload remain stable
            }
            d.drain_fire=1; h.tick(); d.drain_fire=0;
            h.check(d.count==TB_DEPTH,"sent stores retained until write response");
        }
        h.check(!d.drain_valid,"sent entries cannot be sent twice");
        // All stores outstanding. Each B response frees its FIFO head slot;
        // allocate that id on the same edge and send its new owner while the
        // remaining older B responses are still pending. This wraps the FIFO.
        for (unsigned pos=0; pos<TB_DEPTH; ++pos) {
            unsigned id=order[pos];
            d.store_resp_valid=1; d.alloc_valid=1; d.alloc_is_store=1;
            d.alloc_fire=1; d.alloc_id=id; d.seq_base=0xa0000000u+pos; d.eval();
            h.check(d.alloc_ready,"B head can be reused on response edge");
            h.tick(); d.store_resp_valid=0; d.alloc_valid=0; d.alloc_fire=0;
            h.fill(id,0x3000+4*id,0xd4000000u+id);
            h.check(!d.drain_valid,"reused slot waits for new commit");
            h.commit_store(id); h.drain(id,0x3000,0xd4000000u,15);
            d.drain_fire=1; h.tick(); d.drain_fire=0;
            h.check(!d.drain_valid,"new sent owner excluded from selection");
            h.check(d.count==TB_DEPTH,"old B cannot discard another new owner");
        }
        for (unsigned pos=0; pos<TB_DEPTH; ++pos) {
            d.store_resp_valid=1; h.tick(); d.store_resp_valid=0;
            h.check(d.count==TB_DEPTH-pos-1,"new B releases exactly one slot");
            d.alloc_valid=1; d.alloc_id=order[pos]; d.eval();
            h.check(d.alloc_ready,"new B releases matching sent FIFO id");
            if (pos+1<TB_DEPTH) {
                d.alloc_id=order[pos+1]; d.eval();
                h.check(!d.alloc_ready,"next outstanding owner remains reserved");
            }
            d.alloc_valid=0;
        }
        h.check(d.count==0 && !d.drain_valid,"all store owners drain and release");
    }
    // Recovery removes speculative stores and preserves committed stores.
    h.reset(); h.alloc(0,10); h.fill(0,0x4000,0x12345678);
    h.alloc(1,20); h.fill(1,0x4004,0xabcdef01); h.commit_store(0);
    d.squash_valid=1; d.squash_seq=0; h.tick(); d.squash_valid=0;
    h.check(d.count==1 && d.drain_valid && d.drain_id==0,
            "squash preserves committed owner and removes speculative store");
    d.drain_fire=1; h.tick(); d.drain_fire=0;
    d.store_resp_valid=1; h.tick(); d.store_resp_valid=0;
    h.check(d.count==0 && !d.drain_valid,"squashed store never writes");
    std::printf("lsq_query W=%d depth=%d: %u checks, %u failures\n",TB_W,TB_DEPTH,h.checks,h.fails);
    return h.fails ? 1:0;
}

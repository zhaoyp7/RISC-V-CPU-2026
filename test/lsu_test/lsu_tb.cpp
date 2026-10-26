// -----------------------------------------------------------------------------
// lsu_tb.cpp — LSU + LSQ v2 integration test.
//
// Covers: store complete/commit/drain, load formatting, multiple outstanding
// loads, store-to-load forwarding, partial-store ordering, squash, LSQ id
// backpressure and reset.
// -----------------------------------------------------------------------------

#include "Vlsu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <utility>
#include <vector>

#ifndef TB_LSQ_DEPTH
#define TB_LSQ_DEPTH 8
#endif

namespace {

constexpr int PRF = 6;
constexpr int LSQ = (TB_LSQ_DEPTH == 16) ? 4 : 3;
constexpr int ROB = 5;
constexpr int DW = 124 + 3 * PRF + LSQ + ROB;
constexpr int IN_WORDS = (DW + 31) / 32;
constexpr uint32_t BYTE = 0, HALF = 1, WORD = 2;

enum : int {
    O_PC = 1, O_INST = 33, O_IMM = 65, O_RD = 97, O_REG_WE = 102,
    O_ALU = 103, O_A_SEL = 108, O_B_SEL = 110, O_WB = 111,
    O_BR = 113, O_JAL = 114, O_JALR = 115, O_LOAD = 116, O_STORE = 117,
    O_ILLEGAL = 118, O_MEM_SIZE = 119, O_MEM_UNS = 121,
    O_DEST = 122, O_S1 = 128, O_S1R = 134, O_S2 = 135, O_S2R = 141,
    O_LSQ = 142, O_ROB = O_LSQ + LSQ,
};

struct Uop {
    uint32_t imm = 0;
    uint32_t dest = 0;
    uint32_t is_load = 0;
    uint32_t is_store = 0;
    uint32_t illegal = 0;
    uint32_t mem_size = WORD;
    uint32_t mem_uns = 0;
    uint32_t lsq = 0;
    uint32_t rob = 0;
    uint32_t addr_only = 0;
};

template <typename Vec>
void set_field(Vec& vec, int offset, int width, uint32_t value) {
    for (int b = 0; b < width; ++b) {
        int bit = offset + b;
        int word = bit / 32;
        int shift = bit % 32;
        if ((value >> b) & 1u) vec[word] |= (1u << shift);
        else vec[word] &= ~(1u << shift);
    }
}

struct Harness {
    Vlsu* dut = nullptr;
    uint8_t mem[1 << 16] = {};
    bool auto_respond = true;
    bool load_ready = true;
    bool store_ready = true;
    long checks = 0;
    long fails = 0;
    uint32_t seq_base = 0;
    uint32_t seq_of_rob[32] = {};

    // Requests accepted by the memory model, waiting for a response.
    std::deque<uint32_t> ld_pending;
    std::deque<uint8_t>  st_pending;
    std::vector<uint32_t> accepted_loads;
    std::deque<std::pair<uint32_t, uint32_t>> results;

    uint32_t read_word(uint32_t addr) const {
        uint32_t a = addr & 0xffff;
        return (uint32_t)mem[a] | ((uint32_t)mem[(a + 1) & 0xffff] << 8) |
               ((uint32_t)mem[(a + 2) & 0xffff] << 16) |
               ((uint32_t)mem[(a + 3) & 0xffff] << 24);
    }

    void write_word(uint32_t addr, uint32_t value, uint8_t strb) {
        uint32_t a = addr & 0xffff;
        for (int lane = 0; lane < 4; ++lane)
            if (strb & (1u << lane))
                mem[(a + lane) & 0xffff] = (uint8_t)(value >> (8 * lane));
    }

    void tick() {
        dut->clk = 0;
        dut->eval();

        // Memory model: one response per cycle, in request order.
        dut->ld_req_ready = load_ready;
        dut->st_req_ready = store_ready;
        const bool ld_resp = auto_respond && !ld_pending.empty();
        const bool st_resp = auto_respond && !st_pending.empty();
        dut->ld_resp_valid = ld_resp ? 1 : 0;
        dut->ld_resp_rdata = ld_resp ? read_word(ld_pending.front()) : 0;
        dut->st_resp_valid = st_resp ? 1 : 0;
        dut->eval();

        const bool ld_fire = dut->ld_req_valid && dut->ld_req_ready;
        const bool st_fire = dut->st_req_valid && dut->st_req_ready;
        const uint32_t ld_addr = dut->ld_req_addr;
        const uint32_t st_addr = dut->st_req_addr;
        const uint32_t st_data = dut->st_req_wdata;
        const uint8_t  st_strb = (uint8_t)dut->st_req_wstrb;
        const bool result_fire = dut->load_result_valid && dut->load_result_ready;
        const uint32_t result_tag = dut->load_result_tag;
        const uint32_t result_value = dut->load_result_value;

        dut->clk = 1;
        dut->eval();

        if (ld_fire) {
            ld_pending.push_back(ld_addr);
            accepted_loads.push_back(ld_addr);
        }
        if (result_fire) results.push_back({result_tag, result_value});
        if (st_fire) {
            write_word(st_addr, st_data, st_strb);
            st_pending.push_back(1);
        }
        if (ld_resp) ld_pending.pop_front();
        if (st_resp) st_pending.pop_front();

        dut->clk = 0;
        dut->eval();
        dut->ld_resp_valid = 0;
        dut->st_resp_valid = 0;
        dut->eval();
    }

    void clear_inputs() {
        dut->alloc_valid = 0;
        dut->alloc_id = 0;
        dut->alloc_rob = 0;
        dut->alloc_is_store = 0;
        dut->alloc_fire = 0;
        dut->seq_base = 0;
        dut->squash_seq = 0;
        dut->issue_valid = 0;
        dut->issue_seq = 0;
        dut->issue_addr_only = 0;
        for (int i = 0; i < IN_WORDS; ++i) dut->issue_uop[i] = 0;
        dut->issue_src1 = 0;
        dut->issue_src2 = 0;
        dut->commit_valid = 0;
        dut->commit_is_store = 0;
        dut->commit_is_load = 0;
        dut->commit_id = 0;
        dut->squash_valid = 0;
        dut->squash_rob_idx = 0;
        dut->load_result_ready = 0;
        dut->ld_req_ready = 0;
        dut->st_req_ready = 0;
        dut->ld_resp_valid = 0;
        dut->st_resp_valid = 0;
        dut->ld_resp_rdata = 0;
    }

    void reset() {
        auto_respond = true;
        load_ready = true;
        store_ready = true;
        dut->reset = 1;
        clear_inputs();
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        tick();
        seq_base = 0;
        for (int i = 0; i < 32; ++i) seq_of_rob[i] = 0;
        ld_pending.clear();
        st_pending.clear();
        accepted_loads.clear();
        results.clear();
    }

    void pack(const Uop& u) {
        for (int i = 0; i < IN_WORDS; ++i) dut->issue_uop[i] = 0;
        set_field(dut->issue_uop, O_IMM, 32, u.imm);
        set_field(dut->issue_uop, O_DEST, PRF, u.dest);
        set_field(dut->issue_uop, O_LOAD, 1, u.is_load);
        set_field(dut->issue_uop, O_STORE, 1, u.is_store);
        set_field(dut->issue_uop, O_ILLEGAL, 1, u.illegal);
        set_field(dut->issue_uop, O_MEM_SIZE, 2, u.mem_size);
        set_field(dut->issue_uop, O_MEM_UNS, 1, u.mem_uns);
        set_field(dut->issue_uop, O_LSQ, LSQ, u.lsq);
        set_field(dut->issue_uop, O_ROB, ROB, u.rob);
    }

    bool alloc(uint32_t id, uint32_t rob, bool is_store) {
        clear_inputs();
        dut->alloc_valid = 1;
        dut->alloc_id = id;
        dut->alloc_rob = rob;
        dut->alloc_is_store = is_store ? 1 : 0;
        dut->alloc_fire = 1;
        dut->seq_base = seq_base;
        dut->eval();
        const bool ok = dut->alloc_ready;
        tick();
        if (ok) {
            seq_of_rob[rob & 31] = seq_base;
            seq_base += 1;
        }
        clear_inputs();
        return ok;
    }

    bool issue(const Uop& u, uint32_t src1, uint32_t src2) {
        clear_inputs();
        pack(u);
        dut->issue_valid = 1;
        dut->issue_src1 = src1;
        dut->issue_src2 = src2;
        dut->issue_seq = seq_of_rob[u.rob & 31];
        dut->issue_addr_only = u.addr_only;
        // A load is accepted into its reserved slot independently of memory.
        dut->ld_req_ready = load_ready;
        dut->st_req_ready = 1;
        dut->eval();
        if (!dut->issue_ready) return false;
        tick();
        clear_inputs();
        return true;
    }

    void commit(uint32_t id, bool is_store, bool is_load) {
        clear_inputs();
        dut->commit_valid = 1;
        dut->commit_id = id;
        dut->commit_is_store = is_store ? 1 : 0;
        dut->commit_is_load = is_load ? 1 : 0;
        tick();
        clear_inputs();
    }

    void squash(uint32_t boundary) {
        clear_inputs();
        dut->squash_valid = 1;
        dut->squash_rob_idx = 0;
        dut->squash_seq = boundary;
        tick();
        clear_inputs();
    }

    bool wait_store_quiet(const char* tag) {
        for (int i = 0; i < 256; ++i) {
            tick();
            if (!dut->st_req_valid && st_pending.empty()) return true;
        }
        expect(false, tag);
        return false;
    }

    bool wait_idle(const char* tag) {
        for (int i = 0; i < 256; ++i) {
            tick();
            if (!dut->busy && !dut->st_req_valid && st_pending.empty() &&
                ld_pending.empty())
                return true;
        }
        expect(false, tag);
        return false;
    }

    bool wait_load_result(uint32_t want, uint32_t want_tag, const char* tag) {
        for (int i = 0; i < 128; ++i) {
            tick();
            if (dut->load_result_valid) {
                const bool ok = (dut->load_result_value == want) &&
                                (dut->load_result_tag == want_tag) &&
                                !dut->load_result_exception;
                expect(ok, tag);
                if (!ok)
                    printf("  [%s] got=%08x tag=%u exc=%u want=%08x tag=%u\n",
                           tag, (uint32_t)dut->load_result_value,
                           (uint32_t)dut->load_result_tag,
                           (uint32_t)dut->load_result_exception, want, want_tag);
                dut->load_result_ready = 1;
                tick();
                clear_inputs();
                return ok;
            }
        }
        expect(false, "load result timeout");
        return false;
    }

    void address_case(uint32_t base, uint32_t imm, bool store) {
        // Independent arithmetic reference; observe only real LSU ports.
        const uint32_t want = uint32_t(uint64_t(base) + uint64_t(imm));
        const uint32_t data = 0x89abcdefu ^ base ^ imm;
        load_ready = store;
        store_ready = !store;
        expect(alloc(0, 1, store), "AGU alloc");
        Uop u;
        u.dest=7; u.lsq=0; u.rob=1; u.imm=imm;
        u.is_store=store; u.is_load=!store;
        if (!store) write_word(want, data, 15);
        expect(issue(u, base, data), "AGU issue");
        if (store) commit(0, true, false);
        for (int i=0; i<16 && !(store?dut->st_req_valid:dut->ld_req_valid); ++i) tick();
        expect(store?dut->st_req_valid:dut->ld_req_valid, "AGU request arrives");
        auto correct = [&]() {
            return store ? (dut->st_req_valid && dut->st_req_addr==want &&
                            dut->st_req_wdata==data && dut->st_req_wstrb==15)
                         : (dut->ld_req_valid && dut->ld_req_addr==want);
        };
        bool ok=correct();
        expect(ok, "AGU modulo-32-bit address and store payload");
        if(!ok)printf("  base=%08x imm=%08x want=%08x got=%08x store=%d\n",
                      base,imm,want,uint32_t(store?dut->st_req_addr:dut->ld_req_addr),store);
        for (int i=0; i<2; ++i) {
            // No new issue: a held request must ignore changing input operands.
            dut->issue_src1=base^0xffffffffu;
            set_field(dut->issue_uop,O_IMM,32,imm^0xaaaaaaaa);
            tick();expect(correct(), "AGU registered request stable under backpressure");
        }
        clear_inputs();load_ready=true;store_ready=true;
        if (store) {
            expect(wait_idle("AGU store timeout"), "AGU store completes");
            expect(read_word(want)==data,"AGU store writes reference address");
        } else {
            wait_load_result(data,7,"AGU load reads reference address");
            commit(0,false,true);results.clear();
        }
    }

    void expect(bool ok, const char* what) {
        ++checks;
        if (!ok) {
            ++fails;
            printf("FAIL: %s\n", what);
        }
    }
};

// A reused slot belongs to its new payload, even when enqueue and squash
// coincide. Check both the result FIFO and request-metadata FIFO externally.
void run_reused_slot_squash(Harness& h) {
    h.reset();
    h.write_word(0x1800, 0x12345678, 15);
    h.auto_respond = false;
    h.expect(h.alloc(0, 1, false), "reuse older load alloc");
    Uop older; older.dest=10; older.is_load=1; older.lsq=0; older.rob=1;
    h.expect(h.issue(older, 0x1800, 0), "reuse older load issue");
    for (int n=0; n<16 && h.ld_pending.empty(); ++n) h.tick();
    h.expect(h.ld_pending.size()==1, "reuse older response pending");
    h.seq_base=100;
    for (int n=0; n<8; ++n) {
        h.expect(h.alloc(1, 2, false), "reuse younger local alloc");
        Uop u; u.dest=20; u.is_load=1; u.lsq=1; u.rob=2; u.illegal=1;
        h.expect(h.issue(u, 0x1900, 0), "reuse younger local issue");
        h.dut->load_result_ready=1;
        for (int i=0; i<32 && int(h.results.size())<n+1; ++i) h.tick();
        h.expect(int(h.results.size())==n+1, "reuse younger local result");
        h.commit(1, false, true);
    }
    h.results.clear(); h.clear_inputs(); h.auto_respond=true;
    h.dut->squash_valid=1; h.dut->squash_seq=1; h.tick();
    h.expect(h.ld_pending.empty(), "reuse older response consumed on squash");
    h.dut->squash_valid=0; h.dut->load_result_ready=1;
    for (int n=0; n<16; ++n) h.tick();
    h.expect(h.results.size()==1 && h.results.front()==std::make_pair(10u,0x12345678u),
             "result slot reuse preserves older payload on squash");

    h.reset(); h.write_word(0x1800, 0x12345678, 15);
    h.expect(h.alloc(0, 1, false), "metadata older reserved alloc");
    h.seq_base=100;
    for (int n=0; n<8; ++n) {
        h.expect(h.alloc(1, 2, false), "metadata younger alloc");
        Uop u; u.dest=20; u.is_load=1; u.lsq=1; u.rob=2;
        h.expect(h.issue(u, 0x1900, 0), "metadata younger issue");
        h.dut->load_result_ready=1;
        for (int i=0; i<32 && int(h.results.size())<n+1; ++i) h.tick();
        h.expect(int(h.results.size())==n+1, "metadata younger result");
        h.commit(1, false, true);
    }
    h.results.clear(); h.load_ready=false;
    h.expect(h.issue(older, 0x1800, 0), "metadata older issue after younger loads");
    for (int n=0; n<16 && !h.dut->ld_req_valid; ++n) h.tick();
    h.expect(h.dut->ld_req_valid, "metadata older request waits for memory");
    h.clear_inputs(); h.load_ready=true;
    h.dut->squash_valid=1; h.dut->squash_seq=1; h.tick();
    h.expect(h.accepted_loads.size()==9, "metadata older request accepted on squash");
    h.dut->squash_valid=0; h.dut->load_result_ready=1;
    for (int n=0; n<16; ++n) h.tick();
    h.expect(h.results.size()==1 && h.results.front()==std::make_pair(10u,0x12345678u),
             "metadata slot reuse preserves older request on squash");
}

}  // namespace

int main(int argc, char** argv) {
    VerilatedContext context;
    context.threads(1);
    context.commandArgs(argc, argv);
    Vlsu dut{&context};
    Harness h;
    h.dut = &dut;
    h.reset();
    run_reused_slot_squash(h);
    h.reset();

    // ---- store: complete at issue, write only after commit ----------------
    h.expect(h.alloc(0, 1, true), "store alloc");
    Uop st;
    st.dest = 2; st.is_store = 1; st.lsq = 0; st.rob = 1;
    st.imm = 0x10; st.mem_size = WORD;
    h.expect(h.issue(st, 0x1000, 0xdeadbeef), "store issue");
    h.expect(dut.store_complete_valid, "store complete pulse");
    h.expect(dut.store_complete_tag == 2, "store complete tag");
    h.expect(!dut.st_req_valid, "store does not write before commit");
    h.tick();  // consume complete pulse
    h.commit(0, true, false);
    h.expect(h.wait_idle("store drain timeout"), "store drain idle");
    h.expect(h.read_word(0x1010) == 0xdeadbeef, "store drain data");
    h.expect(h.alloc(0, 2, true), "store id freed");

    // ---- load word -------------------------------------------------------
    h.reset();
    h.write_word(0x2000, 0x81234567, 0xf);
    h.expect(h.alloc(0, 1, false), "load alloc");
    Uop ld;
    ld.dest = 5; ld.is_load = 1; ld.lsq = 0; ld.rob = 1;
    ld.imm = 0; ld.mem_size = WORD;
    h.expect(h.issue(ld, 0x2000, 0), "load issue");
    h.expect(h.wait_load_result(0x81234567, 5, "load word"), "load word value");
    h.commit(0, false, true);
    h.expect(h.alloc(0, 2, false), "load id freed");

    // ---- load byte / half sign and zero extension ------------------------
    h.reset();
    h.write_word(0x3000, 0x00000180, 0xf);
    struct LoadCase { uint32_t size, uns, want; const char* name; };
    const LoadCase cases[] = {
        {BYTE, 0, 0xffffff80u, "LB"},
        {BYTE, 1, 0x00000080u, "LBU"},
        {HALF, 0, 0x00000180u, "LH"},
        {HALF, 1, 0x00000180u, "LHU"},
    };
    uint32_t rob = 1;
    for (const LoadCase& c : cases) {
        h.expect(h.alloc(0, rob, false), c.name);
        Uop u;
        u.dest = 7; u.is_load = 1; u.lsq = 0; u.rob = rob;
        u.imm = 0; u.mem_size = c.size; u.mem_uns = c.uns;
        h.expect(h.issue(u, 0x3000, 0), "load case issue");
        h.expect(h.wait_load_result(c.want, 7, c.name), c.name);
        h.commit(0, false, true);
        rob = (rob + 1) & 31;
    }

    // ---- multiple outstanding loads --------------------------------------
    h.reset();
    h.write_word(0x4000, 0x11111111, 0xf);
    h.write_word(0x4004, 0x22222222, 0xf);
    h.expect(h.alloc(0, 1, false), "multi load 0 alloc");
    h.expect(h.alloc(1, 2, false), "multi load 1 alloc");
    Uop l0; l0.dest = 10; l0.is_load = 1; l0.lsq = 0; l0.rob = 1;
    Uop l1; l1.dest = 11; l1.is_load = 1; l1.lsq = 1; l1.rob = 2;
    h.auto_respond = false;
    h.expect(h.issue(l0, 0x4000, 0), "multi load 0 issue");
    h.expect(h.issue(l1, 0x4004, 0), "multi load 1 issue");
    for (int i = 0; i < 8 && h.ld_pending.size() < 2; ++i) h.tick();
    h.expect(h.ld_pending.size() == 2, "two outstanding loads");
    h.auto_respond = true;
    h.expect(h.wait_load_result(0x11111111, 10, "multi load 0 result"),
             "multi load 0 value");
    h.expect(h.wait_load_result(0x22222222, 11, "multi load 1 result"),
             "multi load 1 value");
    h.commit(0, false, true);
    h.commit(1, false, true);

    // ---- full-word store-to-load forwarding ------------------------------
    h.reset();
    h.write_word(0x5000, 0x01020304, 0xf);
    h.expect(h.alloc(0, 1, true), "fwd store alloc");
    Uop fs;
    fs.dest = 2; fs.is_store = 1; fs.lsq = 0; fs.rob = 1;
    fs.mem_size = WORD;
    h.expect(h.issue(fs, 0x5000, 0xcafebabe), "fwd store issue");
    h.expect(h.alloc(1, 2, false), "fwd load alloc");
    Uop fl;
    fl.dest = 6; fl.is_load = 1; fl.lsq = 1; fl.rob = 2;
    fl.mem_size = WORD;
    h.expect(h.issue(fl, 0x5000, 0), "fwd load issue");
    h.expect(h.wait_load_result(0xcafebabe, 6, "forwarded load"),
             "forwarded value");
    h.commit(1, false, true);
    h.commit(0, true, false);
    h.expect(h.wait_idle("fwd store drain"), "fwd store drain");
    h.expect(h.read_word(0x5000) == 0xcafebabe, "forwarded store data");

    // ---- partial older store blocks until it is written ------------------
    h.reset();
    h.write_word(0x6000, 0x01020304, 0xf);
    h.expect(h.alloc(0, 1, true), "partial store alloc");
    Uop ps;
    ps.dest = 2; ps.is_store = 1; ps.lsq = 0; ps.rob = 1;
    ps.mem_size = BYTE;
    h.expect(h.issue(ps, 0x6000, 0xaa), "partial store issue");
    h.expect(h.alloc(1, 2, false), "partial load alloc");
    Uop pl;
    pl.dest = 6; pl.is_load = 1; pl.lsq = 1; pl.rob = 2;
    pl.mem_size = WORD;
    h.expect(h.issue(pl, 0x6000, 0), "blocked load accepted into waiting table");
    for (int i = 0; i < 4; ++i) {
        h.tick();
        h.expect(!dut.ld_req_valid, "blocked load not sent");
    }
    h.commit(0, true, false);
    h.expect(h.wait_store_quiet("partial store drain"), "partial store drain");
    // The waiting table owns this load; do not issue a second copy after drain.
    h.expect(h.wait_load_result(0x010203aa, 6, "partial load value"),
             "partial load value");
    h.commit(1, false, true);

    // ---- squash younger load ---------------------------------------------
    h.reset();
    h.expect(h.alloc(0, 1, true), "squash dummy store alloc");
    Uop ds;
    ds.dest = 2; ds.is_store = 1; ds.lsq = 0; ds.rob = 1;
    ds.mem_size = WORD;
    h.expect(h.issue(ds, 0x7000, 0x12345678), "squash dummy store issue");
    h.expect(h.alloc(1, 2, false), "squash load alloc");
    Uop sl;
    sl.dest = 7; sl.is_load = 1; sl.lsq = 1; sl.rob = 2;
    sl.mem_size = WORD;
    h.auto_respond = false;
    h.expect(h.issue(sl, 0x8000, 0), "squash load issue");
    for (int i = 0; i < 8 && h.ld_pending.empty(); ++i) h.tick();
    h.expect(h.ld_pending.size() == 1, "load sent before squash");
    h.squash(0);
    h.auto_respond = true;
    for (int i = 0; i < 8; ++i) {
        h.tick();
        h.expect(!dut.load_result_valid, "squashed load no result");
    }

    // ---- LSQ id backpressure ---------------------------------------------
    h.reset();
    h.expect(h.alloc(0, 1, true), "bp alloc");
    Uop bp;
    bp.is_store = 1; bp.lsq = 0; bp.rob = 1; bp.mem_size = WORD;
    h.expect(h.issue(bp, 0x9000, 0x1), "bp issue");
    h.expect(!h.alloc(0, 2, true), "duplicate lsq id rejected");

    // ---- late old load can pass younger loads blocked by an old store -----
    h.reset();
    h.write_word(0xa000, 0x11223344, 0xf);
    for (int id = 0; id < TB_LSQ_DEPTH; ++id)
        h.expect(h.alloc(id, id + 1, id == 1), "reserved waiting slot alloc");
    for (int id = 2; id < TB_LSQ_DEPTH; ++id) {
        Uop young;
        young.dest = 20 + id; young.is_load = 1; young.lsq = id; young.rob = id + 1;
        h.expect(h.issue(young, 0xb000, 0), "young blocked load enqueued");
    }
    for (int i = 0; i < 8; ++i) h.tick();
    h.expect(h.accepted_loads.empty(), "unknown store blocks all young requests");
    Uop address;
    address.dest = 11; address.is_store = 1; address.lsq = 1; address.rob = 2;
    address.addr_only = 1;
    h.expect(h.issue(address, 0xb000, 0), "store address prefill progresses");
    h.expect(!dut.store_complete_valid, "address prefill does not complete store");
    for (int i = 0; i < 4; ++i) h.tick();
    h.expect(h.accepted_loads.empty(), "prefilled store still waits for data");
    Uop late;
    late.dest = 10; late.is_load = 1; late.lsq = 0; late.rob = 1;
    h.expect(h.issue(late, 0xa000, 0), "late old load uses its reserved slot");
    h.expect(h.wait_load_result(0x11223344, 10, "late old load result"),
             "late old load progresses past blocked young requests");
    h.results.clear();
    Uop unblock;
    unblock.dest = 11; unblock.is_store = 1; unblock.lsq = 1; unblock.rob = 2;
    h.expect(h.issue(unblock, 0xb000, 0x11223344), "store can fill with blocked loads");
    bool young_seen[64] = {};
    int young_count = 0;
    for (int cycle = 0; cycle < 512 && young_count < TB_LSQ_DEPTH - 2; ++cycle) {
        dut.load_result_ready = 1;
        h.tick();
        while (!h.results.empty()) {
            const auto result = h.results.front(); h.results.pop_front();
            const bool tag_ok = result.first >= 22 && result.first < 20 + TB_LSQ_DEPTH;
            h.expect(tag_ok && result.second == 0x11223344, "young forwarded result");
            if (tag_ok) {
                h.expect(!young_seen[result.first], "young load completes once");
                if (!young_seen[result.first]) ++young_count;
                young_seen[result.first] = true;
            }
        }
    }
    h.clear_inputs();
    h.expect(young_count == TB_LSQ_DEPTH - 2, "all young loads eventually complete");
    h.expect(h.accepted_loads.size() == 1, "young loads forward without extra reads");
    h.commit(0, false, true);
    for (int id = 2; id < TB_LSQ_DEPTH; ++id) h.commit(id, false, true);
    h.commit(1, true, false);
    h.expect(h.wait_idle("late load/store drain"), "late load/store idle");

    // ---- memory backpressure holds the registered address; squash cancels --
    h.reset();
    h.seq_base = 2;
    h.expect(h.alloc(0, 1, false), "held load alloc");
    h.load_ready = false;
    Uop held; held.dest = 12; held.is_load = 1; held.lsq = 0; held.rob = 1;
    h.expect(h.issue(held, 0xd000, 0), "load accepts while memory is not ready");
    for (int i = 0; i < 8 && !dut.ld_req_valid; ++i) h.tick();
    for (int i = 0; i < 5; ++i) {
        h.expect(dut.ld_req_valid && dut.ld_req_addr == 0xd000, "request held stable");
        h.tick();
    }
    h.squash(1);
    h.load_ready = true;
    for (int i = 0; i < 8; ++i) h.tick();
    h.expect(h.accepted_loads.empty() && !dut.load_result_valid,
             "squashed stalled request has no side effect");
    h.write_word(0xd004, 0x55667788, 0xf);
    h.expect(h.alloc(0, 2, false), "squashed waiting slot can be reused");
    held.dest = 13; held.rob = 2;
    h.expect(h.issue(held, 0xd004, 0), "reused waiting slot accepts fresh load");
    h.expect(h.wait_load_result(0x55667788, 13, "reused slot value"), "fresh load result");
    h.commit(0, false, true);

    // ---- squash before pending selection ---------------------------------
    h.reset(); h.seq_base = 2;
    h.expect(h.alloc(0, 1, false), "pending squash alloc");
    held.dest = 14; held.rob = 1;
    h.expect(h.issue(held, 0xd000, 0), "pending squash enqueue");
    h.squash(1);
    for (int i = 0; i < 8; ++i) h.tick();
    h.expect(h.accepted_loads.empty() && !dut.load_result_valid,
             "pending squash prevents request and CDB result");

    // ---- illegal loads use captured tag/exception without a memory read ----
    h.reset();
    h.expect(h.alloc(0, 1, false), "illegal load alloc");
    Uop illegal;
    illegal.dest = 43; illegal.is_load = 1; illegal.illegal = 1;
    illegal.lsq = 0; illegal.rob = 1;
    h.expect(h.issue(illegal, 0xd000, 0), "illegal load enqueued");
    for (int i = 0; i < 16 && !dut.load_result_valid; ++i) h.tick();
    h.expect(dut.load_result_valid && dut.load_result_exception &&
             dut.load_result_tag == 43 && dut.load_result_value == 0,
             "illegal load carries captured metadata");
    h.expect(h.accepted_loads.empty(), "illegal load never reads memory");

    // ---- forwarding carries captured size, offset and signedness ----------
    h.reset();
    h.expect(h.alloc(0, 1, true), "format store alloc");
    fs.lsq = 0; fs.rob = 1;
    h.expect(h.issue(fs, 0xe000, 0x89abcdef), "format store fill");
    h.expect(h.alloc(1, 2, false), "format byte alloc");
    fl.dest = 44; fl.lsq = 1; fl.rob = 2; fl.mem_size = BYTE; fl.mem_uns = 0;
    h.expect(h.issue(fl, 0xe001, 0), "signed byte waiting enqueue");
    h.expect(h.wait_load_result(0xffffffcd, 44, "captured signed byte"), "signed format");
    h.commit(1, false, true);
    h.expect(h.alloc(2, 3, false), "format unsigned byte alloc");
    fl.dest = 45; fl.lsq = 2; fl.rob = 3; fl.mem_uns = 1;
    h.expect(h.issue(fl, 0xe003, 0), "unsigned byte waiting enqueue");
    h.expect(h.wait_load_result(0x89, 45, "captured unsigned byte"), "unsigned format");
    h.commit(2, false, true);
    h.commit(0, true, false);
    h.expect(h.wait_idle("format store drain"), "format idle");

    // ---- consecutive forwarding uses response-stage metadata, not next q ---
    h.reset();
    h.expect(h.alloc(0, 1, true), "mixed format store alloc");
    fs.lsq = 0; fs.rob = 1;
    h.expect(h.issue(fs, 0xe000, 0x89abcdef), "mixed format store fill");
    const uint32_t mixed_addr[] = {0xe001, 0xe003, 0xe002, 0xe000, 0xe000, 0xe002};
    const uint32_t mixed_size[] = {BYTE, BYTE, HALF, HALF, WORD, BYTE};
    const uint32_t mixed_uns[] = {0, 1, 0, 1, 0, 0};
    const uint32_t mixed_value[] = {0xffffffcd, 0x89, 0xffff89ab, 0xcdef,
                                    0x89abcdef, 0xffffffab};
    for (int id = 1; id <= 6; ++id)
        h.expect(h.alloc(id, id + 1, false), "mixed format load alloc");
    for (int id = 1; id <= 6; ++id) {
        Uop mixed;
        mixed.dest = 45 + id; mixed.lsq = id; mixed.rob = id + 1; mixed.is_load = 1;
        mixed.mem_size = mixed_size[id - 1]; mixed.mem_uns = mixed_uns[id - 1];
        h.expect(h.issue(mixed, mixed_addr[id - 1], 0), "mixed load enqueue");
    }
    bool mixed_seen[6] = {};
    int mixed_count = 0;
    for (int cycle = 0; cycle < 128 && mixed_count < 6; ++cycle) {
        dut.load_result_ready = 1;
        h.tick();
        while (!h.results.empty()) {
            const auto result = h.results.front(); h.results.pop_front();
            int id = int(result.first) - 46;
            bool ok = id >= 0 && id < 6;
            h.expect(ok && result.second == mixed_value[id], "mixed response metadata");
            if (ok) {
                h.expect(!mixed_seen[id], "mixed load completes once");
                if (!mixed_seen[id]) ++mixed_count;
                mixed_seen[id] = true;
            }
        }
    }
    h.clear_inputs();
    h.expect(mixed_count == 6 && h.accepted_loads.empty(), "mixed loads all forward");
    for (int id = 1; id <= 6; ++id) h.commit(id, false, true);
    h.commit(0, true, false);
    h.expect(h.wait_idle("mixed forwarding drain"), "mixed queues idle");

    // ---- result credits cover both in-flight requests and stalled results --
    if (TB_LSQ_DEPTH > 8) {
        h.reset();
        for (int id = 0; id < 12; ++id) {
            h.write_word(0xc000 + 4 * id, 0xa1000000u + id, 0xf);
            h.expect(h.alloc(id, id + 1, false), "credit load alloc");
        }
        for (int id = 0; id < 12; ++id) {
            Uop queued;
            queued.dest = 30 + id; queued.is_load = 1; queued.lsq = id; queued.rob = id + 1;
            h.expect(h.issue(queued, 0xc000 + 4 * id, 0), "credit load enqueue");
        }
        for (int i = 0; i < 80; ++i) h.tick();
        h.expect(h.accepted_loads.size() == 8, "eight reserved result credits cap requests");
        bool seen[12] = {};
        int received = 0;
        for (int cycle = 0; cycle < 512 && received < 12; ++cycle) {
            dut.load_result_ready = 1;
            h.tick();
            while (!h.results.empty()) {
                const auto result = h.results.front(); h.results.pop_front();
                const int id = int(result.first) - 30;
                const bool ok = id >= 0 && id < 12;
                h.expect(ok && result.second == 0xa1000000u + id, "credit result data");
                if (ok) {
                    h.expect(!seen[id], "credit result not duplicated");
                    if (!seen[id]) ++received;
                    seen[id] = true;
                }
            }
        }
        h.clear_inputs();
        h.expect(received == 12 && h.accepted_loads.size() == 12, "all reserved loads drain");
        for (int id = 0; id < 12; ++id) h.commit(id, false, true);
        h.expect(h.wait_idle("credit drain"), "credit queues idle");
    }

    // ---- queued arbitration: physical slot order differs from seq order ---
    // Hold r at memory and q behind it, then enqueue all remaining ages in
    // reverse order. Selection must exclude q/r and drain the table by seq.
    for (int round = 0; round < 3; ++round) {
        h.reset();
        h.seq_base = 0x90000000u + 100 * round;
        const uint32_t first_seq = h.seq_base;
        const int keep = (round == 1) ? TB_LSQ_DEPTH / 2 : TB_LSQ_DEPTH;
        for (int age = 0; age < TB_LSQ_DEPTH; ++age) {
            const int id = (5 * age + 3) % TB_LSQ_DEPTH;
            if (round == 2) h.seq_base = first_seq; // equal seq: low id wins
            h.write_word(0xf000 + 4 * id, 0xb2000000u + id, 0xf);
            h.expect(h.alloc(id, age + 1, false), "tree arbitration alloc");
        }
        h.load_ready = false;
        auto enqueue_age = [&](int age) {
            const int id = (5 * age + 3) % TB_LSQ_DEPTH;
            Uop queued;
            queued.dest = 16 + id; queued.is_load = 1; queued.lsq = id; queued.rob = age + 1;
            h.expect(h.issue(queued, 0xf000 + 4 * id, 0), "tree arbitration enqueue");
        };
        enqueue_age(0);
        for (int i = 0; i < 8; ++i) h.tick();
        enqueue_age(1);
        for (int i = 0; i < 8; ++i) h.tick();
        for (int age = TB_LSQ_DEPTH - 1; age >= 2; --age) enqueue_age(age);
        if (round == 1) h.squash(first_seq + keep - 1);
        for (int i = 0; i < 4; ++i) h.tick();
        h.expect(h.accepted_loads.empty(), "tree requests wait for memory ready");
        bool seen[TB_LSQ_DEPTH] = {};
        int received = 0;
        h.load_ready = true;
        for (int cycle = 0; cycle < 512 && received < keep; ++cycle) {
            dut.load_result_ready = 1;
            h.tick();
            while (!h.results.empty()) {
                const auto result = h.results.front(); h.results.pop_front();
                const int id = int(result.first) - 16;
                const bool valid_id = id >= 0 && id < TB_LSQ_DEPTH;
                h.expect(valid_id && result.second == 0xb2000000u + id,
                         "tree result retains tag and data");
                if (valid_id) {
                    h.expect(!seen[id], "tree load completes once");
                    if (!seen[id]) ++received;
                    seen[id] = true;
                }
            }
        }
        for (int i = 0; i < 16; ++i) h.tick();
        h.expect(received == keep && h.accepted_loads.size() == size_t(keep),
                 "tree request count after squash and q/r exclusion");
        std::vector<int> expected_ids;
        expected_ids.push_back(3);
        expected_ids.push_back(8 % TB_LSQ_DEPTH);
        if (round == 2) {
            for (int id = 0; id < TB_LSQ_DEPTH; ++id)
                if (id != expected_ids[0] && id != expected_ids[1]) expected_ids.push_back(id);
        } else {
            for (int age = 2; age < keep; ++age) expected_ids.push_back((5 * age + 3) % TB_LSQ_DEPTH);
        }
        for (int pos = 0; pos < keep; ++pos)
            h.expect(h.accepted_loads.size() > size_t(pos) &&
                     h.accepted_loads[pos] == 0xf000u + 4 * expected_ids[pos],
                     "tree chooses oldest seq then lowest physical id");
        h.expect(h.results.empty(), "tree has no duplicate trailing result");
        h.clear_inputs();
        for (int id : expected_ids) h.commit(id, false, true);
        h.expect(h.wait_idle("tree arbitration drain"), "tree arbitration idle");
    }

    // ---- address carry boundaries, wraparound and arbitrary immediates -----
    h.reset();
    std::vector<std::pair<uint32_t,uint32_t>> addresses = {
        {0,0},{0xffffffffu,1},{1,0xffffffffu},{0x80000000u,0x80000000u},
        {0x7fffffffu,1},{0,0xffffffffu},{0xffffffffu,0xffffffffu},
    };
    for(unsigned bit=1;bit<=32;++bit) {
        uint32_t mask=uint32_t((uint64_t(1)<<bit)-1);
        addresses.push_back({mask,1});addresses.push_back({1,mask});
        addresses.push_back({~mask,mask});addresses.push_back({~mask,1});
    }
    std::mt19937 random(0x20261024);
    for(int i=0;i<4096;++i) {
        uint32_t a=random(),b=random();
        if(i%4==0) { // sign-extended 12-bit offsets without signed shifts
            b &= 0xfff;
            if(b&0x800)b |= 0xfffff000u;
        }
        addresses.push_back({a,b});
    }
    for(const auto& pair:addresses) {
        h.address_case(pair.first,pair.second,false);
        h.address_case(pair.first,pair.second,true);
    }
    printf("AGU reference: %zu operand pairs, load/store ports, two stalled cycles each\n",
           addresses.size());

    // ---- reset -----------------------------------------------------------
    h.reset();
    h.expect(!dut.load_result_valid, "reset load result");
    h.expect(!dut.store_complete_valid, "reset store complete");
    h.expect(!dut.ld_req_valid, "reset ld request");
    h.expect(!dut.st_req_valid, "reset st request");

    printf("\nLSQ=%d checked=%ld fails=%ld\n", TB_LSQ_DEPTH, h.checks, h.fails);
    const bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}

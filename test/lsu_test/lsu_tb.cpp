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

namespace {

constexpr int PRF = 6;
constexpr int LSQ = 3;
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
    O_LSQ = 142, O_ROB = 145,
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
    long checks = 0;
    long fails = 0;
    uint32_t seq_base = 0;
    uint32_t seq_of_rob[32] = {};

    // Requests accepted by the memory model, waiting for a response.
    std::deque<uint32_t> ld_pending;
    std::deque<uint8_t>  st_pending;

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
        dut->ld_req_ready = 1;
        dut->st_req_ready = 1;
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

        dut->clk = 1;
        dut->eval();

        if (ld_fire) ld_pending.push_back(ld_addr);
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
        dut->reset = 1;
        clear_inputs();
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        tick();
        seq_base = 0;
        for (int i = 0; i < 32; ++i) seq_of_rob[i] = 0;
        ld_pending.clear();
        st_pending.clear();
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
        // issue_ready for loads depends on ld_req_ready.
        dut->ld_req_ready = 1;
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

    void expect(bool ok, const char* what) {
        ++checks;
        if (!ok) {
            ++fails;
            printf("FAIL: %s\n", what);
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vlsu dut;
    Harness h;
    h.dut = &dut;
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
    h.expect(!h.issue(pl, 0x6000, 0), "partial store blocks load");
    for (int i = 0; i < 4; ++i) {
        h.tick();
        h.expect(!dut.ld_req_valid, "blocked load not sent");
    }
    h.commit(0, true, false);
    h.expect(h.wait_store_quiet("partial store drain"), "partial store drain");
    h.expect(h.issue(pl, 0x6000, 0), "load after partial store");
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
    h.tick();
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

    // ---- reset -----------------------------------------------------------
    h.reset();
    h.expect(!dut.load_result_valid, "reset load result");
    h.expect(!dut.store_complete_valid, "reset store complete");
    h.expect(!dut.ld_req_valid, "reset ld request");
    h.expect(!dut.st_req_valid, "reset st request");

    printf("\nchecked=%ld fails=%ld\n", h.checks, h.fails);
    const bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}

// -----------------------------------------------------------------------------
// backend_tb.cpp — full backend smoke/integration test.
//
// Drives the frozen dispatch/commit/squash buses and observes cdb/complete/
// br_update.  Covers ALU chain, load/store, branch/JAL, squash, IQ full
// backpressure, and W=2 dispatch absorption (IW stays 1 in P1).
// -----------------------------------------------------------------------------

#include "Vbackend_ooo.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <utility>

#ifndef TB_W
#define TB_W 1
#endif

namespace {

constexpr int W = TB_W;
constexpr int IW = 2;
constexpr int R = 2;
constexpr int PRF = 6;
constexpr int CDB_W = 34 + PRF;
constexpr int LSQ = 3;
constexpr int ROB = 5;
constexpr int DW = 124 + 3 * PRF + LSQ + ROB;
constexpr int DISP_WORDS = (W * DW + 31) / 32;
constexpr int BR_WORDS = (73 + 31) / 32;

constexpr uint32_t A_REG = 0, A_PC = 1, A_ZERO = 2;
constexpr uint32_t B_REG = 0, B_IMM = 1;
constexpr uint32_t WB_ALU = 0, WB_MEM = 1, WB_PC4 = 2;
constexpr uint32_t ALU_ADD = 0, ALU_SUB = 1;
constexpr uint32_t ALU_DIV = 14, ALU_DIVU = 15, ALU_REM = 16, ALU_REMU = 17;

constexpr int C_VALID = 0, C_TAG = 1, C_VALUE = 1 + PRF,
              C_STORE = 1 + PRF, C_LOAD = 2 + PRF, C_LSQ = 3 + PRF;
constexpr int S_VALID = 0, S_ROB = 1;
constexpr int B_VALID = 0, B_PC = 1, B_TAKEN = 33, B_TARGET = 34,
              B_JALR = 66, B_TAG = 67;

enum : int {
    O_VALID = 0, O_PC = 1, O_INST = 33, O_IMM = 65, O_RD = 97,
    O_REG_WE = 102, O_ALU = 103, O_A_SEL = 108, O_B_SEL = 110,
    O_WB = 111, O_BR = 113, O_JAL = 114, O_JALR = 115, O_LOAD = 116,
    O_STORE = 117, O_ILLEGAL = 118, O_MEM_SIZE = 119, O_MEM_UNS = 121,
    O_DEST = 122, O_S1 = 128, O_S1R = 134, O_S2 = 135, O_S2R = 141,
    O_LSQ = 142, O_ROB = 145,
};

struct Uop {
    uint32_t pc = 0;
    uint32_t inst = 0;
    uint32_t imm = 0;
    uint32_t rd = 0;
    uint32_t reg_we = 0;
    uint32_t alu = ALU_ADD;
    uint32_t a_sel = A_REG;
    uint32_t b_sel = B_REG;
    uint32_t wb_sel = WB_ALU;
    uint32_t is_branch = 0;
    uint32_t is_jal = 0;
    uint32_t is_jalr = 0;
    uint32_t is_load = 0;
    uint32_t is_store = 0;
    uint32_t illegal = 0;
    uint32_t mem_size = 2;
    uint32_t mem_uns = 0;
    uint32_t dest = 0;
    uint32_t src1 = 0;
    uint32_t src1_ready = 1;
    uint32_t src2 = 0;
    uint32_t src2_ready = 1;
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

template <typename T>
void set_int(T& vec, int offset, int width, uint32_t value) {
    uint32_t mask = (width >= 32) ? 0xffffffffu : ((1u << width) - 1u);
    uint32_t all = (uint32_t)vec;
    all = (all & ~(mask << offset)) | ((value & mask) << offset);
    vec = (T)all;
}

template <typename Vec>
uint32_t get_field(const Vec& vec, int offset, int width) {
    uint32_t value = 0;
    for (int b = 0; b < width; ++b) {
        int bit = offset + b;
        int word = bit / 32;
        int shift = bit % 32;
        value |= ((vec[word] >> shift) & 1u) << b;
    }
    return value;
}

struct Harness {
    Vbackend_ooo* dut = nullptr;
    uint8_t mem[1 << 16] = {};
    bool auto_respond = true;
    long checks = 0;
    long fails = 0;
    bool br_seen = false;
    uint32_t br_tag_seen = 0, br_taken_seen = 0, br_target_seen = 0;
    uint32_t last_complete_tag = 0;
    std::deque<uint32_t> ld_pending;
    std::deque<uint8_t>  st_pending;
    std::deque<std::pair<uint32_t, uint32_t>> cdb_q;
    std::deque<uint32_t> complete_q;

    void capture_events() {
        for (int lane = 0; lane < R; ++lane) {
            if (get_field(dut->cdb, lane * CDB_W + C_VALID, 1)) {
                const uint32_t tag = get_field(dut->cdb, lane * CDB_W + C_TAG, PRF);
                const uint32_t value = get_field(dut->cdb, lane * CDB_W + C_VALUE, 32);
                cdb_q.push_back({tag, value});
            }
        }
        const uint32_t comp = (uint32_t)dut->complete;
        if (comp & 1) {
            last_complete_tag = (comp >> 1) & 0x3f;
            complete_q.push_back(last_complete_tag);
        }
        if (get_field(dut->br_update, B_VALID, 1)) {
            br_seen = true;
            br_tag_seen = get_field(dut->br_update, B_TAG, PRF);
            br_taken_seen = get_field(dut->br_update, B_TAKEN, 1);
            br_target_seen = get_field(dut->br_update, B_TARGET, 32);
        }
    }

    void tick() {
        dut->clk = 0;
        dut->eval();

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
        const uint8_t st_strb = (uint8_t)dut->st_req_wstrb;

        dut->clk = 1;
        dut->eval();
        capture_events();

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

    uint32_t read_word(uint32_t addr) {
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

    void clear_dispatch() {
        for (int i = 0; i < DISP_WORDS; ++i) dut->dispatch[i] = 0;
    }

    void clear_commit() { dut->commit = 0; }
    void clear_squash() { dut->squash = 0; }

    void reset() {
        dut->reset = 1;
        clear_dispatch();
        clear_commit();
        clear_squash();
        dut->ld_req_ready = 0;
        dut->st_req_ready = 0;
        dut->ld_resp_valid = 0;
        dut->st_resp_valid = 0;
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        tick();
        ld_pending.clear();
        st_pending.clear();
        cdb_q.clear();
        complete_q.clear();
        br_seen = false;
        last_complete_tag = 0;
    }

    void pack(int lane, const Uop& u) {
        int base = lane * DW;
        set_field(dut->dispatch, base + O_VALID, 1, 1);
        set_field(dut->dispatch, base + O_PC, 32, u.pc);
        set_field(dut->dispatch, base + O_INST, 32, u.inst);
        set_field(dut->dispatch, base + O_IMM, 32, u.imm);
        set_field(dut->dispatch, base + O_RD, 5, u.rd);
        set_field(dut->dispatch, base + O_REG_WE, 1, u.reg_we);
        set_field(dut->dispatch, base + O_ALU, 5, u.alu);
        set_field(dut->dispatch, base + O_A_SEL, 2, u.a_sel);
        set_field(dut->dispatch, base + O_B_SEL, 1, u.b_sel);
        set_field(dut->dispatch, base + O_WB, 2, u.wb_sel);
        set_field(dut->dispatch, base + O_BR, 1, u.is_branch);
        set_field(dut->dispatch, base + O_JAL, 1, u.is_jal);
        set_field(dut->dispatch, base + O_JALR, 1, u.is_jalr);
        set_field(dut->dispatch, base + O_LOAD, 1, u.is_load);
        set_field(dut->dispatch, base + O_STORE, 1, u.is_store);
        set_field(dut->dispatch, base + O_ILLEGAL, 1, u.illegal);
        set_field(dut->dispatch, base + O_MEM_SIZE, 2, u.mem_size);
        set_field(dut->dispatch, base + O_MEM_UNS, 1, u.mem_uns);
        set_field(dut->dispatch, base + O_DEST, PRF, u.dest);
        set_field(dut->dispatch, base + O_S1, PRF, u.src1);
        set_field(dut->dispatch, base + O_S1R, 1, u.src1_ready);
        set_field(dut->dispatch, base + O_S2, PRF, u.src2);
        set_field(dut->dispatch, base + O_S2R, 1, u.src2_ready);
        set_field(dut->dispatch, base + O_LSQ, LSQ, u.lsq);
        set_field(dut->dispatch, base + O_ROB, ROB, u.rob);
    }

    bool dispatch_one(const Uop& u) {
        clear_dispatch();
        pack(0, u);
        dut->eval();
        if (!dut->backend_ready) return false;
        tick();
        clear_dispatch();
        return true;
    }

    bool dispatch_group(const Uop* u) {
        clear_dispatch();
        for (int lane = 0; lane < W; ++lane) pack(lane, u[lane]);
        dut->eval();
        if (!dut->backend_ready) return false;
        tick();
        clear_dispatch();
        return true;
    }

    void commit_one(uint32_t lsq, bool is_store, bool is_load) {
        clear_commit();
        set_int(dut->commit, C_VALID, 1, 1);
        set_int(dut->commit, C_TAG, PRF, 0);
        set_int(dut->commit, C_STORE, 1, is_store);
        set_int(dut->commit, C_LOAD, 1, is_load);
        set_int(dut->commit, C_LSQ, LSQ, lsq);
        tick();
        clear_commit();
    }

    void squash_one(uint32_t rob) {
        set_int(dut->squash, S_VALID, 1, 1);
        set_int(dut->squash, S_ROB, ROB, rob);
        tick();
        clear_squash();
    }

    bool wait_cdb(uint32_t& tag, uint32_t& value, int limit = 128) {
        for (int n = 0; n < limit; ++n) {
            if (!cdb_q.empty()) {
                tag = cdb_q.front().first;
                value = cdb_q.front().second;
                cdb_q.pop_front();
                return true;
            }
            tick();
        }
        if (!cdb_q.empty()) {
            tag = cdb_q.front().first;
            value = cdb_q.front().second;
            cdb_q.pop_front();
            return true;
        }
        return false;
    }

    bool wait_complete_and_branch(uint32_t& ctag, uint32_t& btag,
                                  uint32_t& taken, uint32_t& target,
                                  int limit = 128) {
        for (int n = 0; n < limit; ++n) {
            if (br_seen && !complete_q.empty()) {
                ctag = complete_q.front();
                complete_q.pop_front();
                btag = br_tag_seen;
                taken = br_taken_seen;
                target = br_target_seen;
                return true;
            }
            tick();
        }
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
    VerilatedContext context;
    context.threads(1);
    context.commandArgs(argc, argv);
    Vbackend_ooo dut{&context};
    Harness h;
    h.dut = &dut;
    h.reset();
    h.expect(dut.backend_ready, "reset backend_ready");

    // ---- ALU: addi x1, x0, 5 ---------------------------------------------
    Uop addi;
    addi.pc = 0x100;
    addi.inst = 0x00500093;  // addi x1, x0, 5
    addi.imm = 5;
    addi.rd = 1; addi.reg_we = 1; addi.dest = 1;
    addi.a_sel = A_REG; addi.b_sel = B_IMM; addi.wb_sel = WB_ALU;
    addi.rob = 1;
    h.expect(h.dispatch_one(addi), "addi dispatch");
    uint32_t tag = 0, value = 0;
    h.expect(h.wait_cdb(tag, value), "addi cdb");
    h.expect(tag == 1 && value == 5, "addi result");

    // ---- dependent add x2, x1, x1 ----------------------------------------
    Uop add;
    add.pc = 0x104;
    add.inst = 0x00108133;  // add x2, x1, x1
    add.rd = 2; add.reg_we = 1; add.dest = 2;
    add.src1 = 1; add.src1_ready = 1;
    add.src2 = 1; add.src2_ready = 1;
    add.a_sel = A_REG; add.b_sel = B_REG; add.wb_sel = WB_ALU;
    add.rob = 2;
    h.expect(h.dispatch_one(add), "add dispatch");
    h.expect(h.wait_cdb(tag, value), "add cdb");
    h.expect(tag == 2 && value == 10, "add result");

    // ---- divider: div x4, x2, x1 = 10 / 5 = 2 ----------------------------
    Uop divu;
    divu.pc = 0x106;
    divu.inst = 0x02114233;  // div x4, x2, x1
    divu.rd = 4; divu.reg_we = 1; divu.dest = 4;
    divu.alu = 14;  // ALU_DIV
    divu.src1 = 2; divu.src1_ready = 1;
    divu.src2 = 1; divu.src2_ready = 1;
    divu.a_sel = A_REG; divu.b_sel = B_REG; divu.wb_sel = WB_ALU;
    divu.rob = 3;
    h.expect(h.dispatch_one(divu), "div dispatch");
    h.expect(h.wait_cdb(tag, value), "div cdb");
    h.expect(tag == 4 && value == 2, "div result");

    // ---- load word --------------------------------------------------------
    h.write_word(0x2000, 0xdeadbeef, 0xf);
    Uop ld;
    ld.pc = 0x108;
    ld.inst = 0x00002083;  // lw x1, 0(x0)
    ld.imm = 0x2000; ld.rd = 3; ld.reg_we = 1; ld.dest = 3;
    ld.is_load = 1; ld.wb_sel = WB_MEM; ld.mem_size = 2;
    ld.a_sel = A_REG; ld.b_sel = B_IMM; ld.lsq = 0; ld.rob = 3;
    h.expect(h.dispatch_one(ld), "load dispatch");
    h.expect(h.wait_cdb(tag, value), "load cdb");
    h.expect(tag == 3 && value == 0xdeadbeef, "load result");
    h.commit_one(0, false, true);

    // ---- store x1 (value 5) to 0x3000 ------------------------------------
    Uop st;
    st.pc = 0x10c;
    st.inst = 0x00102023;  // sw x1, 0(x0)
    st.imm = 0x3000; st.is_store = 1; st.mem_size = 2;
    st.src1 = 0; st.src1_ready = 1;
    st.src2 = 1; st.src2_ready = 1;
    st.a_sel = A_REG; st.b_sel = B_IMM; st.lsq = 1; st.rob = 4;
    h.expect(h.dispatch_one(st), "store dispatch");
    // Wait for store complete (complete bus lane 0).
    bool saw_complete = false;
    for (int n = 0; n < 8 && !saw_complete; ++n) {
        h.tick();
        if ((uint32_t)dut.complete & 1) saw_complete = true;
    }
    h.expect(saw_complete, "store complete");
    h.commit_one(1, true, false);
    for (int n = 0; n < 16; ++n) h.tick();
    h.expect(h.read_word(0x3000) == 5, "store write data");

    // ---- taken branch: beq x0, x0, +0x20 ---------------------------------
    Uop br;
    br.pc = 0x400;
    br.inst = 0x00000063;  // beq x0, x0, 0x20
    br.imm = 0x20; br.is_branch = 1; br.dest = 7; br.rob = 5;
    br.src1 = 0; br.src1_ready = 1; br.src2 = 0; br.src2_ready = 1;
    h.complete_q.clear();
    h.br_seen = false;
    h.expect(h.dispatch_one(br), "branch dispatch");
    uint32_t ctag = 0, btag = 0, taken = 0, target = 0;
    h.expect(h.wait_complete_and_branch(ctag, btag, taken, target), "branch event");
    h.expect(ctag == 7, "branch complete tag");
    h.expect(btag == 7 && taken == 1 && target == 0x420, "branch update");

    // ---- JAL x8, +0x40 ---------------------------------------------------
    Uop jal;
    jal.pc = 0x500;
    jal.inst = 0x0400046f;  // jal x8, 0x40
    jal.imm = 0x40; jal.is_jal = 1; jal.reg_we = 1; jal.dest = 8;
    jal.wb_sel = WB_PC4; jal.rob = 6;
    h.expect(h.dispatch_one(jal), "jal dispatch");
    h.br_seen = false;
    h.expect(h.wait_cdb(tag, value), "jal cdb");
    h.expect(tag == 8 && value == 0x504, "jal link value");
    h.expect(h.br_seen && h.br_tag_seen == 8 && h.br_taken_seen == 1 &&
             h.br_target_seen == 0x540, "jal target");

    // ---- squash younger entry --------------------------------------------
    h.reset();
    Uop sq1; sq1.pc = 0x600; sq1.dest = 9; sq1.rob = 1; sq1.reg_we = 1;
    Uop sq2; sq2.pc = 0x604; sq2.dest = 10; sq2.rob = 2; sq2.reg_we = 1;
    sq2.src1 = 20; sq2.src1_ready = 0;  // keep it in IQ/skid until squash
    if (W == 1) {
        h.expect(h.dispatch_one(sq1), "squash first dispatch");
        h.expect(h.dispatch_one(sq2), "squash second dispatch");
    } else {
        Uop pair[2] = {sq1, sq2};
        h.expect(h.dispatch_group(pair), "squash pair dispatch");
    }
    h.squash_one(1);
    bool saw_q2 = false;
    for (int n = 0; n < 16; ++n) {
        h.tick();
        while (!h.cdb_q.empty()) {
            if (h.cdb_q.front().first == 10) saw_q2 = true;
            h.cdb_q.pop_front();
        }
    }
    h.expect(!saw_q2, "squash drops younger result");

    // ---- IQ full backpressure --------------------------------------------
    h.reset();
    Uop block;
    block.pc = 0x700; block.dest = 11; block.rob = 1; block.reg_we = 1;
    block.src1 = 20; block.src1_ready = 0;  // never woken
    int accepted = 0;
    for (int n = 0; n < 24 && dut.backend_ready; ++n) {
        if (h.dispatch_one(block)) ++accepted;
        else h.tick();
        block.rob = (block.rob + 1) & 31;
    }
    h.expect(accepted >= 8, "filled issue queue + skid");
    h.expect(!dut.backend_ready, "backend_ready low with IQ+skid full");

    // ---- two-slot dispatch: full queue wake preservation and recovery -----
    for (int kill = 0; kill < 2; ++kill) {
        h.auto_respond = true;
        h.reset();
        h.auto_respond = false;
        h.write_word(0x7100, 100, 15);
        Uop producer;
        producer.pc=0x900; producer.dest=40; producer.rob=1; producer.reg_we=1;
        producer.is_load=1; producer.wb_sel=WB_MEM;
        producer.imm=0x7100; producer.lsq=0;
        h.expect(h.dispatch_one(producer), "buffer wake producer accepted");
        for (int n=0; n<24 && h.ld_pending.empty(); ++n) h.tick();
        h.expect(h.ld_pending.size()==1, "buffer wake producer waiting for memory");
        constexpr int queued=8+2*W;
        for (int base=0; base<queued; base+=W) {
            Uop group[W];
            for (int lane=0; lane<W; ++lane) {
                int n=base+lane;
                group[lane].pc=0x904+4*n; group[lane].dest=10+n;
                group[lane].rob=2+n; group[lane].reg_we=1;
                group[lane].src1=40; group[lane].src1_ready=0;
                group[lane].b_sel=B_IMM; group[lane].imm=n;
                if (n & 1) {
                    group[lane].pc=n; group[lane].a_sel=A_PC;
                    group[lane].src1=0; group[lane].src1_ready=1;
                    group[lane].src2=40; group[lane].src2_ready=0;
                    group[lane].b_sel=B_REG;
                }
            }
            h.expect(h.dispatch_group(group), "IQ and both dispatch slots accept exact capacity");
        }
        h.expect(!dut.backend_ready, "two full dispatch slots apply backpressure");
        Uop overflow;
        overflow.dest=35; overflow.rob=20; overflow.reg_we=1;
        h.expect(!h.dispatch_one(overflow), "full buffer rejects extra dispatch");
        h.clear_dispatch();
        if (kill) {
            h.squash_one(1);
            h.expect(dut.backend_ready, "squash frees both pending dispatch slots");
            Uop fresh;
            fresh.dest=55; fresh.rob=21; fresh.reg_we=1; fresh.b_sel=B_IMM; fresh.imm=7;
            h.expect(h.dispatch_one(fresh), "post-squash dispatch accepted");
        }
        h.auto_respond=true;
        bool seen[queued] = {};
        int received=0;
        bool producer_seen=false, fresh_seen=false;
        for (int cycle=0; cycle<512; ++cycle) {
            h.tick();
            while (!h.cdb_q.empty()) {
                auto result=h.cdb_q.front(); h.cdb_q.pop_front();
                if (result.first==40) {
                    h.expect(!producer_seen && result.second==100, "producer returns once");
                    producer_seen=true;
                } else if (kill) {
                    h.expect(result.first==55 && result.second==7 && !fresh_seen,
                             "squashed head and tail never produce results");
                    fresh_seen=true;
                } else {
                    int n=int(result.first)-10;
                    bool ok=n>=0 && n<queued;
                    h.expect(ok && result.second==100u+n, "queued dependency has saved wake and data");
                    if (ok) {
                        h.expect(!seen[n], "accepted dispatch completes once");
                        if (!seen[n]) ++received;
                        seen[n]=true;
                    }
                }
            }
        }
        h.expect(producer_seen && (kill?fresh_seen:received==queued),
                 "all retained owners complete after full-buffer stall");
        h.expect(dut.backend_ready, "dispatch buffer recovers after drain");
    }

    // ---- seq follows each buffered group across stalls and squash gaps ----
    h.auto_respond=true;h.reset();h.auto_respond=false;
    h.write_word(0x7200,100,15);
    Uop age_producer;
    age_producer.dest=40;age_producer.rob=1;age_producer.reg_we=1;
    age_producer.is_load=1;age_producer.wb_sel=WB_MEM;age_producer.imm=0x7200;
    h.expect(h.dispatch_one(age_producer), "age producer accepted");
    for(int i=0;i<32 && h.ld_pending.empty();++i)h.tick();
    h.expect(h.ld_pending.size()==1, "age producer waits for response");
    auto age_uop = [&](int n) {
        Uop u;u.dest=10+n;u.rob=2+n;u.reg_we=1;u.b_sel=B_IMM;u.imm=n;
        u.src1=(n<8+W)?40:63;u.src1_ready=0;return u;
    };
    for(int n=0;n<8;++n)h.expect(h.dispatch_one(age_uop(n)), "mixed single-lane groups accepted");
    for(int base=8;base<8+2*W;base+=W) {
        Uop group[W];for(int l=0;l<W;++l)group[l]=age_uop(base+l);
        h.expect(h.dispatch_group(group), "buffered age group accepted");
    }
    h.expect(!dut.backend_ready, "age test fills both dispatch slots");
    bool age_seen[8+W]={};bool boundary_seen=false,age_prod_seen=false,fresh_age_seen=false;
    auto age_results = [&]() {
        while(!h.cdb_q.empty()) {
            auto r=h.cdb_q.front();h.cdb_q.pop_front();
            if(r.first==40) {h.expect(!age_prod_seen && r.second==100,"age producer completes once");age_prod_seen=true;}
            else if(r.first==63) {h.expect(!fresh_age_seen && r.second==7,"post-squash producer completes once");fresh_age_seen=true;}
            else {
                int n=int(r.first)-10;bool ok=n>=0 && n<8+W;
                h.expect(ok && r.second==100u+n,"only pre-boundary owners complete");
                if(ok){h.expect(!age_seen[n],"retained owner completes once");age_seen[n]=true;}
                if(r.first==17+W)boundary_seen=true;
            }
        }
    };
    h.auto_respond=true;
    for(int i=0;i<256 && !boundary_seen;++i){h.tick();age_results();}
    h.expect(boundary_seen,"head-group boundary reached execution");
    h.squash_one(9+W);
    Uop fresh_age;fresh_age.dest=63;fresh_age.rob=30;fresh_age.reg_we=1;
    fresh_age.a_sel=A_ZERO;fresh_age.b_sel=B_IMM;fresh_age.imm=7;
    h.expect(h.dispatch_one(fresh_age),"dispatch accepted after discarded sequence gap");
    for(int i=0;i<256;++i){h.tick();age_results();}
    bool all_age=true;for(bool seen:age_seen)all_age &= seen;
    h.expect(all_age && age_prod_seen && fresh_age_seen,"saved group ages preserve exact squash boundary");
    h.expect(dut.backend_ready,"age buffer fully recovers");

    // ---- mixed group sizes, partial-group squash, and queued younger group -
    for (int cut=0;cut<W;++cut) {
        h.auto_respond=true;h.reset();h.auto_respond=false;
        h.write_word(0x7400,100,15);
        Uop producer;
        producer.dest=40;producer.rob=1;producer.reg_we=1;
        producer.is_load=1;producer.wb_sel=WB_MEM;producer.imm=0x7400;
        h.expect(h.dispatch_one(producer),"partial-boundary producer accepted");
        for(int i=0;i<32 && h.ld_pending.empty();++i)h.tick();
        h.expect(h.ld_pending.size()==1,"partial-boundary producer held");
        for(int base=0;base<8;) {
            int count=(W==2 && base%3!=0 && base+1<8)?2:1;
            Uop group[W];
            for(int lane=0;lane<count;++lane) {
                int n=base+lane;
                group[lane].dest=10+n;group[lane].rob=2+n;group[lane].reg_we=1;
                group[lane].src1=40;group[lane].src1_ready=0;
                group[lane].b_sel=B_IMM;group[lane].imm=n;
            }
            h.expect(count==1?h.dispatch_one(group[0]):h.dispatch_group(group),
                     "mixed-width older group accepted");
            base+=count;
        }
        Uop boundary[W],younger[W];
        for(int lane=0;lane<W;++lane) {
            boundary[lane].dest=50+lane;boundary[lane].rob=10+lane;
            boundary[lane].reg_we=1;boundary[lane].b_sel=B_IMM;
            boundary[lane].imm=20+lane;boundary[lane].src1=(lane<=cut)?40:63;
            boundary[lane].src1_ready=0;
            younger[lane].dest=52+lane;younger[lane].rob=10+W+lane;
            younger[lane].reg_we=1;younger[lane].b_sel=B_IMM;
            younger[lane].imm=30+lane;younger[lane].src1=63;younger[lane].src1_ready=0;
        }
        h.expect(h.dispatch_group(boundary),"boundary group buffered");
        h.expect(h.dispatch_group(younger),"younger group buffered behind boundary");
        h.expect(!dut.backend_ready,"partial-boundary test fills both slots");
        bool seen[8]={},kept[W]={},boundary_seen=false,producer_seen=false,fresh_seen=false;
        auto capture = [&]() {
            while(!h.cdb_q.empty()) {
                auto r=h.cdb_q.front();h.cdb_q.pop_front();
                if(r.first==40) {
                    h.expect(!producer_seen && r.second==100,"partial-boundary producer returns once");
                    producer_seen=true;
                } else if(r.first==63) {
                    h.expect(!fresh_seen && r.second==7,"fresh producer returns once");fresh_seen=true;
                } else if(r.first>=10 && r.first<18) {
                    int n=int(r.first)-10;
                    h.expect(!seen[n] && r.second==100u+n,"all older owners retained once");seen[n]=true;
                } else if(r.first>=50 && r.first<50+W) {
                    int lane=int(r.first)-50;
                    h.expect(lane<=cut && !kept[lane] && r.second==120u+lane,
                             "squash retains exactly the boundary prefix");
                    kept[lane]=true;if(lane==cut)boundary_seen=true;
                } else h.expect(false,"younger buffered group must not complete");
            }
        };
        h.auto_respond=true;
        for(int i=0;i<256 && !boundary_seen;++i){h.tick();capture();}
        h.expect(boundary_seen,"selected partial-group boundary executes");
        h.squash_one(10+cut);
        Uop fresh;fresh.dest=63;fresh.rob=30;fresh.reg_we=1;
        fresh.a_sel=A_ZERO;fresh.b_sel=B_IMM;fresh.imm=7;
        h.expect(h.dispatch_one(fresh),"fresh group accepted after partial squash");
        for(int i=0;i<128;++i){h.tick();capture();}
        bool correct=producer_seen && fresh_seen && dut.backend_ready;
        for(bool v:seen)correct &= v;
        for(int lane=0;lane<W;++lane)correct &= kept[lane]==(lane<=cut);
        h.expect(correct,"group ages preserve order across width changes and recovery");
    }

    // ---- W=2 dispatch absorption -----------------------------------------
    if (W == 2) {
        h.reset();
        Uop w2[2];
        w2[0].pc = 0x800; w2[0].dest = 12; w2[0].rob = 1; w2[0].reg_we = 1;
        w2[1].pc = 0x804; w2[1].dest = 13; w2[1].rob = 2; w2[1].reg_we = 1;
        w2[1].imm = 7; w2[1].b_sel = B_IMM;
        h.expect(h.dispatch_group(w2), "W=2 dispatch");
        bool got12 = false, got13 = false;
        uint32_t val12 = 0, val13 = 0;
        for (int n = 0; n < 2; ++n) {
            h.expect(h.wait_cdb(tag, value), "W=2 cdb");
            if (tag == 12) { got12 = true; val12 = value; }
            if (tag == 13) { got13 = true; val13 = value; }
        }
        h.expect(got12 && val12 == 0, "W=2 tag12 value");
        h.expect(got13 && val13 == 7, "W=2 tag13 value");
    }

    // DIV/REM must use the serial divider after combinational division is
    // disabled in both ALUs. Also check a consumer waiting for its CDB result.
    const uint32_t div_operands[][2] = {
        {10, 3}, {0xfffffff6u, 3}, {10, 0xfffffffdu},
        {0x80000000u, 0xffffffffu}, {0x80000000u, 0},
        {0xffffffffu, 0}, {0, 0}, {0xffffffffu, 2},
    };
    for (const auto& operands : div_operands) {
        for (uint32_t op = ALU_DIV; op <= ALU_REMU; ++op) {
            h.reset();
            for (uint32_t src = 1; src <= 2; ++src) {
                Uop seed;
                seed.reg_we = 1; seed.dest = src; seed.rob = src;
                seed.a_sel = A_ZERO; seed.b_sel = B_IMM;
                seed.imm = operands[src - 1];
                h.expect(h.dispatch_one(seed), "divider operand dispatch");
                h.expect(h.wait_cdb(tag, value), "divider operand cdb");
                h.expect(tag == src && value == seed.imm, "divider operand value");
                h.tick();  // let the broadcast write the PRF
            }
            const uint32_t a = operands[0], b = operands[1];
            const bool signed_op = (op == ALU_DIV || op == ALU_REM);
            const bool rem_op = (op == ALU_REM || op == ALU_REMU);
            uint32_t expected;
            if (b == 0) {
                expected = rem_op ? a : 0xffffffffu;
            } else if (signed_op) {
                // Widen first: INT_MIN/-1 is well-defined in int64_t.
                const int64_t sa = static_cast<int32_t>(a);
                const int64_t sb = static_cast<int32_t>(b);
                expected = static_cast<uint32_t>(rem_op ? sa % sb : sa / sb);
            } else {
                expected = rem_op ? a % b : a / b;
            }

            Uop divide;
            divide.reg_we = 1; divide.dest = 3; divide.rob = 3;
            divide.alu = op; divide.src1 = 1; divide.src2 = 2;
            h.expect(h.dispatch_one(divide), "DIV/REM dispatch");
            Uop consumer;
            consumer.reg_we = 1; consumer.dest = 4; consumer.rob = 4;
            consumer.src1 = 3; consumer.src1_ready = 0;
            consumer.b_sel = B_IMM; consumer.imm = 1;
            h.expect(h.dispatch_one(consumer), "DIV/REM consumer dispatch");
            h.expect(h.wait_cdb(tag, value), "DIV/REM cdb");
            h.expect(tag == 3 && value == expected, "DIV/REM result");
            h.expect(h.wait_cdb(tag, value), "DIV/REM consumer cdb");
            h.expect(tag == 4 && value == expected + 1u, "DIV/REM consumer value");
            for (int n = 0; n < 8; ++n) h.tick();
            h.expect(h.cdb_q.empty(), "DIV/REM has no duplicate ALU result");
        }
    }

    // A load wakes an ordinary ALU while no registered-ready candidate is
    // available. The restored registered-wake pipeline must read new PRF data.
    for(int both=0;both<2;++both) {
        h.auto_respond=true;h.reset();h.auto_respond=false;
        const uint32_t seed=0x12345678;
        h.write_word(0x7500,seed,15);
        Uop producer;
        producer.dest=40;producer.rob=1;producer.reg_we=1;
        producer.is_load=1;producer.wb_sel=WB_MEM;producer.imm=0x7500;
        h.expect(h.dispatch_one(producer),"load dependency load accepted");
        for(int n=0;n<32&&h.ld_pending.empty();++n)h.tick();
        h.expect(h.ld_pending.size()==1,"load dependency producer waits for memory");
        Uop consumer;
        consumer.dest=41;consumer.rob=2;consumer.reg_we=1;
        consumer.src1=40;consumer.src1_ready=0;
        consumer.b_sel=both?B_REG:B_IMM;consumer.imm=7;
        if(both) {consumer.src2=40;consumer.src2_ready=0;}
        h.expect(h.dispatch_one(consumer),"load dependency consumer accepted");
        Uop follower;
        follower.dest=42;follower.rob=3;follower.reg_we=1;
        follower.src1=41;follower.src1_ready=0;
        follower.b_sel=both?B_REG:B_IMM;follower.imm=3;
        if(both) {follower.src2=41;follower.src2_ready=0;}
        h.expect(h.dispatch_one(follower),"compute dependency follower accepted");
        for(int n=0;n<8;++n)h.tick();
        h.expect(h.cdb_q.empty(),"consumer does not execute before producer");
        h.auto_respond=true;
        int producer_cycle=-1,consumer_cycle=-1,follower_cycle=-1;
        for(int n=0;n<20;++n) {
            h.tick();
            while(!h.cdb_q.empty()) {
                auto event=h.cdb_q.front();h.cdb_q.pop_front();
                if(event.first==40) {
                    h.expect(producer_cycle<0&&event.second==seed,"load dependency producer returns once");
                    producer_cycle=n;
                } else if(event.first==41) {
                    h.expect(consumer_cycle<0&&event.second==(both?seed+seed:seed+7),
                             "load dependency consumer reads new PRF data exactly once");
                    consumer_cycle=n;
                } else {
                    const uint32_t expected=both?(seed+seed+seed+seed):(seed+10);
                    h.expect(event.first==42&&follower_cycle<0&&event.second==expected,
                             "lookahead follower reads new PRF data exactly once");
                    follower_cycle=n;
                }
            }
        }
        h.expect(producer_cycle>=0&&consumer_cycle==producer_cycle+3,
                 "registered-wake consumer returns three edges after producer");
        h.expect(follower_cycle==consumer_cycle+2,
                 "uncontended compute follower returns two edges after consumer");
    }

    printf("\nW=%d checked=%ld fails=%ld\n", W, h.checks, h.fails);
    bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}

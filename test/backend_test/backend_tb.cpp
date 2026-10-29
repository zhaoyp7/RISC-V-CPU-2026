// -----------------------------------------------------------------------------
// backend_tb.cpp — full backend smoke/integration test.
//
// Drives the frozen dispatch/commit/squash buses and observes cdb/complete/
// br_update.  Covers ALU chain, load/store, branch/JAL, squash, IQ full
// backpressure, and W=2 dispatch absorption (IW stays 1 in P1).
// -----------------------------------------------------------------------------

#ifdef TB_STORE_CAPTURE
#include "Vstore_capture_backend_top.h"
using Vbackend_ooo=Vstore_capture_backend_top;
#else
#include "Vbackend_ooo.h"
#endif
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <utility>

#ifndef TB_W
#define TB_W 1
#endif

#ifndef TB_EXTERNAL_SQUASH_SEQUENCE
#define TB_EXTERNAL_SQUASH_SEQUENCE 0
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
    uint64_t cycle_count=0;
#if TB_EXTERNAL_SQUASH_SEQUENCE
    uint32_t model_next_age=0;
    uint32_t model_rob_age[32]={};
    uint32_t model_dest_age[64]={};
    void record_dispatch_age() {
        if(dut->reset) {
            model_next_age=0;
            std::memset(model_rob_age,0,sizeof(model_rob_age));
            std::memset(model_dest_age,0,sizeof(model_dest_age));
        } else if(dut->backend_ready) {
            unsigned accepted=0;
            for(unsigned lane=0;lane<W;++lane)if(get_field(dut->dispatch,lane*DW+O_VALID,1)) {
                model_rob_age[get_field(dut->dispatch,lane*DW+O_ROB,ROB)]=model_next_age+lane;
                model_dest_age[get_field(dut->dispatch,lane*DW+O_DEST,PRF)]=model_next_age+lane;
                ++accepted;
            }
            model_next_age+=accepted;
        }
    }
#endif
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
        cycle_count++;
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

        // CDB/complete/branch outputs are combinational transactions sampled
        // by their consumers at this edge. A response bypass can disappear
        // immediately after the edge and must be captured before state moves.
#if TB_EXTERNAL_SQUASH_SEQUENCE
        if(!dut->reset && get_field(dut->br_update,B_VALID,1))
            expect(dut->br_update_sequence==model_dest_age[get_field(dut->br_update,B_TAG,PRF)],
                   "branch sequence matches independent accepted dispatch order");
#endif
        capture_events();
#if TB_EXTERNAL_SQUASH_SEQUENCE
        record_dispatch_age();
#endif
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
#if TB_EXTERNAL_SQUASH_SEQUENCE
        dut->squash_sequence=model_rob_age[rob];
#endif
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
    // available. The guaranteed load hint must read new PRF data after the write edge.
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
        h.expect(producer_cycle>=0&&consumer_cycle==producer_cycle+2,
                 "load-hinted consumer returns two edges after producer");
#ifdef TB_EXECUTION_HINT
        h.expect(follower_cycle==consumer_cycle+1,
                 "executing producer removes one dependent scheduling edge");
#else
        h.expect(follower_cycle==consumer_cycle+2,
                 "uncontended compute follower returns two edges after consumer");
#endif
    }

    // A held load writes a previously zero PRF slot. A dependent branch
    // must use the new word, including two equal hinted sources and JALR LSB.
    for(int kind=0;kind<5;kind++) {
        h.auto_respond=true;h.reset();h.auto_respond=false;
        const uint32_t seed=kind==2?0x80000123u:0x12345u;
        h.write_word(0x7600,seed,15);
        Uop producer;producer.dest=40;producer.rob=1;producer.reg_we=1;
        producer.is_load=1;producer.wb_sel=WB_MEM;producer.imm=0x7600;
        h.expect(h.dispatch_one(producer),"control hint producer dispatch");
        for(int n=0;n<32&&h.ld_pending.empty();n++)h.tick();
        h.expect(h.ld_pending.size()==1,"control hint held load");
        Uop control;control.pc=0x900;control.dest=41;control.rob=2;
        control.src1=40;control.src1_ready=0;control.imm=0x20;
        if(kind==4){control.is_jalr=1;control.reg_we=1;control.wb_sel=WB_PC4;control.imm=6;}
        else {control.is_branch=1;control.inst=0x63u|((kind==1?1u:kind==2?4u:0u)<<12);}
        if(kind==3){control.src2=40;control.src2_ready=0;}
        h.expect(h.dispatch_one(control),"control hint consumer dispatch");
        for(int n=0;n<8;n++)h.tick();
        h.expect(!h.br_seen&&h.cdb_q.empty()&&h.complete_q.empty(),"control waits before producer writeback");
        h.auto_respond=true;int producer_cycle=-1,branch_cycle=-1,branch_count=0,complete_count=0,links=0;
        for(int n=0;n<24;n++) {
            h.tick();
            while(!h.cdb_q.empty()) {
                auto e=h.cdb_q.front();h.cdb_q.pop_front();
                if(e.first==40){h.expect(producer_cycle<0&&e.second==seed,"control producer word once");producer_cycle=n;}
                else {h.expect(kind==4&&e.first==41&&e.second==0x904,"JALR link word");links++;}
            }
            if(h.br_seen) {
                h.expect(h.br_tag_seen==41,"control update tag");
                h.expect(h.br_taken_seen==unsigned(kind!=0),"control uses new source for direction");
                const uint32_t target=kind==4?((seed+6)&~1u):0x920u;
                h.expect(h.br_target_seen==target,"control target and JALR alignment");
                branch_cycle=n;branch_count++;h.br_seen=false;
            }
            while(!h.complete_q.empty()) {
                h.expect(h.complete_q.front()==41,"control completion tag");
                h.complete_q.pop_front();complete_count++;
            }
        }
        h.expect(producer_cycle>=0&&branch_cycle>producer_cycle&&branch_count==1,"one branch after producer");
        h.expect(kind==4?(links==1&&complete_count==0):(links==0&&complete_count==1),"control finishes exactly once");
    }


#ifdef TB_STORE_CAPTURE
    // The address can finish before an older load supplies store data.
    // Even an early synthetic commit must not write until that data arrives.
    for(unsigned seed:{0x12345678u,0x89abcdefu,0u}) {
        h.auto_respond=true;h.reset();h.auto_respond=false;
        h.write_word(0x7600,seed,15);h.write_word(0x7700,0xfeedbeef,15);
        Uop producer;producer.dest=40;producer.rob=1;producer.reg_we=1;
        producer.is_load=1;producer.wb_sel=WB_MEM;producer.imm=0x7600;
        h.expect(h.dispatch_one(producer),"captured store producer dispatch");
        for(unsigned n=0;n<32&&h.ld_pending.empty();n++)h.tick();
        Uop store;store.dest=41;store.rob=2;store.is_store=1;store.lsq=1;
        store.src2=40;store.src2_ready=0;store.imm=0x7700;
        h.expect(h.dispatch_one(store),"captured store address dispatch");
        for(unsigned n=0;n<8;n++)h.tick();
        unsigned completions=0;
        while(!h.complete_q.empty()){h.expect(h.complete_q.front()==41,"early store completion tag");h.complete_q.pop_front();completions++;}
        h.expect(completions==1&&h.cdb_q.empty(),"store completes once before source load returns");
        h.expect(!dut.st_req_valid&&h.read_word(0x7700)==0xfeedbeef,"uncommitted pending data never writes");
        h.commit_one(1,true,false);
        for(unsigned n=0;n<4;n++)h.tick();
        h.expect(!dut.st_req_valid&&h.read_word(0x7700)==0xfeedbeef,"early commit waits for source data");
        h.auto_respond=true;unsigned writes=0,produced=0;
        for(unsigned n=0;n<32;n++){
            dut.clk=0;dut.eval();if(dut.st_req_valid)writes++;
            h.tick();
            while(!h.cdb_q.empty()){auto e=h.cdb_q.front();h.cdb_q.pop_front();h.expect(e.first==40&&e.second==seed,"pending store receives producer value");produced++;}
            while(!h.complete_q.empty()){h.complete_q.pop_front();completions++;}
        }
        h.expect(writes==1&&produced==1&&completions==1,"one producer, completion and memory write");
        h.expect(h.read_word(0x7700)==seed,"captured store writes its new source word");
    }

#endif


#ifdef TB_DISPATCH_BYPASS
    for(int occupied=0;occupied<2;occupied++){
        h.auto_respond=true;h.reset();
        if(occupied){
            h.auto_respond=false;h.write_word(0x7600,100,15);
            Uop p;p.dest=40;p.rob=1;p.reg_we=1;p.is_load=1;p.wb_sel=WB_MEM;p.imm=0x7600;
            h.expect(h.dispatch_one(p),"direct ALU older load accepted");
            for(int n=0;n<32&&h.ld_pending.empty();n++)h.tick();
            for(int n=0;n<3;n++){Uop q;q.dest=10+n;q.rob=2+n;q.reg_we=1;q.src1=40;q.src1_ready=0;q.b_sel=B_IMM;q.imm=n;h.expect(h.dispatch_one(q),"blocked IQ owner accepted");}
            for(int n=0;n<4;n++)h.tick();
        }
        Uop a;a.dest=50;a.rob=20;a.reg_we=1;a.b_sel=B_IMM;a.imm=123;
        uint64_t start=h.cycle_count;h.expect(h.dispatch_one(a),"ready ALU accepted for direct execution");
        uint32_t tag=0,value=0;bool done=h.wait_cdb(tag,value,24);
        h.expect(done&&tag==50&&value==123,"direct ALU returns correct value exactly once");
        h.expect(h.cycle_count-start==4,"direct ALU saves IQ allocation and selection cycle");
        std::printf("DIRECT_ALU W=%d occupied=%d latency=%llu\n",W,occupied,(unsigned long long)(h.cycle_count-start));
        if(occupied){
            a.dest=51;a.rob=21;a.imm=124;h.expect(h.dispatch_one(a),"ready ALU accepted before squash");
            h.squash_one(1);h.auto_respond=true;unsigned source=0;
            for(int n=0;n<40;n++){h.tick();while(!h.cdb_q.empty()){auto e=h.cdb_q.front();h.cdb_q.pop_front();h.expect(e.first==40&&e.second==100,"squash drops queued and direct younger owners");source++;}}
            h.expect(source==1,"older load survives direct ALU squash");
        }
    }
#endif

#ifdef TB_DISPATCH_COMPUTE_HINT
    for(int both=0;both<2;both++){
        h.auto_respond=true;h.reset();
        Uop producer;producer.dest=40;producer.rob=1;producer.reg_we=1;producer.b_sel=B_IMM;producer.imm=100;
        h.expect(h.dispatch_one(producer),"dispatch hint producer accepted");h.tick();
        Uop consumer;consumer.dest=41;consumer.rob=2;consumer.reg_we=1;consumer.src1=40;consumer.src1_ready=0;
        if(both){consumer.src2=40;consumer.src2_ready=0;consumer.b_sel=B_REG;}else{consumer.b_sel=B_IMM;consumer.imm=3;}
        h.expect(h.dispatch_one(consumer),"dispatch hint consumer accepted before source writeback");
        int first=-1,last=-1;unsigned a=0,b=0;
        for(int n=0;n<24;n++){h.tick();while(!h.cdb_q.empty()){auto e=h.cdb_q.front();h.cdb_q.pop_front();
            if(e.first==40){h.expect(a++==0&&e.second==100,"dispatch hint source writes once");first=n;}
            else {h.expect(e.first==41&&b++==0&&e.second==uint32_t(both?200:103),"dispatch hint uses written operand values");last=n;}
        }}
        h.expect(a==1&&b==1&&last-first==2,"dispatch hint removes one compute dependency cycle");
        std::printf("DISPATCH_HINT W=%d both=%d delta=%d\n",W,both,last-first);
    }
#endif
#ifdef TB_CONTROL_BYPASS
    for(int kind=0;kind<9;++kind){
        h.auto_respond=true;h.reset();Uop q;q.dest=50;q.rob=20;q.pc=0x400+kind*4;q.imm=0x20;
        bool link=kind==6||kind==7;bool taken=kind<6?(kind==0||kind==3||kind==5):true;
        if(kind<6){unsigned f[]={0,1,4,5,6,7};q.is_branch=1;q.inst=0x63|(f[kind]<<12);}
        else if(kind==6){q.is_jal=1;q.reg_we=1;q.wb_sel=WB_PC4;}
        else {q.is_jalr=1;q.reg_we=link;q.wb_sel=WB_PC4;q.imm=0x21;}
        uint64_t start=h.cycle_count;h.expect(h.dispatch_one(q),"control direct admission");
        for(int n=0;n<16&&!h.br_seen;++n)h.tick();
        h.expect(h.br_seen&&h.br_tag_seen==50&&h.br_taken_seen==unsigned(taken),"control direct resolution");
        h.expect(h.br_target_seen==(kind>=7?0x20:q.pc+0x20),"control direct target/alignment");
        h.expect(h.cycle_count-start==3,"control direct saves IQ stage");
        unsigned events=0,completions=0;
        for(int n=0;n<12;++n){
          while(!h.cdb_q.empty()){auto x=h.cdb_q.front();h.cdb_q.pop_front();++events;h.expect(link&&x.first==50&&x.second==q.pc+4,"control link writeback");}
          while(!h.complete_q.empty()){auto x=h.complete_q.front();h.complete_q.pop_front();++completions;h.expect(!link&&x==50,"control no-value completion");}
          h.br_seen=false;h.tick();h.expect(!h.br_seen,"control must resolve once");
        }
        h.expect(events==unsigned(link)&&completions==unsigned(!link),"control exact completion ownership");
        std::printf("DIRECT_CONTROL W=%d kind=%d latency=3\n",W,kind);
    }
    // Highest-lane control bypass must leave the older packet prefix in IQ.
    if(W==2)for(int prefix_control=0;prefix_control<2;++prefix_control){
      h.reset();Uop a,q;a.dest=40;a.rob=1;a.pc=0x600;a.imm=7;a.b_sel=B_IMM;a.reg_we=1;
      if(prefix_control){a.reg_we=0;a.is_branch=1;a.inst=0x63;a.imm=0x20;}
      q.dest=50;q.rob=2;q.pc=0x604;q.imm=0x20;q.is_branch=1;q.inst=0x63;
      Uop packet[2]={a,q};h.expect(h.dispatch_group(packet),"mixed control packet accepted");
      unsigned branches=0,completes=0,writes=0;bool older_branch=false,younger_branch=false;
      for(int n=0;n<24;++n){
        h.tick();if(h.br_seen){++branches;h.expect((h.br_tag_seen==40&&prefix_control)||h.br_tag_seen==50,"mixed branch identity");older_branch|=h.br_tag_seen==40;younger_branch|=h.br_tag_seen==50;h.expect(h.br_taken_seen&&h.br_target_seen==(h.br_tag_seen==40?0x620:0x624),"mixed branch result");h.br_seen=false;}
        while(!h.cdb_q.empty()){auto x=h.cdb_q.front();h.cdb_q.pop_front();++writes;h.expect(!prefix_control&&x.first==40&&x.second==7,"mixed ALU older prefix");}
        while(!h.complete_q.empty()){auto x=h.complete_q.front();h.complete_q.pop_front();++completes;h.expect(x==50||(prefix_control&&x==40),"mixed branch completion identity");}
      }
      h.expect(branches==unsigned(1+prefix_control)&&younger_branch&&older_branch==bool(prefix_control),"both mixed packet owners resolve once");
      h.expect(completes==unsigned(1+prefix_control)&&writes==unsigned(!prefix_control),"mixed packet completion conservation");
    }
    // Squash after the direct owner entered the execution buffer.
    h.reset();Uop older;older.dest=40;older.rob=1;older.reg_we=1;older.b_sel=B_IMM;older.imm=9;
    h.expect(h.dispatch_one(older),"control squash older owner");uint32_t ot=0,ov=0;h.expect(h.wait_cdb(ot,ov),"control squash older completes");
    Uop younger;younger.dest=50;younger.rob=20;younger.pc=0x500;younger.imm=0x20;younger.is_branch=1;younger.inst=0x63;
    h.expect(h.dispatch_one(younger),"control squash younger accepted");h.tick();h.squash_one(1);
    h.expect(!h.br_seen&&h.complete_q.empty()&&h.cdb_q.empty(),"control cancelled on squash edge");
    for(int n=0;n<12;++n){h.tick();h.expect(!h.br_seen&&h.complete_q.empty()&&h.cdb_q.empty(),"cancelled control stays discarded");}
#endif
#ifdef TB_MEMORY_HINT
    // An unwritten base has a distinct old PRF value (zero). Check load
    // addresses, stores with ready data, and same-edge base/data capture.
    for(int kind=0;kind<3;kind++){
        h.auto_respond=true;h.reset();
        const uint32_t base=0x7800+kind*0x20, address=base+4, seed=0x91827364+kind;
        h.write_word(address,seed,15);
        Uop p;p.dest=40;p.rob=1;p.reg_we=1;p.b_sel=B_IMM;p.imm=base;
        h.expect(h.dispatch_one(p),"memory base producer dispatch");
        Uop q;q.dest=41;q.rob=2;q.lsq=1;q.src1=40;q.src1_ready=0;q.imm=4;q.mem_size=2;
        if(kind==0){q.is_load=1;q.reg_we=1;q.wb_sel=WB_MEM;}
        else {q.is_store=1;if(kind==2){q.src2=40;q.src2_ready=0;}}
        h.expect(h.dispatch_one(q),"dependent memory dispatch before base writeback");
        unsigned bases=0,loads=0,completions=0;
        for(int n=0;n<32;n++){
            h.tick();
            while(!h.cdb_q.empty()){
                auto x=h.cdb_q.front();h.cdb_q.pop_front();
                if(x.first==40){++bases;h.expect(x.second==base,"base producer value");}
                else {++loads;h.expect(kind==0&&x.first==41&&x.second==seed,"early load reads computed address");}
            }
            while(!h.complete_q.empty()){auto x=h.complete_q.front();h.complete_q.pop_front();++completions;h.expect(kind!=0&&x==41,"early store completes once");}
        }
        h.expect(bases==1&&loads==unsigned(kind==0)&&completions==unsigned(kind!=0),"early memory exact completion ownership");
        h.expect(dut.early_base_events==1,"memory really issues before registered base-ready");
        if(kind!=0){
            h.expect(h.read_word(address)==seed,"early store cannot write before commit");
            h.commit_one(1,true,false);for(int n=0;n<24;n++)h.tick();
            h.expect(h.read_word(address)==(kind==2?base:0),"early store address and captured data");
        }
    }
    // Cancel at several stages of the dependent load's lifetime. Responses
    // may still return, but the cancelled physical destination cannot write.
    for(int delay=0;delay<4;delay++){
        h.auto_respond=false;h.reset();h.write_word(0x7904,0x10203040,15);
        Uop p;p.dest=40;p.rob=1;p.reg_we=1;p.b_sel=B_IMM;p.imm=0x7900;
        h.expect(h.dispatch_one(p),"cancelled early base producer");
        Uop q;q.dest=41;q.rob=20;q.lsq=1;q.src1=40;q.src1_ready=0;q.imm=4;q.mem_size=2;q.is_load=1;q.reg_we=1;q.wb_sel=WB_MEM;
        h.expect(h.dispatch_one(q),"cancelled early load dispatch");
        for(int n=0;n<delay;n++)h.tick();
        h.squash_one(1);h.auto_respond=true;
        for(int n=0;n<32;n++)h.tick();
        unsigned producers=0;
        while(!h.cdb_q.empty()){auto x=h.cdb_q.front();h.cdb_q.pop_front();++producers;h.expect(x.first==40&&x.second==0x7900,"cancelled load never writes reused destination");}
        h.expect(producers==1&&h.complete_q.empty(),"cancellation keeps only older base producer");
    }
#endif
#ifdef TB_EXECUTION_HINT
    // A pending load keeps the whole dependence chain in IQ. Once it
    // returns, ALU0 and ALU1 both schedule their next consumer before WB.
    unsigned negative_sra_cases=0;
    for(unsigned trial=0;trial<512;trial++){
      h.auto_respond=true;h.reset();h.auto_respond=false;
      uint32_t seed=trial*0x91827365u+0x80000000u;h.write_word(0x7600,seed,15);
      Uop load;load.reg_we=1;load.dest=40;load.rob=1;load.is_load=1;load.wb_sel=WB_MEM;load.imm=0x7600;
      h.expect(h.dispatch_one(load),"future source load accepted");
      for(unsigned n=0;n<24&&h.ld_pending.empty();n++)h.tick();
      uint32_t expected[5]={seed,0,0,0,0};
      for(unsigned k=0;k<4;k++){
       Uop q;q.reg_we=1;q.dest=41+k;q.rob=2+k;q.src1=40+k;q.src1_ready=0;q.b_sel=B_IMM;q.imm=(trial^(k*71))+1;
       static const unsigned operations[]={0,5,2,6,7,3,4,8,9,1};
       q.alu=operations[(trial+k)%10];uint32_t a=expected[k],b=q.imm;
       switch(q.alu){
        case 0:expected[k+1]=a+b;break;
        case 1:q.b_sel=B_REG;q.src2=q.src1;q.src2_ready=0;expected[k+1]=a-a;break;
        case 2:expected[k+1]=a<<(b&31);break;
        case 3:expected[k+1]=int32_t(a)<int32_t(b);break;
        case 4:expected[k+1]=a<b;break;
        case 5:expected[k+1]=a^b;break;
        case 6:expected[k+1]=a>>(b&31);break;
        case 7:expected[k+1]=uint32_t(int32_t(a)>>(b&31));negative_sra_cases+=int32_t(a)<0;break;
        case 8:expected[k+1]=a|b;break;
        case 9:expected[k+1]=a&b;break;
       }
       h.expect(h.dispatch_one(q),"future dependent chain owner accepted");
      }
      for(unsigned n=0;n<6;n++)h.tick();h.auto_respond=true;unsigned seen[5]={};
      for(unsigned n=0;n<64;n++){
       h.tick();while(!h.cdb_q.empty()){
        auto e=h.cdb_q.front();h.cdb_q.pop_front();bool tag_ok=e.first>=40&&e.first<=44;
        h.expect(tag_ok,"future chain exact destination owner");
        if(tag_ok){unsigned k=e.first-40;h.expect(seen[k]++==0&&e.second==expected[k],"future chain exact value, no duplicate");}
       }
      }
      for(unsigned k=0;k<5;k++)h.expect(seen[k]==1,"each future chain instruction completes");
      h.expect(dut.future0_events>0&&dut.future1_events>0,"both executing producers actually schedule early consumers");
    }
    h.expect(negative_sra_cases>0,"forwarded arithmetic covers negative signed shifts");
    std::printf("FORWARD_ARITHMETIC W=%d chains=512 negative_sra=%u\n",W,negative_sra_cases);
#endif
    printf("\nW=%d checked=%ld fails=%ld\n", W, h.checks, h.fails);
    bool pass = (h.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}

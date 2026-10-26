#include "Vrename.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

#ifndef TB_W
#define TB_W 2
#endif

namespace {
constexpr int W = TB_W, PW = 6, DECODE = 132, RENAMED = 145;
constexpr int RD = 97, REG_WE = 102, RS1 = 122, RS2 = 127;
constexpr int DEST = 122, SRC1 = 128, READY1 = 134, SRC2 = 135, READY2 = 141;
int checked = 0, fails = 0;

template <typename T> void put(T& bus, int off, uint32_t value, int width) {
    for (int i = 0; i < width; ++i) {
        const uint32_t mask = uint32_t(1) << ((off + i) % 32);
        auto& word = bus[(off + i) / 32];
        word = (word & ~mask) | (((value >> i) & 1) ? mask : 0);
    }
}
template <typename T> uint32_t get(const T& bus, int off, int width) {
    uint32_t value = 0;
    for (int i = 0; i < width; ++i)
        value |= ((bus[(off + i) / 32] >> ((off + i) % 32)) & 1) << i;
    return value;
}
void expect(const char* label, uint32_t got, uint32_t want) {
    ++checked;
    if (got != want) {
        ++fails;
        std::printf("FAIL %s got=%u want=%u\n", label, got, want);
    }
}
void clear(Vrename& d) {
    d.clk = 0; d.reset = 0; d.in_valid = 0; d.out_ready = 1;
    std::memset(&d.in_uop, 0, sizeof(d.in_uop));
    d.commit_valid = 0; d.commit_rd = 0; d.commit_dest_tag = 0;
    d.commit_reg_we = 0; d.commit_free_valid = 0; d.commit_free_tag = 0;
    d.wake_mask = 0; d.recover_valid = 0; d.recover_free_mask = 0;
    d.recover_busy_mask = 0; d.recover_lsq_ptr = 0;
    std::memset(&d.recover_rat, 0, sizeof(d.recover_rat));
}
void reset(Vrename& d) {
    clear(d); d.reset = 1; d.eval(); d.clk = 1; d.eval();
    d.clk = 0; d.reset = 0; d.eval();
}
void lane(Vrename& d, int n, int rd, int rs1, int rs2, bool writes) {
    d.in_valid |= 1 << n;
    put(d.in_uop, n * DECODE + RD, rd, 5);
    put(d.in_uop, n * DECODE + REG_WE, writes, 1);
    put(d.in_uop, n * DECODE + RS1, rs1, 5);
    put(d.in_uop, n * DECODE + RS2, rs2, 5);
}
void zero_sources(Vrename& d, int n) {
    expect("x0 source1 tag", get(d.out_uop, n * RENAMED + SRC1, PW), 0);
    expect("x0 source1 ready", get(d.out_uop, n * RENAMED + READY1, 1), 1);
    expect("x0 source2 tag", get(d.out_uop, n * RENAMED + SRC2, PW), 0);
    expect("x0 source2 ready", get(d.out_uop, n * RENAMED + READY2, 1), 1);
}
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vrename d;
    reset(d);
    // A decoded instruction writing rd=x0 still receives a completion tag.
    // RISC-V x0 reads must remain constant even beside such an instruction.
    lane(d, 0, 0, 0, 0, true);
    if (W == 2) lane(d, 1, 5, 0, 0, true);
    d.eval(); expect("accepted bundle", d.in_ready, 1); zero_sources(d, 0);
    if (W == 2) zero_sources(d, 1);
    d.clk = 1; d.eval(); clear(d);
    lane(d, 0, 6, 0, 0, true); d.eval(); zero_sources(d, 0);

    // A real nonzero RAW dependency must still point at lane0's new tag.
    if (W == 2) {
        reset(d); lane(d, 0, 5, 0, 0, true); lane(d, 1, 6, 5, 5, true); d.eval();
        const auto tag = get(d.out_uop, DEST, PW);
        expect("nonzero source1 forwarding", get(d.out_uop, RENAMED + SRC1, PW), tag);
        expect("nonzero source2 forwarding", get(d.out_uop, RENAMED + SRC2, PW), tag);
        expect("nonzero source1 waits", get(d.out_uop, RENAMED + READY1, 1), 0);
        expect("nonzero source2 waits", get(d.out_uop, RENAMED + READY2, 1), 0);
    }
    // Exhaust allocation credits and check that x0 stays ready under stall.
    reset(d);
    for (int i = 0; i < 64; ++i) {
        clear(d); lane(d, 0, 0, 0, 0, true);
        if (W == 2) lane(d, 1, 7, 0, 0, true);
        d.eval(); zero_sources(d, 0); if (W == 2) zero_sources(d, 1);
        d.clk = 1; d.eval();
    }
    d.final(); std::printf("rename_zero_tb: W=%d checked=%d fails=%d\n", W, checked, fails);
    return fails ? 1 : 0;
}

// -----------------------------------------------------------------------------
// divider_tb.cpp — divider.sv 的 Verilator 单元测试
//
// 测试协议（与 verilog/divider.sv 的接口约定）：
//   - reset 至少 1 拍后，busy=0、done=0；
//   - start 拉高 1 拍发起运算（busy=1 时应忽略）；
//   - 运算期间 a/b/is_signed 保持不变；
//   - done 为 1 拍脉冲，且 done=1 那一拍 quotient/remainder 已经有效；
//   - done 之后下一拍回到 IDLE（done=0）。
//
// 参考语义（RISC-V M 扩展）：
//   - 有符号除法向零截断，余数符号跟被除数；
//   - 除零：商 = 0xffffffff，余数 = 被除数；
//   - INT_MIN / -1 溢出：商 = INT_MIN，余数 = 0。
//
// 用法见同目录 README.md。g++ -std=c++17 编译（由 run.sh 调用）。
// -----------------------------------------------------------------------------

#include "Vdivider.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

uint32_t rng = 0x20260927u;
uint32_t next_rand() {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

struct Ref {
    uint32_t q, r;
};

// 用 int64_t 中转，避免 INT_MIN / -1 在 C++ 里的未定义行为。
Ref reference(bool is_signed, uint32_t a, uint32_t b) {
    if (!is_signed) {
        if (b == 0) return {0xffffffffu, a};
        return {a / b, a % b};
    }
    if (b == 0) return {0xffffffffu, a};
    int64_t q = (int64_t)(int32_t)a / (int64_t)(int32_t)b;
    int64_t r = (int64_t)(int32_t)a % (int64_t)(int32_t)b;
    return {(uint32_t)q, (uint32_t)r};
}

bool is_boundary(bool is_signed, uint32_t a, uint32_t b) {
    return b == 0 || (is_signed && a == 0x80000000u && b == 0xffffffffu);
}

struct Stats {
    long checked = 0;
    long fails = 0;
    long boundary_fails = 0;
};

struct Harness {
    Vdivider* dut = nullptr;
    Stats stats;
    bool no_boundary = false;
    int max_cycles = 200;

    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    }

    void reset() {
        dut->reset = 1;
        dut->start = 0;
        dut->is_signed = 0;
        dut->a = 0;
        dut->b = 0;
        for (int i = 0; i < 3; ++i) tick();
        dut->reset = 0;
        tick();
    }

    void report_fail(bool boundary, const char* tag, bool signed_op, uint32_t a, uint32_t b,
                     uint32_t got_q, uint32_t got_r, Ref want, const char* why) {
        if (boundary && stats.boundary_fails >= 5) return;
        if (!boundary && stats.fails >= 10) return;
        printf("FAIL [%s] %s %s a=%08x b=%08x | q=%08x want=%08x | r=%08x want=%08x\n",
               tag, why, signed_op ? "signed  " : "unsigned", a, b, got_q, want.q, got_r, want.r);
    }

    // 发起一次运算并检查结果与协议；返回是否通过。
    bool check(bool signed_op, uint32_t a, uint32_t b, const char* tag) {
        bool boundary = is_boundary(signed_op, a, b);
        if (no_boundary && boundary) return true;
        Ref want = reference(signed_op, a, b);

        dut->is_signed = signed_op;
        dut->a = a;
        dut->b = b;
        dut->start = 1;
        tick();  // start 在本时钟沿被接受
        dut->start = 0;

        int cycles = 1;
        bool ok = true;
        while (!dut->done && cycles < max_cycles) {
            tick();
            ++cycles;
            if (!dut->done && !dut->busy) {
                report_fail(boundary, tag, signed_op, a, b, 0, 0, want, "busy dropped");
                ok = false;
                break;
            }
        }
        if (!ok) {
            ++stats.checked;
            if (boundary) ++stats.boundary_fails; else ++stats.fails;
            return false;
        }
        if (!dut->done) {
            report_fail(boundary, tag, signed_op, a, b, 0, 0, want, "timeout");
            ++stats.checked;
            if (boundary) ++stats.boundary_fails; else ++stats.fails;
            return false;
        }

        // done=1 的这一拍结果必须已经有效。
        uint32_t got_q = dut->quotient;
        uint32_t got_r = dut->remainder;
        if (got_q != want.q || got_r != want.r) {
            report_fail(boundary, tag, signed_op, a, b, got_q, got_r, want, "mismatch");
            ok = false;
        }

        tick();  // done 必须是 1 拍脉冲
        if (dut->done) {
            report_fail(boundary, tag, signed_op, a, b, got_q, got_r, want, "done not a pulse");
            ok = false;
        }

        ++stats.checked;
        if (!ok) {
            if (boundary) ++stats.boundary_fails; else ++stats.fails;
        }
        return ok;
    }

    void check_reset_midway() {
        dut->is_signed = 1;
        dut->a = (uint32_t)-100;
        dut->b = 7;
        dut->start = 1;
        tick();
        dut->start = 0;
        for (int i = 0; i < 5; ++i) tick();  // 运算中途
        dut->reset = 1;
        tick();
        dut->reset = 0;
        tick();
        if (dut->busy || dut->done) {
            printf("FAIL [reset] reset 后 busy/done 不为 0 (busy=%d done=%d)\n",
                   dut->busy, dut->done);
            ++stats.checked;
            ++stats.fails;
            return;
        }
        check(true, (uint32_t)-100, 7, "reset");
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long random_iters = 100000;
    bool quick = false;
    bool no_boundary = false;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--quick")) quick = true;
        else if (!strcmp(argv[i], "--no-boundary")) no_boundary = true;
        else {
            printf("usage: %s [--quick] [--no-boundary]\n", argv[0]);
            return 2;
        }
    }
    if (quick) random_iters = 5000;

    Vdivider dut;
    Harness h;
    h.dut = &dut;
    h.no_boundary = no_boundary;
    h.reset();

    // ---------- 定向用例 ----------
    struct Case { bool s; uint32_t a, b; };
    const Case directed[] = {
        {true, 7, 2}, {true, (uint32_t)-7, 2}, {true, 7, (uint32_t)-2},
        {true, (uint32_t)-7, (uint32_t)-2},
        {true, 4, 2}, {true, 6, 3}, {true, 8, 2}, {true, 1, 1},
        {true, 0, 5}, {true, 0, (uint32_t)-5},
        {true, (uint32_t)-1, 2}, {true, (uint32_t)-1, (uint32_t)-2},
        {true, 1, (uint32_t)-2}, {true, (uint32_t)-1, 1},
        {true, 0x80000000u, 1}, {true, 0x80000000u, 2},
        {true, 0x80000000u, 3}, {true, 0x80000000u, 0x7fffffffu},
        {true, 0x80000000u, 0xffffffffu}, {true, 0x7fffffffu, 0xffffffffu},
        {true, 5, 0}, {true, (uint32_t)-5, 0}, {true, 0, 0},
        {false, 0xffffffffu, 2}, {false, 7, 2}, {false, 4, 2}, {false, 0, 5},
        {false, 0x80000000u, 1}, {false, 1, 0xffffffffu}, {false, 5, 0},
    };
    for (const Case& c : directed) h.check(c.s, c.a, c.b, "directed");

    h.check_reset_midway();

    // ---------- 随机用例（偏向边界值）----------
    const uint32_t corners[] = {0, 1, 2, 3, 0x40000000u, 0x7fffffffu,
                                0x80000000u, 0xffffffffu, (uint32_t)-2, (uint32_t)-3};
    for (long n = 0; n < random_iters; ++n) {
        bool s = next_rand() & 1;
        uint32_t a = next_rand();
        uint32_t b = next_rand();
        if ((next_rand() & 7) == 0) {
            a = corners[next_rand() % 10];
            b = corners[next_rand() % 10];
        }
        h.check(s, a, b, "random");
    }

    printf("\nchecked=%ld  fails=%ld  boundary_fails=%ld%s\n", h.stats.checked, h.stats.fails,
           h.stats.boundary_fails, no_boundary ? " (boundary cases skipped)" : "");
    bool pass = h.stats.fails == 0 && h.stats.boundary_fails == 0;
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}

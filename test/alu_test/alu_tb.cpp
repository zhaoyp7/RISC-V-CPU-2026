#include "Valu_test_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <random>

static uint32_t reference(uint32_t a, uint32_t b, unsigned op) {
    const int64_t sa = static_cast<int32_t>(a);
    const int64_t sb = static_cast<int32_t>(b);
    const unsigned shift = b & 31;
    switch (op) {
    case 0: return a + b;
    case 1: return a - b;
    case 2: return a << shift;
    case 3: return sa < sb;
    case 4: return a < b;
    case 5: return a ^ b;
    case 6: return a >> shift;
    case 7: return (a >> shift) |
                   ((shift && (a >> 31)) ? (0xffffffffu << (32 - shift)) : 0);
    case 8: return a | b;
    case 9: return a & b;
    case 10: return static_cast<uint32_t>(uint64_t(a) * b);
    case 11: return static_cast<uint64_t>(sa * sb) >> 32;
    case 12: return static_cast<uint64_t>(sa * int64_t(b)) >> 32;
    case 13: return (uint64_t(a) * b) >> 32;
    // int64_t division also handles the RV32 INT_MIN/-1 overflow safely.
    case 14: return b ? static_cast<uint32_t>(sa / sb) : 0xffffffffu;
    case 15: return b ? a / b : 0xffffffffu;
    case 16: return b ? static_cast<uint32_t>(sa % sb) : a;
    case 17: return b ? a % b : a;
    default: return 0;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Valu_test_top dut;
    uint64_t checks = 0;
    auto check_pair = [&](uint32_t a, uint32_t b) {
        const unsigned count = TB_ENABLE_DIV ? 18 : 14;
        for (unsigned op = 0; op < count; ++op) {
            dut.a = a; dut.b = b; dut.op = op;
            dut.eval();
            const uint32_t expected = reference(a, b, op);
            ++checks;
            if (dut.y != expected) {
                std::printf("FAIL ENABLE_DIV=%d op=%u a=%08x b=%08x got=%08x expected=%08x\n",
                            TB_ENABLE_DIV, op, a, b, dut.y, expected);
                return false;
            }
        }
        return true;
    };

    const uint32_t edges[] = {
        0, 1, 2, 3, 0x7fffffffu, 0x80000000u, 0x80000001u,
        0xffffffffu, 0xfffffffeu, 0x00010000u, 0xffff0000u,
        0x0000ffffu, 0x55555555u, 0xaaaaaaaau, 0x01010101u, 0x80808080u,
    };
    for (uint32_t a : edges)
        for (uint32_t b : edges)
            if (!check_pair(a, b)) return 1;
    for (unsigned i = 0; i < 32; ++i) {
        const uint32_t bit = uint32_t(1) << i;
        for (uint32_t b : edges) {
            if (!check_pair(bit, b) || !check_pair(b, bit) ||
                !check_pair(0u - bit, b) || !check_pair(b, 0u - bit)) return 1;
        }
    }
    std::mt19937 random(0x20261023u);
    for (unsigned i = 0; i < 20000; ++i) {
        const uint32_t a = random(), b = random();
        if (!check_pair(a, b)) return 1;
    }
    std::printf("alu ENABLE_DIV=%d checks=%llu PASS\n", TB_ENABLE_DIV,
                static_cast<unsigned long long>(checks));
    return 0;
}

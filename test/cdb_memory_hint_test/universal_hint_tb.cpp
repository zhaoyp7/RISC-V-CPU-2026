#include "Vcdb_memory_hint_universal.h"
#include "verilated.h"
#include <cstdio>

// Independent rotating-priority allocator with the production ALU0 priority.
static unsigned grant(unsigned phase, unsigned offered) {
    unsigned result = 0;
    for (unsigned lane = 0; lane < 2; ++lane) {
        if (lane == 0 && (offered & 1)) {
            result |= 1;
            continue;
        }
        for (unsigned n = 0; n < 4; ++n) {
            unsigned bit = 1u << ((phase + lane + n + 1) % 4);
            if ((offered & bit) && !(result & bit)) {
                result |= bit;
                break;
            }
        }
    }
    return result;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vcdb_memory_hint_universal dut;
    unsigned checks = 0, failures = 0;
    auto expect = [&](bool ok) { ++checks; if (!ok) ++failures; };
    for (unsigned pending = 0; pending < 8; ++pending) {
        unsigned raw = (pending & 3) | ((pending & 4) << 1);
        unsigned expected = 11;
        for (unsigned phase = 0; phase < 4; ++phase)
            for (unsigned load = 0; load < 2; ++load)
                expected &= grant(phase, raw | (load << 2));
        dut.compute_valid = pending;
        dut.eval();
        expect(dut.hint_mask == expected);
        // A cancellation can remove any pending producer before arbitration.
        for (unsigned phase = 0; phase < 4; ++phase)
            for (unsigned actual = 0; actual < 16; ++actual)
                if ((actual & ~4u & ~raw) == 0)
                    expect((dut.hint_mask & actual & ~grant(phase, actual)) == 0);
    }
    std::printf("UNIVERSAL_MEMORY_HINT checks=%u failures=%u\n", checks, failures);
    return failures ? 1 : 0;
}

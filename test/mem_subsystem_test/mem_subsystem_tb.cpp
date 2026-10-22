// -----------------------------------------------------------------------------
// mem_subsystem_tb.cpp — mem_subsystem v2 unit test.
//
// Checks the P2 clients (dual I-Cache refill, pipelined load, pipelined store)
// against a simple AXI4-Lite slave: routing, read/write data, write strobes,
// back-to-back transactions and IF/LD arbitration.
// -----------------------------------------------------------------------------

#include "Vmem_subsystem.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

namespace {

struct Slave {
    Vmem_subsystem* dut = nullptr;

    uint8_t mem[1 << 16];

    bool     rd_pending = false;
    uint32_t rd_addr = 0;
    int      rd_delay = 0;
    bool     rvalid = false;
    bool     r_fire = false;

    bool     aw_seen = false;
    bool     w_seen = false;
    bool     wr_active = false;
    uint32_t wr_addr = 0;
    uint32_t wr_data = 0;
    uint8_t  wr_strb = 0;
    int      wr_delay = 0;
    bool     bvalid = false;
    bool     b_fire = false;

    long checks = 0;
    long fails = 0;

    void init() {
        for (unsigned i = 0; i < sizeof(mem); ++i)
            mem[i] = (uint8_t)(i * 37 + 11);
        dut->arready = 1;
        dut->awready = 1;
        dut->wready = 1;
        dut->rvalid = 0;
        dut->rdata = 0;
        dut->rresp = 0;
        dut->bvalid = 0;
        dut->bresp = 0;
    }

    uint32_t word(uint32_t addr) const {
        uint32_t a = addr & 0xffff;
        return (uint32_t)mem[a] |
               ((uint32_t)mem[(a + 1) & 0xffff] << 8) |
               ((uint32_t)mem[(a + 2) & 0xffff] << 16) |
               ((uint32_t)mem[(a + 3) & 0xffff] << 24);
    }

    void write_word(uint32_t addr, uint32_t value, uint8_t strb) {
        uint32_t a = addr & 0xffff;
        for (int lane = 0; lane < 4; ++lane)
            if (strb & (1u << lane))
                mem[(a + lane) & 0xffff] = (uint8_t)(value >> (8 * lane));
    }

    void before_edge() {
        // One outstanding read/write at a time; axi_mem_if queues internally.
        dut->arready = (!rd_pending && !rvalid) ? 1 : 0;
        if (dut->arvalid && dut->arready) {
            rd_pending = true;
            rd_addr = dut->araddr;
            rd_delay = 2;
        }

        dut->awready = (!wr_active && !aw_seen) ? 1 : 0;
        if (dut->awvalid && dut->awready) {
            aw_seen = true;
            wr_addr = dut->awaddr;
        }
        dut->wready = (!wr_active && !w_seen) ? 1 : 0;
        if (dut->wvalid && dut->wready) {
            w_seen = true;
            wr_data = dut->wdata;
            wr_strb = (uint8_t)dut->wstrb;
        }
        if (aw_seen && w_seen && !wr_active) {
            wr_active = true;
            wr_delay = 2;
        }

        if (rd_pending && !rvalid) {
            if (rd_delay > 0) --rd_delay;
            else {
                rvalid = true;
                dut->rdata = word(rd_addr);
            }
        }
        if (wr_active && !bvalid) {
            if (wr_delay > 0) --wr_delay;
            else bvalid = true;
        }

        dut->rvalid = rvalid ? 1 : 0;
        dut->bvalid = bvalid ? 1 : 0;
        r_fire = rvalid && dut->rready;
        b_fire = bvalid && dut->bready;
    }

    void after_edge() {
        if (r_fire) {
            rvalid = false;
            rd_pending = false;
        }
        if (b_fire) {
            write_word(wr_addr, wr_data, wr_strb);
            bvalid = false;
            wr_active = false;
            aw_seen = false;
            w_seen = false;
        }
    }

    void check(bool ok, const char* what) {
        ++checks;
        if (!ok) {
            ++fails;
            printf("FAIL: %s\n", what);
        }
    }
};

struct Harness {
    Vmem_subsystem* dut = nullptr;
    Slave slave;

    long if_count = 0, if2_count = 0, ld_count = 0, st_count = 0;
    uint32_t if_rdata = 0, if2_rdata = 0, ld_rdata = 0;
    bool last_ld_fire = false, last_st_fire = false;

    void tick() {
        dut->clk = 0;
        dut->eval();
        slave.before_edge();
        dut->eval();
        last_ld_fire = (dut->ld_req_valid && dut->ld_req_ready) != 0;
        last_st_fire = (dut->st_req_valid && dut->st_req_ready) != 0;
        sample();
        dut->clk = 1;
        dut->eval();
        slave.after_edge();
        dut->eval();
    }

    void sample() {
        if (dut->if_resp_valid) {
            ++if_count;
            if_rdata = dut->if_resp_rdata;
        }
        if (dut->if2_resp_valid) {
            ++if2_count;
            if2_rdata = dut->if2_resp_rdata;
        }
        if (dut->ld_resp_valid) {
            ++ld_count;
            ld_rdata = dut->ld_resp_rdata;
        }
        if (dut->st_resp_valid) ++st_count;
    }

    void reset() {
        dut->reset = 1;
        dut->if_req_valid = 0;
        dut->if_req_addr = 0;
        dut->if2_req_valid = 0;
        dut->if2_req_addr = 0;
        dut->ld_req_valid = 0;
        dut->ld_req_addr = 0;
        dut->st_req_valid = 0;
        dut->st_req_addr = 0;
        dut->st_req_wdata = 0;
        dut->st_req_wstrb = 0;
        dut->data_req_valid = 0;
        dut->data_req_we = 0;
        dut->data_req_addr = 0;
        dut->data_req_wdata = 0;
        dut->data_req_wstrb = 0;
        for (int i = 0; i < 4; ++i) tick();
        dut->reset = 0;
        tick();
        if_count = if2_count = ld_count = st_count = 0;
    }

    bool if_read(uint32_t addr, uint32_t want, const char* tag) {
        const long before = if_count;
        dut->if_req_valid = 1;
        dut->if_req_addr = addr;
        for (int c = 0; c < 128; ++c) {
            tick();
            if (if_count != before) {
                const bool ok = (if_rdata == want);
                slave.check(ok, tag);
                if (!ok)
                    printf("  [%s] addr=%08x got=%08x want=%08x\n",
                           tag, addr, if_rdata, want);
                dut->if_req_valid = 0;
                tick();
                return ok;
            }
        }
        slave.check(false, "if_read timeout");
        dut->if_req_valid = 0;
        return false;
    }

    bool if2_read(uint32_t addr, uint32_t want, const char* tag) {
        const long before = if2_count;
        dut->if2_req_valid = 1;
        dut->if2_req_addr = addr;
        for (int c = 0; c < 128; ++c) {
            tick();
            if (if2_count != before) {
                const bool ok = (if2_rdata == want);
                slave.check(ok, tag);
                if (!ok)
                    printf("  [%s] addr=%08x got=%08x want=%08x\n",
                           tag, addr, if2_rdata, want);
                dut->if2_req_valid = 0;
                tick();
                return ok;
            }
        }
        slave.check(false, "if2_read timeout");
        dut->if2_req_valid = 0;
        return false;
    }

    bool ld_read(uint32_t addr, uint32_t want, const char* tag) {
        // Hold valid until the request stream accepts it.
        dut->ld_req_valid = 1;
        dut->ld_req_addr = addr;
        bool accepted = false;
        for (int c = 0; c < 64 && !accepted; ++c) {
            tick();
            accepted = last_ld_fire;
        }
        slave.check(accepted, "ld request accepted");
        dut->ld_req_valid = 0;
        const long before = ld_count;
        for (int c = 0; c < 128; ++c) {
            tick();
            if (ld_count != before) {
                const bool ok = (ld_rdata == want);
                slave.check(ok, tag);
                if (!ok)
                    printf("  [%s] addr=%08x got=%08x want=%08x\n",
                           tag, addr, ld_rdata, want);
                return ok;
            }
        }
        slave.check(false, "ld_read timeout");
        return false;
    }

    bool st_write(uint32_t addr, uint32_t value, uint8_t strb, const char* tag) {
        dut->st_req_valid = 1;
        dut->st_req_addr = addr;
        dut->st_req_wdata = value;
        dut->st_req_wstrb = strb;
        bool accepted = false;
        for (int c = 0; c < 64 && !accepted; ++c) {
            tick();
            accepted = last_st_fire;
        }
        slave.check(accepted, "st request accepted");
        dut->st_req_valid = 0;
        const long before = st_count;
        for (int c = 0; c < 128; ++c) {
            tick();
            if (st_count != before) {
                slave.check(true, tag);
                return true;
            }
        }
        slave.check(false, "st_write timeout");
        return false;
    }

    void concurrent_if_ld(uint32_t if_addr, uint32_t if_want,
                          uint32_t ld_addr, uint32_t ld_want) {
        const long if_before = if_count, ld_before = ld_count;
        dut->if_req_valid = 1;
        dut->if_req_addr = if_addr;
        dut->ld_req_valid = 1;
        dut->ld_req_addr = ld_addr;

        bool if_done = false, ld_done = false;
        bool ld_accepted = false;
        for (int c = 0; c < 256 && !(if_done && ld_done); ++c) {
            tick();
            if (!ld_accepted && last_ld_fire) {
                ld_accepted = true;
                dut->ld_req_valid = 0;
            }
            if (if_count != if_before && !if_done) {
                if_done = true;
                slave.check(if_rdata == if_want, "concurrent if data");
                dut->if_req_valid = 0;
            }
            if (ld_count != ld_before && !ld_done) {
                ld_done = true;
                slave.check(ld_rdata == ld_want, "concurrent ld data");
            }
        }
        slave.check(ld_accepted, "concurrent ld accepted");
        slave.check(if_done && ld_done, "concurrent both completed");
        dut->if_req_valid = 0;
        dut->ld_req_valid = 0;
        tick();
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vmem_subsystem dut;
    Harness h;
    h.dut = &dut;
    h.slave.dut = &dut;
    h.slave.init();
    h.reset();

    const uint32_t if_addr = 0x1000;
    const uint32_t if2_addr = 0x1100;
    const uint32_t ld_addr = 0x2000;
    const uint32_t st_addr = 0x3000;

    h.slave.write_word(if_addr, 0x11223344, 0xf);
    h.slave.write_word(if2_addr, 0x55667788, 0xf);
    h.slave.write_word(ld_addr, 0xa5a55a5a, 0xf);

    h.if_read(if_addr, 0x11223344, "if read");
    h.if2_read(if2_addr, 0x55667788, "if2 read");
    h.ld_read(ld_addr, 0xa5a55a5a, "ld read");

    h.st_write(st_addr, 0xdeadbeef, 0xf, "st write");
    h.slave.check(h.slave.word(st_addr) == 0xdeadbeef, "st write data");
    h.ld_read(st_addr, 0xdeadbeef, "ld write then read");

    h.slave.write_word(st_addr + 4, 0x01020304, 0xf);
    h.st_write(st_addr + 4, 0x0000aa00, 0x2, "st partial write");
    h.slave.check(h.slave.word(st_addr + 4) == 0x0102aa04,
                  "st partial write data");

    // Back-to-back load requests.
    h.slave.write_word(0x4000, 0x0badf00d, 0xf);
    h.slave.write_word(0x4004, 0xcafebabe, 0xf);
    h.ld_read(0x4000, 0x0badf00d, "back-to-back ld 0");
    h.ld_read(0x4004, 0xcafebabe, "back-to-back ld 1");

    // IF has priority over LD; both must complete without mixing data.
    h.slave.write_word(0x5000, 0x12345678, 0xf);
    h.slave.write_word(0x5004, 0x87654321, 0xf);
    h.concurrent_if_ld(0x5000, 0x12345678, 0x5004, 0x87654321);

    printf("\nchecks=%ld fails=%ld if=%ld if2=%ld ld=%ld st=%ld\n",
           h.slave.checks, h.slave.fails, h.if_count, h.if2_count,
           h.ld_count, h.st_count);
    const bool pass = (h.slave.fails == 0);
    printf(pass ? "PASS\n" : "FAIL\n");
    return pass ? 0 : 1;
}

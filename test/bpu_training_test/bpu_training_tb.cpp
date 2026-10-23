// Observe training latency and prediction snapshots through frontend ports only.
#include "Vfrontend_ooo.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <vector>

struct Record { uint32_t pc, target; bool taken; };
struct Harness {
    Vfrontend_ooo& d;
    struct Memory { bool pending=false; uint32_t addr=0; int delay=0; } mem[2];
    unsigned checks=0, fails=0;
    std::vector<Record> records;
    void check(bool ok,const char* what) {
        ++checks;if(!ok){++fails;std::printf("FAIL: %s\n",what);}
    }
    static uint32_t instruction(uint32_t addr) {
        return ((addr&0x1ff)==0)?0x1000006fu:0x00000013u;
    }
    template<class V> static uint32_t field(const V& v,int off,int width) {
        uint32_t x=0;for(int b=0;b<width;++b)x|=((v[(off+b)/32]>>((off+b)%32))&1u)<<b;
        return x;
    }
    void tick() {
        d.clk=0;d.eval();bool drive[2]={};
        for(int ch=0;ch<2;++ch) {
            bool valid=ch?d.refill_valid1:d.refill_valid;
            uint32_t addr=ch?d.refill_addr1:d.refill_addr;
            auto& m=mem[ch];
            if(m.pending && (!valid || addr!=m.addr)) {
                check(d.redirect_valid || !valid,"refill address stable");m.pending=false;
            }
            if(!m.pending && valid){m.pending=true;m.addr=addr;m.delay=2;}
            if(m.pending){if(m.delay)--m.delay;else drive[ch]=true;}
        }
        d.refill_resp_valid=drive[0];d.refill_resp_valid1=drive[1];
        d.refill_rdata=drive[0]?instruction(mem[0].addr):0;
        d.refill_rdata1=drive[1]?instruction(mem[1].addr):0;d.eval();
        if(!d.reset && !d.redirect_valid && d.rename_ready) {
            for(int lane=0;lane<TB_W;++lane)if(d.dec_valid>>lane&1) {
                Record r{field(d.dec_uop,lane*132+1,32),
                         uint32_t(d.dec_pred_target>>(32*lane)),bool(d.dec_pred_taken>>lane&1)};
                check(field(d.dec_uop,lane*132+33,32)==instruction(r.pc),"instruction/PC pairing");
                records.push_back(r);
            }
        }
        d.clk=1;d.eval();d.clk=0;d.eval();
        for(int ch=0;ch<2;++ch)if(drive[ch])mem[ch].pending=false;
        d.refill_resp_valid=0;d.refill_resp_valid1=0;d.eval();
    }
    void reset() {
        d.reset=1;d.backend_ready=0;d.rename_ready=0;d.redirect_valid=0;d.redirect_pc=0;
        d.br_update_valid=0;d.br_update_pc=0;d.br_update_taken=0;d.br_update_target=0;
        d.br_update_uncond=0;d.br_update_is_jalr=0;d.br_update_tag=0;
        d.refill_resp_valid=0;d.refill_resp_valid1=0;d.refill_rdata=0;d.refill_rdata1=0;
        mem[0]={};mem[1]={};records.clear();tick();tick();d.reset=0;tick();
    }
    void update(uint32_t pc,uint32_t target,bool taken=true,bool uncond=true) {
        d.br_update_valid=1;d.br_update_pc=pc;d.br_update_target=target;
        d.br_update_taken=taken;d.br_update_uncond=uncond;tick();
    }
    void settle() { d.br_update_valid=0;tick();tick(); }
    void until(unsigned n) {
        d.backend_ready=1;d.rename_ready=1;
        for(unsigned i=0;i<256 && records.size()<n;++i)tick();
        check(records.size()>=n,"decoded response arrives");
    }
    void redirect(uint32_t pc) {
        d.backend_ready=0;d.rename_ready=0;d.redirect_valid=1;d.redirect_pc=pc;
        tick();check(d.pc_out==pc,"redirect applies immediately");
        d.redirect_valid=0;records.clear();
    }
    void first(uint32_t pc,bool taken,uint32_t target=0) {
        redirect(pc);until(1);
        if(!records.empty())check(records[0].pc==pc && records[0].taken==taken &&
                                 (!taken || records[0].target==target),"trained prediction metadata");
        d.backend_ready=0;d.rename_ready=0;
    }
};
int main(int argc,char** argv) {
    VerilatedContext context;context.threads(1);context.commandArgs(argc,argv);
    Vfrontend_ooo dut{&context};Harness h{dut};auto& d=dut;
    h.reset();
    // An incoming training update cannot rewrite the current fetch snapshot.
    d.backend_ready=1;d.rename_ready=0;h.update(0,0x100);
    d.br_update_valid=0;d.backend_ready=0;
    for(int i=0;i<6;++i)h.tick();h.until(2);
    if(h.records.size()>=2) {
        h.check(h.records[0].pc==0 && !h.records[0].taken,"incoming update is delayed one cycle");
        h.check(h.records[1].pc==4 && !h.records[1].taken,"paired instruction retains original snapshot");
    }
    h.redirect(0);h.until(2);
    if(h.records.size()>=2) {
        h.check(h.records[0].pc==0 && h.records[0].taken && h.records[0].target==0x100,
                "training becomes visible after pipeline");
        h.check(h.records[1].pc==0x100,"taken first lane suppresses sequential second lane");
    }
    // Back-to-back updates, including conflicting BTB/BHT indices and targets.
    d.backend_ready=0;d.rename_ready=0;
    h.update(0,0x140);h.update(0,0x180);h.update(0x200,0x300);h.update(0,0x1c0);h.settle();
    h.first(0,true,0x1c0);h.first(0x200,false);
    for(int i=0;i<3;++i)h.update(0,0,false,false);h.settle();h.first(0,false);
    h.update(0,0x180,true,false);h.update(0,0x180,true,false);h.settle();h.first(0,true,0x180);
    // Training and redirect are independent; recovery does not wait a cycle.
    d.redirect_valid=1;d.redirect_pc=4;h.update(4,0x88);
    h.check(d.pc_out==4,"training does not delay simultaneous redirect");
    d.redirect_valid=0;d.br_update_valid=0;h.records.clear();h.until(1);
    if(!h.records.empty())h.check(h.records[0].pc==4 && h.records[0].taken &&
                                 h.records[0].target==0x88,"redirect preserves accepted training");
    // Reset discards any pending training valid and predictor table state.
    d.backend_ready=0;d.rename_ready=0;h.update(0,0x100);h.reset();h.until(1);
    if(!h.records.empty())h.check(h.records[0].pc==0 && !h.records[0].taken,"reset drops pending training");
    std::printf("BPU training W=%d checks=%u fails=%u\n",TB_W,h.checks,h.fails);
    return h.fails?1:0;
}

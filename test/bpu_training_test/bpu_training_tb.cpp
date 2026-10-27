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
    int latency[2]={2,2};
    unsigned checks=0, fails=0;
    std::vector<Record> records;
    void check(bool ok,const char* what) {
        ++checks;if(!ok){++fails;std::printf("FAIL: %s\n",what);}
    }
    static uint32_t instruction(uint32_t addr) {
        return ((addr&0x1ff)==0)?0x1000006fu:(((addr>>2)&0x7ff)<<20)|0x13u;
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
            if(!m.pending && valid){m.pending=true;m.addr=addr;m.delay=latency[ch];}
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
        d.decode_capacity=(1u<<TB_W)-1;
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
    void backend_stall_responses() {
        reset();d.backend_ready=1;d.rename_ready=0;tick();tick();
        check(d.pc_out==16,"two paired requests accepted before backend stall");
        d.backend_ready=0;
        for(int i=0;i<128;++i)tick();
        check(d.dec_valid!=0 && field(d.dec_uop,1,32)==0,
              "in-flight responses buffered while backend is stalled");
        if(TB_W==2)check(d.dec_valid==3 && field(d.dec_uop,133,32)==4,
                        "paired response remains together during backend stall");
        // With rename stopped, bounded prefetch must eventually stop too.
        uint32_t stopped_pc=d.pc_out;
        for(int i=0;i<32;++i) {
            tick();check(d.pc_out==stopped_pc,"prefetch remains bounded during backend stall");
        }
        // Rename may drain responses independently of the backend hint.
        // Check every observed instruction, including any new prefetches.
        d.rename_ready=1;
        for(int i=0;i<32;++i)tick();
        check(records.size()>=4,"all initially issued responses drain during backend stall");
        for(unsigned i=0;i<records.size();++i)
            check(records[i].pc==4*i && !records[i].taken,"stalled response order and snapshot");
        check(d.pc_out>=4*records.size(),"request PC covers the decoded prefix");
        d.rename_ready=0;
    }
    void partial_decode_capacity() {
        if(TB_W!=2)return;
        reset();update(4,0x80);settle();redirect(0);
        d.backend_ready=1;d.rename_ready=0;tick();tick();d.backend_ready=0;
        for(int i=0;i<64;++i)tick();
        uint64_t targets=d.dec_pred_target;
        bool second_taken=(d.dec_pred_taken>>1)&1;
        uint32_t second_target=uint32_t(targets>>32);
        check(second_taken && second_target==0x80,"partial group includes nonzero taken prediction snapshot");
        d.decode_capacity=1;d.rename_ready=1;tick();
        check(records.size()==1 && records[0].pc==0,"one slot consumes only first decoded instruction");
        d.rename_ready=0;tick();
        check(d.dec_valid==1 && field(d.dec_uop,1,32)==4,"second decoded instruction retained at FIFO head");
        check(bool(d.dec_pred_taken&1)==second_taken && uint32_t(d.dec_pred_target)==second_target,
              "retained instruction keeps prediction snapshot");
        d.decode_capacity=0;d.rename_ready=1;
        for(int i=0;i<5;++i)tick();
        check(records.size()==1 && d.dec_valid==0,"zero capacity consumes nothing even when rename is ready");
        d.decode_capacity=1;tick();d.decode_capacity=3;tick();
        check(records.size()==4,"single then dual admission preserves exact instruction count");
        const uint32_t expected[]={0,4,0x80,0x84};
        for(unsigned i=0;i<records.size();++i)check(records[i].pc==expected[i],"partial admission preserves program order");
        check(d.pc_out>=0x88,"partial decode capacity preserves the requested prefix");
        // Redirect while a suffix remains queued after a one-instruction pop.
        d.rename_ready=0;d.backend_ready=1;tick();tick();d.backend_ready=0;
        for(int i=0;i<64;++i)tick();
        d.decode_capacity=1;d.rename_ready=1;tick();redirect(0x100);until(4);
        for(unsigned i=0;i<4 && i<records.size();++i)
            check(records[i].pc==0x100+4*i,"redirect drops partially consumed group suffix");
        d.decode_capacity=3;d.rename_ready=0;d.backend_ready=0;
    }
    void randomized_flush_and_capacity(uint32_t seed) {
        reset();uint32_t expected_pc=0;unsigned accepted=0, redirects=0;
        auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
        for(unsigned cycle=0;cycle<30000;++cycle) {
            uint32_t bits=random();bool flush=bits%47==0;
            d.redirect_valid=flush;d.redirect_pc=((bits>>8)&127u)*4;
            d.backend_ready=(bits>>16)&1;d.rename_ready=(bits>>17)&1;
            unsigned slots=(bits>>18)%3;
            d.decode_capacity=slots==0?0:slots==1?1:((1u<<TB_W)-1);
            latency[0]=(bits>>22)&7;latency[1]=(bits>>25)&7;
            unsigned before=records.size();tick();
            if(flush){expected_pc=d.redirect_pc;++redirects;}
            for(unsigned i=before;i<records.size();++i) {
                check(records[i].pc==expected_pc,"random flush/capacity preserves exact PC stream");
                check(!records[i].taken,"untrained prediction survives random flush/capacity");
                expected_pc+=4;++accepted;
            }
        }
        d.redirect_valid=0;d.rename_ready=1;d.backend_ready=1;
        d.decode_capacity=(1u<<TB_W)-1;
        for(unsigned cycle=0;cycle<128;++cycle) {
            unsigned before=records.size();tick();
            for(unsigned i=before;i<records.size();++i) {
                check(records[i].pc==expected_pc,"randomized stream drains without loss or duplication");
                expected_pc+=4;++accepted;
            }
        }
        check(redirects>500 && accepted>3000,"randomized flush/capacity exercises sustained progress");
        latency[0]=latency[1]=2;d.rename_ready=0;d.backend_ready=0;
    }
    void response_skew(int slow_bank) {
        reset();latency[0]=slow_bank==0?9:0;latency[1]=slow_bank==1?9:0;
        update(0,0x40);update(0x4c,0x90);update(0x90,0xc0);settle();redirect(0);
        // Fill every level while rename stalls, without stalling cache supply.
        d.backend_ready=1;d.rename_ready=0;
        for(int i=0;i<128;++i)tick();
        auto head=d.dec_uop;auto targets=d.dec_pred_target;
        auto taken=d.dec_pred_taken;auto valid=d.dec_valid;
        check(valid!=0,"stalled decode head is present");
        for(int i=0;i<12;++i) {
            tick();bool same=d.dec_valid==valid && d.dec_pred_taken==taken &&
                            d.dec_pred_target==targets;
            for(unsigned word=0;word<sizeof(head)/sizeof(uint32_t);++word)
                same= same && d.dec_uop[word]==head[word];
            check(same,"decode payload stable during rename stall");
        }
        for(int i=0;i<1024 && records.size()<24;++i) {
            d.backend_ready=i%7!=0;d.rename_ready=i%5!=0;tick();
        }
        check(records.size()>=24,"skewed mixed requests make progress");
        const uint32_t initial[]={0,0x40,0x44,0x48,0x4c,0x90};
        for(unsigned i=0;i<24 && i<records.size();++i) {
            uint32_t pc=i<6?initial[i]:0xc0+4*(i-6);
            bool pred=pc==0 || pc==0x4c || pc==0x90;
            uint32_t target=pc==0?0x40:pc==0x4c?0x90:0xc0;
            if(records[i].pc!=pc)std::printf("slow=%d i=%u expected=%x got=%x\n",
                                            slow_bank,i,pc,records[i].pc);
            check(records[i].pc==pc,"single/dual response order");
            check(records[i].taken==pred && (!pred || records[i].target==target),
                  "skewed response retains prediction snapshot");
        }
        // Clear queued responses and an outstanding refill under backpressure.
        d.rename_ready=0;d.backend_ready=1;
        for(int i=0;i<17;++i)tick();
        redirect(0x100);until(16);
        for(unsigned i=0;i<16 && i<records.size();++i)
            check(records[i].pc==0x100+4*i && !records[i].taken,
                  "redirect discards all old response queues");
        d.backend_ready=0;d.rename_ready=0;latency[0]=latency[1]=2;
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
    h.backend_stall_responses();h.partial_decode_capacity();h.response_skew(0);h.response_skew(1);
    for(uint32_t seed:{0x23ad4581u,0x6f9c20b3u,0xa3158e47u})h.randomized_flush_and_capacity(seed);
    std::printf("BPU training / response queues W=%d checks=%u fails=%u\n",TB_W,h.checks,h.fails);
    return h.fails?1:0;
}

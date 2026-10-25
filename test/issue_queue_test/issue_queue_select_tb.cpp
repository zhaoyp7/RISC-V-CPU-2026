// Independent slot scoreboard: sort eligible entries by (seq, physical slot),
// choose lane0 including prefill, then each full-ready lane excluding winners.
#include "Vissue_queue_select_top.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <vector>

constexpr int W=TB_W, R=TB_R, D=TB_D, IW=TB_IW, DW=150;
#ifndef TB_ALU_ONLY
#define TB_ALU_ONLY 0
#endif
using Bits=std::array<uint32_t,(DW+31)/32>;
template<class V> void put(V& v,int off,int width,uint32_t x) {
    for(int b=0;b<width;++b) {
        uint32_t mask=1u<<((off+b)%32);
        if((x>>b)&1) v[(off+b)/32]|=mask;
        else v[(off+b)/32]&=~mask;
    }
}
template<class V> uint32_t get(const V& v,int off,int width) {
    uint32_t x=0;
    for(int b=0;b<width;++b) x|=((v[(off+b)/32]>>((off+b)%32))&1u)<<b;
    return x;
}
struct Entry { bool valid=false, addr_sent=false, r1=false, r2=false;
    uint32_t seq=0; Bits bits{}; };
struct Stim {
    int n=0; std::array<Bits,W> bits{};
    uint32_t base=0, cut=0; bool squash=false;
    unsigned ready=0, wake_valid=0; uint32_t wake_tag=0;
};
struct Test {
    Vissue_queue_select_top& d;
    std::array<Entry,D> entries{};
    unsigned checks=0, fails=0, cycles=0;
    uint32_t random=0x6198face;
    uint32_t rng() { random^=random<<13; random^=random>>17; random^=random<<5; return random; }
    void check(bool ok,const char* msg) {
        ++checks;
        if(!ok && fails++<12) std::printf("FAIL cycle=%u: %s\n",cycles,msg);
    }
    void edge() { d.clk=0;d.eval();d.clk=1;d.eval();d.clk=0;d.eval(); }
    bool hit(const Stim& s,unsigned tag) {
        for (int r=0; r<R; ++r) {
            bool active = (s.wake_valid >> r) & 1u;
            unsigned value = (s.wake_tag >> (6*r)) & 63u;
            if (active && value == tag) return true;
        }
        return false;
    }
    Bits uop(bool store,bool r1,bool r2,unsigned t1,unsigned t2) {
        Bits b{};
        for(auto& x:b)x=rng();
        put(b,117,1,store);put(b,128,6,t1);put(b,134,1,r1);
        put(b,135,6,t2);put(b,141,1,r2);
        // Generate coherent instruction classes so the constrained-port
        // scoreboard exercises both supported and unsupported candidates.
        if(TB_ALU_ONLY) {
            put(b,102,1,1);put(b,103,5,rng()%14);
            for(int off=113;off<=118;++off)put(b,off,1,0);
            put(b,117,1,store);
            if(!store) {
                unsigned kind=rng()%12;
                if(kind<5)put(b,113+kind,1,1);
                else if(kind==5)put(b,118,1,1);
                else if(kind==6)put(b,102,1,0);
                else if(kind==7)put(b,103,5,14+rng()%4);
            }
        }
        return b;
    }
    bool lane1_ok(const Bits& b) {
        if(!get(b,102,1))return false;
        for(int off=113;off<=118;++off)if(get(b,off,1))return false;
        unsigned op=get(b,103,5);return op<14||op>17;
    }
    void reset() {
        entries={};d.reset=1;d.in_valid=0;d.in_alloc_mask=0;d.out_ready=0;
        d.wake_valid=0;d.wake_tag=0;d.squash_valid=0;d.squash_seq=0;d.seq_base=0;
        for(int i=0;i<(W*DW+31)/32;++i)d.in_uop[i]=0;
        edge();d.reset=0;d.eval();
    }
    void step(const Stim& s) {
        ++cycles;
        d.in_valid=(1u<<s.n)-1;d.in_alloc_mask=d.in_valid;d.seq_base=s.base;
        for(int i=0;i<(W*DW+31)/32;++i)d.in_uop[i]=0;
        for(int l=0;l<W;++l)for(int b=0;b<DW;++b)put(d.in_uop,l*DW+b,1,get(s.bits[l],b,1));
        d.wake_valid=s.wake_valid;d.wake_tag=s.wake_tag;
        d.out_ready=s.ready;d.squash_valid=s.squash;d.squash_seq=s.cut;d.eval();
        std::array<bool,D> killed{}, used{};
        std::vector<int> order;
        int count=0,free_after=0;
        for(int i=0;i<D;++i) {
            auto& e=entries[i];count+=e.valid;
            killed[i]=e.valid&&s.squash&&e.seq>s.cut;
            free_after+=!e.valid||killed[i];
            if(e.valid&&!killed[i])order.push_back(i);
        }
        std::sort(order.begin(),order.end(),[&](int a,int b){
            return entries[a].seq!=entries[b].seq ? entries[a].seq<entries[b].seq : a<b;
        });
        std::array<int,IW> sel;sel.fill(-1);
        std::array<bool,IW> pre{};
        for(int l=0;l<IW;++l)for(int i:order) {
            auto& e=entries[i];bool full=e.r1&&e.r2;
            bool pf=e.r1&&!e.r2&&get(e.bits,117,1)&&!e.addr_sent;
            bool supported=!(TB_ALU_ONLY&&l==1)||lane1_ok(e.bits);
            if(!used[i]&&supported&&(full||(l==0&&pf))) {sel[l]=i;used[i]=true;pre[l]=!full;break;}
        }
        check(d.count==count,"occupied count");check(d.free_count==D-count,"free count");
        bool accept=free_after>=s.n;
        check(bool(d.in_ready)==accept,"dispatch capacity after squash");
        for(int l=0;l<IW;++l) {
            check(bool(d.out_valid>>l&1)==(sel[l]>=0),"lane valid");
            check(bool(d.out_addr_only>>l&1)==pre[l],"prefill lane flag");
            if(sel[l]>=0) {
                check(uint32_t(d.out_seq>>(32*l))==entries[sel[l]].seq,"selected seq");
                bool bits_ok=true;
                for(int b=0;b<DW;++b)bits_ok &= get(d.out_uop,l*DW+b,1)==get(entries[sel[l]].bits,b,1);
                check(bits_ok,"selected uop all fields");
            }
        }
        std::array<int,W> slots{};std::array<bool,D> allocated{};
        for(int l=0;l<W;++l)for(int i=0;i<D;++i)
            if((!entries[i].valid||killed[i])&&!allocated[i]) {slots[l]=i;allocated[i]=true;break;}
        for(int i=0;i<D;++i) {
            auto& e=entries[i];
            if(killed[i]) {e.valid=false;e.addr_sent=false;e.r1=false;e.r2=false;}
            else if(e.valid) {e.r1|=hit(s,get(e.bits,128,6));e.r2|=hit(s,get(e.bits,135,6));}
        }
        for(int l=0;l<IW;++l)if(sel[l]>=0&&(s.ready>>l&1)) {
            auto& e=entries[sel[l]];if(pre[l])e.addr_sent=true;else e.valid=false;
        }
        if(accept)for(int l=0;l<s.n;++l) {
            auto& e=entries[slots[l]];e={};e.valid=true;e.seq=s.base+l;e.bits=s.bits[l];
            e.r1=get(e.bits,134,1)||hit(s,get(e.bits,128,6));
            e.r2=get(e.bits,141,1)||hit(s,get(e.bits,135,6));
        }
        edge();
    }
    void run() {
        reset();
        if(TB_ALU_ONLY&&IW==2) {
            // For every unsupported class, lane1 must skip it, reserve
            // lane0's oldest entry under backpressure, and retain the loser.
            for(int kind=0;kind<11;++kind) {
                reset();
                for(int n=0;n<4;++n) {
                    Stim t;t.n=1;t.base=10+n;
                    Bits b=uop(false,true,true,1,2);
                    put(b,102,1,1);put(b,103,5,0);
                    for(int off=113;off<=118;++off)put(b,off,1,0);
                    if(n==1) {
                        if(kind<6)put(b,113+kind,1,1);
                        else if(kind<10)put(b,103,5,14+kind-6);
                        else put(b,102,1,0);
                    }
                    t.bits[0]=b;step(t);
                }
                Stim t;t.ready=2;step(t); // oldest held; third issued
                t={};t.squash=true;t.cut=11;t.ready=3;step(t);
                t={};t.ready=3;step(t);step(t);
            }
            reset();
        }
        // Old partial store can prefill while an independently-ready lane issues.
        Stim s;s.n=1;s.base=10;s.bits[0]=uop(true,true,false,3,4);step(s);
        s={};s.n=1;s.base=20;s.bits[0]=uop(false,true,true,5,6);step(s);
        s={};s.ready=2;step(s); // lane0 stalled, lane1 accepted
        s.ready=1;step(s); // prefill accepted, store retained
        s.ready=3;step(s); // prefill must not repeat
        s.wake_valid=1;s.wake_tag=4;step(s); // wake doesn't select before edge
        s={};s.ready=3;step(s); // full store accepted
        // Boundary-age prefill/full candidates survive; younger candidates
        // must be suppressed on the squash edge even with consumers ready.
        for (int kind=0; kind<3; ++kind) {
            reset();
            Stim t;t.n=1;t.base=20;
            t.bits[0]=uop(kind==0,true,kind!=0,11,12);step(t);
            t={};t.n=1;t.base=10;
            t.bits[0]=uop(kind==1,true,kind!=1,13,14);step(t);
            t={};t.squash=true;t.cut=(kind==2)?9:10;
            t.ready=(1u<<IW)-1;step(t);
            // Once discarded, a wake must not resurrect the younger entry.
            t={};t.wake_valid=1;t.wake_tag=12;t.ready=(1u<<IW)-1;step(t);
            t.wake_tag=14;step(t);
            t={};t.ready=(1u<<IW)-1;step(t);
        }
        // Rebuild pairwise age state after reset, then reuse squashed slots.
        // Include a two-lane allocation crossing UINT32_MAX: age ordering is
        // unsigned numeric ordering, with physical-slot ties, even at wrap.
        reset();
        const uint32_t ages[] = {0xffffffffu,17,0x80000000u,0,17,7,0xfffffffeu,2};
        for (int filled=0, batch=0; filled<D; filled+=W, ++batch) {
            Stim t;t.n=std::min(W,D-filled);t.base=ages[batch%8];
            for (int l=0;l<W;++l)t.bits[l]=uop(false,true,true,11,12);
            step(t);
        }
        {
            Stim t;t.n=W;t.base=0xfffffffeu;t.squash=true;t.cut=17;
            for (int l=0;l<W;++l)t.bits[l]=uop(true,true,false,11,12);
            step(t);
        }
        for (int c=0;c<D+5;++c) {
            Stim t;t.ready=(1u<<IW)-1;
            if(c==2) {t.wake_valid=1;t.wake_tag=12;}
            step(t);
        }
        // Fill and free slots repeatedly with independent lane backpressure.
        // Equal seq, high seq bits, nonphysical age order, squash+dispatch,
        // registered wake and dispatch-wake bypass are checked cycle by cycle.
        for(int batch=0;batch<20;++batch) {
            reset();uint32_t base=rng()&0xffff0000u;
            for(int c=0;c<2000;++c) {
                Stim t;t.n=rng()%(W+1);t.base=base;
                for(int l=0;l<W;++l)t.bits[l]=uop((rng()%3)==0,rng()&1,rng()&1,rng()%64,rng()%64);
                t.ready=rng()% (1u<<IW);t.wake_valid=rng()%(1u<<R);
                for(int r=0;r<R;++r)t.wake_tag|=(rng()%64)<<(6*r);
                t.squash=(rng()%23)==0;t.cut=base;
                if(t.squash) {
                    int i=rng()%D;
                    if(entries[i].valid)t.cut=entries[i].seq;
                    else t.cut=base-(rng()%20);
                }
                step(t);base+=rng()%4; // includes equal ages, no wrap within batch
            }
        }
        std::printf("IQ select W=%d R=%d IW=%d D=%d ALU_ONLY=%d cycles=%u checks=%u fails=%u\n",W,R,IW,D,TB_ALU_ONLY,cycles,checks,fails);
    }
};
int main(int argc,char** argv) {
    VerilatedContext context;context.threads(1);context.commandArgs(argc,argv);
    Vissue_queue_select_top dut{&context};Test test{dut};test.run();return test.fails?1:0;
}

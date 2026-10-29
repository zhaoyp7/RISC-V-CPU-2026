#include "Vlsq.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
constexpr unsigned D=16,LW=4;
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);Vlsq d;unsigned long long checks=0,failures=0;uint32_t ages[D]={};
 auto check=[&](bool ok,const char*why){checks++;if(!ok&&failures++<8)std::printf("FAIL %s\n",why);};
 auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};
 auto clear=[&](){d.alloc_valid=0;d.alloc_id=0;d.alloc_rob=0;d.alloc_is_store=0;d.alloc_fire=0;d.seq_base=0;d.fill_valid=0;d.fill_id=0;d.fill_addr=0;d.fill_wdata=0;d.fill_wstrb=0;d.fill_is_store=0;d.prefill_valid=0;d.prefill_id=0;d.prefill_addr=0;d.prefill_data_tag=0;d.prefill_wstrb=0;for(unsigned i=0;i<3;i++)d.store_cdb[i]=0;d.commit_valid=0;d.commit_is_store=0;d.commit_is_load=0;d.commit_id=0;d.squash_valid=0;d.squash_seq=0;d.drain_fire=0;d.store_resp_valid=0;d.query_valid=0;d.query_seq=0;d.query_addr=0;d.query_resp_ready=1;d.query_flush=0;};
 auto allocate=[&](unsigned a,unsigned b,uint32_t age,bool pair){
  d.clk=0;d.alloc_valid=pair?3:1;d.alloc_is_store=d.alloc_valid;d.alloc_id=a|(b<<LW);d.seq_base=age;d.alloc_fire=1;d.eval();check(d.alloc_ready,"free slots allocate");tick();d.alloc_fire=0;d.alloc_valid=0;ages[a]=age;if(pair)ages[b]=age+1;
 };
 auto fill=[&](unsigned id,uint32_t address,uint32_t data){d.fill_valid=1;d.fill_id=id;d.fill_addr=address;d.fill_wdata=data;d.fill_wstrb=15;d.fill_is_store=1;tick();d.fill_valid=0;};
 uint32_t random=0x73a1b2c3u;
 auto rng=[&](){random^=random<<13;random^=random>>17;random^=random<<5;return random;};
 for(unsigned scenario=0;scenario<64;scenario++){
  clear();d.reset=1;tick();tick();d.reset=0;
  for(unsigned n=0;n<D;){
   unsigned a=(5*n+3)%D,b=(5*(n+1)+3)%D;bool pair=(n%4==0);
   uint32_t special[]={0u,1u,0x7fffffffu,0x80000000u,0xfffffffeu,0xffffffffu};
   uint32_t age=(scenario%2)?rng():special[(n/2+scenario)%6];
   allocate(a,b,age,pair);n+=pair?2:1;
  }
  for(unsigned i=0;i<D;i++)fill(i,0x1000,0xa5000000u+i);
  for(unsigned n=0;n<2048;n++){
   unsigned slot=rng()%D;fill(slot,(rng()&1)?0x1000:0x2000+4*slot,0xa5000000u+slot);
   // Keep an independent address model, including the immediately applied fill.
   static bool matching[D];
   if(n==0)for(unsigned i=0;i<D;i++)matching[i]=true;
   matching[slot]=d.fill_addr==0x1000;
   uint32_t threshold=(n%3)?rng():ages[rng()%D];
   d.query_valid=1;d.query_seq=threshold;d.query_addr=0x1000;tick();d.query_valid=0;d.eval();
   int best=-1;for(unsigned i=0;i<D;i++)if(matching[i]&&ages[i]<threshold)
    if(best<0||ages[i]>ages[best])best=i;
   check(d.query_resp_valid,"boundary query snapshot valid");
   check(!d.query_blocked,"known boundary stores never block");
   check(bool(d.query_fwd_valid)==(best>=0),"strict full-width query age predicate");
   if(best>=0)check(d.query_fwd_data==0xa5000000u+unsigned(best),"boundary youngest and equal-age tie rule");
   tick();
  }
 }
 std::printf("LSQ_AGE_BOUNDARIES checks=%llu failures=%llu\n",checks,failures);return failures?1:0;
}

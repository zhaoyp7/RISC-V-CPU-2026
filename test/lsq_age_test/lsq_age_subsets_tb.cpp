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
 for(unsigned scenario=0;scenario<3;scenario++){
  clear();d.reset=1;tick();tick();d.reset=0;
  for(unsigned n=0;n<D;){
   unsigned a=(5*n+3)%D,b=(5*(n+1)+3)%D;bool pair=scenario==2;
   uint32_t age=scenario==1?100000u:0x10000u+((n*7)%D)*11u;
   allocate(a,b,age,pair);n+=pair?2:1;
  }
  for(unsigned i=0;i<D;i++)fill(i,0x2000+4*i,0xa5000000u+i);
  unsigned previous=0;
  for(unsigned n=0;n<(1u<<D);n++){
   unsigned mask=n^(n>>1);
   if(n){unsigned changed=__builtin_ctz(mask^previous);fill(changed,(mask>>changed)&1?0x1000:0x2000+4*changed,0xa5000000u+changed);}
   previous=mask;d.query_valid=1;d.query_seq=0xffffffffu;d.query_addr=0x1000;tick();d.query_valid=0;d.eval();
   int best=-1;for(unsigned i=0;i<D;i++)if((mask>>i)&1)if(best<0||ages[i]>ages[best])best=i;
   check(d.query_resp_valid,"query owns a snapshot");check(!d.query_blocked,"known full stores do not block");check(bool(d.query_fwd_valid)==(best>=0),"found store matches independent full-width scan");if(best>=0)check(d.query_fwd_data==0xa5000000u+unsigned(best),"youngest store data and low-slot tie rule");tick();
  }
  // Hold a live query while all original owners are removed and reused.
  for(unsigned i=0;i<D;i++)fill(i,0x1000,0xa5000000u+i);
  int best=0;for(unsigned i=1;i<D;i++)if(ages[i]>ages[best])best=i;
  d.query_valid=1;d.query_resp_ready=0;tick();d.query_valid=0;d.squash_valid=1;d.squash_seq=0;tick();d.squash_valid=0;
  for(unsigned i=0;i<D;i++){
   allocate(i,0,0xb0000000u-i,false);fill(i,0x1000,0x5a000000u+i);d.eval();
   check(d.query_resp_valid&&d.query_fwd_valid,"held response survives owner reuse");check(d.query_fwd_data==0xa5000000u+unsigned(best),"held snapshot keeps old age and payload");
  }
  d.query_resp_ready=1;tick();
 }
 std::printf("LSQ_AGE_SUBSETS checks=%llu failures=%llu\n",checks,failures);return failures?1:0;
}

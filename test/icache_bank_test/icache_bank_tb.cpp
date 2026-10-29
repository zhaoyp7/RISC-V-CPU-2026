#include "Vicache_banked_top.h"
using Vicache_pipe=Vicache_banked_top;
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
struct Bench {
 Vicache_pipe d;
 std::deque<uint32_t> expected;
 uint32_t random=0x3458ab91, bank=0;
 uint64_t cycles=0,checks=0,refills=0,due=0;
 uint32_t address=0,held_pc=0,held_inst=0;
 bool pending=false,held=false;
 uint32_t rng(){random^=random<<13;random^=random>>17;random^=random<<5;return random;}
 static uint32_t word(uint32_t a){return (a*0x9e3779b9u)^0xa35109cdu;}
 void check(bool ok,const char* why){checks++;if(!ok){std::fprintf(stderr,"FAIL bank=%u cycle=%llu %s\n",bank,(unsigned long long)cycles,why);std::exit(1);}}
 bool step(bool valid=false,uint32_t pc=0,bool ready=true,bool flush=false){
  d.clk=0;d.fetch_valid=valid;d.fetch_pc=pc;d.fetch_resp_ready=ready;d.flush=flush;d.discard=0;d.refill_resp_valid=0;d.eval();
  if(!pending&&d.refill_valid){pending=true;address=d.refill_addr;due=cycles+1+rng()%17;refills++;check((address&7)==bank*4,"refill uses physical bank parity");}
  if(pending)check(d.refill_valid&&d.refill_addr==address,"outstanding refill stable across flush");
  bool returned=pending&&cycles>=due;d.refill_resp_valid=returned;d.refill_rdata=returned?word(address):0;d.eval();
  if(d.reset||flush)expected.clear();
  if(held&&!flush&&!d.reset)check(d.fetch_resp_valid&&d.fetch_resp_pc==held_pc&&d.fetch_inst==held_inst,"response stable under backpressure");
  if(!d.reset&&!flush&&d.fetch_resp_valid&&ready){check(!expected.empty(),"no unsolicited response");uint32_t want=expected.front();expected.pop_front();check(d.fetch_resp_pc==want&&d.fetch_inst==word(want),"ordered PC and value");}
  bool accepted=!d.reset&&d.fetch_valid&&d.fetch_ready;
  if(accepted)expected.push_back(pc);
  held=!d.reset&&!flush&&d.fetch_resp_valid&&!ready;held_pc=d.fetch_resp_pc;held_inst=d.fetch_inst;
  d.clk=1;d.eval();if(returned)pending=false;cycles++;return accepted;
 }
 void drain(){for(int i=0;!expected.empty()||pending;i++){check(i<10000,"drain progress");step();}for(int i=0;i<8;i++)step();}
 void load(uint32_t pc){for(int i=0;!step(true,pc);i++)check(i<10000,"request progress");drain();}
 void run(){d.reset=1;for(int i=0;i<3;i++)step();d.reset=0;
  constexpr unsigned lines=1u<<TB_INDEX_BITS;
  for(unsigned i=0;i<lines;i++)load(0x1000+i*8+bank*4);
  uint64_t before=refills;
  for(unsigned i=0;i<lines;i++)load(0x1000+i*8+bank*4);
  check(refills==before,"all SRAM rows retain distinct words");
  for(unsigned i=0;i<lines;i++)load(0x1000+(i+lines)*8+bank*4);
  for(int i=0;i<100000;i++){
   uint32_t x=rng(),a=(x&31)?(0x2000+(rng()%(2*lines))*8):(rng()&0xfff8);
   step((x&3)!=0,a+bank*4,(x&12)!=0,x%97==0);
  }
  drain();std::printf("icache bank=%u index=%d PASS checks=%llu refills=%llu cycles=%llu\n",bank,TB_INDEX_BITS,(unsigned long long)checks,(unsigned long long)refills,(unsigned long long)cycles);
 }
};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Bench b;b.bank=argc>1?unsigned(std::strtoul(argv[1],nullptr,0)):0;b.run();}

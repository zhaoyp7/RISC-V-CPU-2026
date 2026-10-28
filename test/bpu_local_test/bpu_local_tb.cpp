#include "Vbpu.h"
#include "verilated.h"
#include <array>
#include <random>
#include <cstdio>
#include <cstdlib>
#ifndef TB_HISTORY
#define TB_HISTORY 2
#endif
struct Entry{bool valid=false,uncond=false;unsigned pc=0,target=0,history=0;std::array<unsigned,1<<TB_HISTORY> counters{};};
struct Update{bool valid,taken,uncond;unsigned pc,target;};
struct Bench{
 Vbpu d;std::array<Entry,32> table{};std::mt19937 rng{20261028};unsigned checks=0,cycles=0;
 [[noreturn]] void fail(const char*s){std::fprintf(stderr,"FAIL local-history H=%d cycle=%u %s\n",TB_HISTORY,cycles,s);std::exit(1);}
 unsigned sat(unsigned n,bool t){return t?(n==3?3:n+1):(n?n-1:0);}
 void check(unsigned pc,bool got,unsigned target,const Update&u){
  Entry e=table[(pc>>2)%32];auto old=table[(u.pc>>2)%32];bool hit=old.valid&&old.pc==u.pc;unsigned counter=e.counters[e.history];
  if(u.valid&&(pc>>2)%32==(u.pc>>2)%32){
   if(u.uncond||u.taken){e.valid=true;e.pc=u.pc;e.target=u.target;e.uncond=u.uncond;}else if(hit)e.uncond=false;
   if(u.uncond)counter=3;else if(u.taken)counter=hit?sat(old.counters[old.history],true):2;else if(hit)counter=sat(old.counters[old.history],false);
  }
  bool match=e.valid&&e.pc==pc;bool expected=match&&(e.uncond||counter>=2);++checks;
  if(got!=expected||target!=(match?e.target:0))fail("dual-port prediction/reference mismatch");
 }
 void reset(){d.reset=1;d.upd_valid=0;d.clk=0;d.eval();d.clk=1;d.eval();for(auto&e:table)e.valid=false;d.reset=0;}
 bool step(unsigned pc,unsigned pc2,Update u){
  d.clk=0;d.fetch_pc=pc;d.fetch_pc2=pc2;d.upd_valid=u.valid;d.upd_pc=u.pc;d.upd_taken=u.taken;d.upd_is_uncond=u.uncond;d.upd_target=u.target;d.eval();
  check(pc,d.predict_taken,d.predict_target,u);check(pc2,d.predict_taken2,d.predict_target2,u);bool pred=d.predict_taken;
  if(u.valid){auto&e=table[(u.pc>>2)%32];bool hit=e.valid&&e.pc==u.pc;
   if(u.uncond){e.valid=true;e.pc=u.pc;e.target=u.target;e.uncond=true;e.history=0;e.counters.fill(3);}
   else if(u.taken){if(!hit){e.counters.fill(2);e.history=1;}else{e.counters[e.history]=sat(e.counters[e.history],true);e.history=((e.history<<1)|1)&((1<<TB_HISTORY)-1);}e.valid=true;e.pc=u.pc;e.target=u.target;e.uncond=false;}
   else if(hit){e.uncond=false;e.counters[e.history]=sat(e.counters[e.history],false);e.history=(e.history<<1)&((1<<TB_HISTORY)-1);}
  }
  d.clk=1;d.eval();d.clk=0;d.upd_valid=0;d.eval();check(pc,d.predict_taken,d.predict_target,{false,false,false,0,0});check(pc2,d.predict_taken2,d.predict_target2,{false,false,false,0,0});++cycles;return pred;
 }
 void run(){reset();for(unsigned n=0;n<100000;++n){if(n%997==0)reset();unsigned pc=(rng()%512)*4,pc2=(rng()%512)*4;Update u{rng()%4!=0,bool(rng()%2),rng()%5==0,(rng()%512)*4,(rng()%4096)*4};if(n%3==0)pc=u.pc;if(n%5==0)pc2=u.pc;step(pc,pc2,u);}
  reset();unsigned errors=0;
  for(unsigned n=0;n<512;++n){bool taken=n%2;bool pred=step(0x100,0x104,{false,false,false,0,0});if(n>=32&&pred!=taken)++errors;step(0x104,0x100,{true,taken,false,0x100,0x200});}
  if(errors>2)fail("failed to learn alternating branch pattern");
  std::printf("PASS local-history H=%d checks=%u alternating_errors_after_warmup=%u\n",TB_HISTORY,checks,errors);
 }
};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Bench b;b.run();}

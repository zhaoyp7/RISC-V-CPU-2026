#include "Vload_line_cache.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <unordered_map>
#include <random>
struct Read { uint64_t due; uint32_t data,addr; };
struct Expected { uint32_t addr,data; };
struct Bench {
 Vload_line_cache d;
 std::mt19937 rng{20261026};
 std::unordered_map<uint32_t,uint32_t> ram;
 std::deque<Read> rd;
 std::deque<uint64_t> bs;
 std::deque<Expected> expected;
 uint64_t cycle=0,checks=0,requests=0,responses=0,external=0;
 uint64_t first_return=uint64_t(-1),first_response=uint64_t(-1);
 unsigned latency=10;
 bool stalls=true;
 uint32_t word(uint32_t a) { a&=~3u; auto it=ram.find(a);return it==ram.end() ? ((a*0x9e3779b9u)^0xa5b6c7d8u):it->second; }
 [[noreturn]] void fail(const char* why,uint32_t a=0,uint32_t got=0,uint32_t want=0){
  std::fprintf(stderr,"FAIL cycle=%llu %s addr=%08x got=%08x want=%08x\n",(unsigned long long)cycle,why,a,got,want);std::exit(1);
 }
 bool tick(bool v=false,uint32_t a=0,bool st=false,uint32_t sa=0,uint32_t data=0,uint8_t mask=15){
  d.clk=0;d.req_valid=v;d.req_addr=a;d.store_fire=0;
  d.store_addr=sa;d.store_data=data;d.store_mask=mask;
  d.mem_ready=!stalls || rng()%5!=0;
  d.mem_resp_valid=!rd.empty() && rd.front().due<=cycle;
  d.mem_resp_data=d.mem_resp_valid?rd.front().data:0;
  d.store_resp_valid=!bs.empty() && bs.front()<=cycle;
  d.eval();
  if(st && d.store_ready){d.store_fire=1;d.eval();}
  bool accepted=v&&d.req_ready, sf=d.store_fire;
  if(accepted){expected.push_back({a,word(a)});requests++;}
  if(d.resp_valid){
   if(first_response==uint64_t(-1))first_response=cycle;
   if(expected.empty())fail("unsolicited load response");
   auto e=expected.front();expected.pop_front();
   checks++;responses++;
   if(d.resp_data!=e.data)fail("ordered load value",e.addr,d.resp_data,e.data);
  }
  if(d.mem_resp_valid){if(first_return==uint64_t(-1))first_return=cycle;rd.pop_front();}
  if(d.store_resp_valid)bs.pop_front();
  if(d.mem_valid&&d.mem_ready){
   uint64_t due=cycle+latency+(stalls?rng()%7:0);
   if(!rd.empty()&&due<=rd.back().due)due=rd.back().due+1;
   rd.push_back({due,word(d.mem_addr),d.mem_addr});external++;
  }
  if(sf){
   uint32_t old=word(sa),m=0;for(int i=0;i<4;i++)if(mask>>i&1)m|=255u<<(i*8);
   ram[sa&~3u]=(old&~m)|(data&m);
   uint64_t due=cycle+latency+3;if(!bs.empty()&&due<=bs.back())due=bs.back()+1;bs.push_back(due);
  }
  d.clk=1;d.eval();cycle++;
  return st?sf:accepted;
 }
 void reset(){d.reset=1;for(int i=0;i<3;i++)tick();d.reset=0;}
 void load(uint32_t a){for(int n=0;!tick(true,a);n++)if(n>20000)fail("request timeout",a);}
 void drain(){for(int n=0;!expected.empty()||!rd.empty()||!bs.empty();n++){if(n>100000)fail("drain timeout");tick();}for(int i=0;i<8;i++)tick();}
 void wait_loads(){for(int n=0;!expected.empty();n++){if(n>100000)fail("load timeout");tick();}}
 void store(uint32_t a,uint32_t v,uint8_t mask){for(int n=0;!tick(false,0,true,a,v,mask);n++)if(n>100000)fail("store timeout");}
};
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);Bench b;b.reset();
 // Cold fills, all offsets, hot-hit stream, and two independent outstanding lines.
 for(unsigned k=0;k<4;k++)for(unsigned i=0;i<64;i++)b.load(0x1000+i*4);
 b.drain();
 uint64_t before=b.external;
 for(unsigned i=0;i<128;i++)b.load(0x1000+(i%64)*4);
 b.drain();b.checks++;if(b.external!=before)b.fail("hot hits caused external reads");
 // Warm hits queued behind a cold miss must preserve the LSU response order.
 b.load(0x3000);for(int i=0;i<6;i++)b.load(0x1000+i*4);b.drain();
 // Multiple same-word waiters and words arriving while another request enters.
 for(int k=0;k<12;k++){for(int i=0;i<8;i++)b.load(0x5000+k*32+(i%3)*4);b.drain();}
 // Same-index different-tag replacements plus uncached words.
 for(unsigned i=0;i<50;i++){b.load(0x2000+(i%3)*4096+(i%8)*4);b.load(0x80001000+(i%8)*4);}b.drain();
 // Cached byte-mask updates and write-miss/refill races after early completion.
 for(unsigned i=0;i<64;i++){
  uint32_t a=0x8000+i*32+(i%8)*4;
  b.load(a);b.wait_loads(); // other words of this fill can still be outstanding
  b.store(a,0x10203040u+i,uint8_t(1u<<(i%4)));
  while(!b.bs.empty())b.tick();
  b.load(a);b.load((a&~31u)+((i+3)%8)*4);b.drain();
  b.store(a,0xfedcba98u-i,15);while(!b.bs.empty())b.tick();
  b.load(a);b.drain();
 }
 // Randomized streams against a separate byte-mask memory reference.
 for(unsigned round=0;round<300;round++){
  for(unsigned n=0;n<40;n++)b.load(0x10000+(b.rng()%2048)*4);
  b.wait_loads();
  for(unsigned n=0;n<4;n++)b.store(0x10000+(b.rng()%2048)*4,b.rng(),1+b.rng()%15);
  while(!b.bs.empty())b.tick();
 }
 b.drain();b.checks++;if(b.requests!=b.responses)b.fail("response count mismatch");
 // Latency extremes, with and without request backpressure.
 for(unsigned lat:{1u,50u}){b.latency=lat;b.stalls=(lat==50);for(unsigned i=0;i<200;i++)b.load(0x50000+(i%80)*4);b.drain();}
 std::printf("line_cache: PASS checks=%llu requests=%llu responses=%llu external=%llu cycles=%llu\n",(unsigned long long)b.checks,(unsigned long long)b.requests,(unsigned long long)b.responses,(unsigned long long)b.external,(unsigned long long)b.cycle);
}

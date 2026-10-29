#include "Vmul_booth_wallace.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
int main(int argc,char**argv) {
 VerilatedContext context;context.threads(1);context.commandArgs(argc,argv);
 Vmul_booth_wallace dut{&context};uint64_t checks=0,failures=0;
 auto check=[&](uint32_t a,uint32_t b) {
  for(unsigned signs=0;signs<4;++signs) {
  dut.a=a;dut.b=b;dut.a_signed=signs&1;dut.b_signed=(signs>>1)&1;dut.eval();
  uint64_t ax=a,bx=b;
  if((signs&1)&&(a>>31))ax-=uint64_t(1)<<32;
  if((signs&2)&&(b>>31))bx-=uint64_t(1)<<32;
  uint64_t want=ax*bx;++checks;
  if(uint64_t(dut.product)!=want) {
   if(failures++<12)std::printf("FAIL a=%08x b=%08x got=%016llx want=%016llx\n",a,b,(unsigned long long)dut.product,(unsigned long long)want);
  }
  }
 };
 uint32_t edge[]={0,1,2,3,0xffffffffu,0xfffffffeu,0x80000000u,0x7fffffffu,0xaaaaaaaau,0x55555555u,0xccccccccu,0x33333333u,0x80000001u,0xc0000000u};
 for(auto a:edge)for(auto b:edge)check(a,b);
 for(unsigned i=0;i<32;++i)for(unsigned j=0;j<32;++j) {
  check(uint32_t(1)<<i,uint32_t(1)<<j);
  check(~(uint32_t(1)<<i),uint32_t(1)<<j);
  check(~(uint32_t(1)<<i),~(uint32_t(1)<<j));
 }
 uint64_t state=0x51e47b0a93d2c68full;
 auto random=[&](){state^=state<<13;state^=state>>7;state^=state<<17;return uint32_t(state);};
 for(unsigned n=0;n<1000000;++n){uint32_t a=random(),b=random();check(a,b);}
 std::printf("Booth/pseudo-Wallace all signedness32x32 checks=%llu failures=%llu\n",(unsigned long long)checks,(unsigned long long)failures);
 return failures?1:0;
}

#include "Vcore_admission_top.h"
#include "verilated.h"
#include <cstdio>
#ifndef TB_W
#define TB_W 2
#endif
int main(int argc,char**argv){
 VerilatedContext c;c.threads(1);c.commandArgs(argc,argv);Vcore_admission_top d{&c};
 unsigned checks=0,fails=0;auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};
 d.reset=1;d.backend_ready=0;d.free_ready=0;d.rob_ready=0;tick();d.reset=0;
 for(unsigned repeat=0;repeat<3;repeat++)for(unsigned bits=0;bits<8;bits++){
  d.backend_ready=(bits>>2)&1;d.rob_ready=(bits>>1)&1;d.free_ready=bits&1;
  d.clk=0;d.eval();unsigned expected=bits==7 ? (1u<<TB_W)-1 : 0;
  for(unsigned got:{unsigned(d.dispatched),unsigned(d.rob_received),unsigned(d.rename_received)}){
   ++checks;if(got!=expected){++fails;printf("FAIL admission controls=%u got=%u expected=%u\n",bits,got,expected);}
  }tick();
 }
 d.final();printf("core_admission W=%d checks=%u fails=%u\n",TB_W,checks,fails);
 puts(fails?"FAIL":"PASS");return fails?1:0;
}

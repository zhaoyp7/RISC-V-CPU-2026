#include "Vcdb_guarantee_top.h"
using Vcdb=Vcdb_guarantee_top;
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <type_traits>
#ifndef TB_R
#define TB_R 2
#endif
constexpr unsigned R=TB_R,PW=6,CW=40;
template<class T>unsigned field(T const &v,unsigned off,unsigned width){unsigned z=0;for(unsigned i=0;i<width;i++){unsigned b;if constexpr(std::is_integral_v<T>)b=(uint64_t(v)>>(off+i))&1;else b=(v[(off+i)/32]>>((off+i)%32))&1;z|=b<<i;}return z;}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Vcdb d;unsigned checks=0,fails=0;
 auto expect=[&](bool b,const char*s){checks++;if(!b&&fails++<8)std::printf("FAIL %s\n",s);};
 for(unsigned state=0;state<4;state++){
  d.clk=0;d.reset=1;d.src_valid=0;d.eval();d.clk=1;d.eval();d.reset=0;
  for(unsigned n=0;n<state;n++){d.clk=0;d.src_valid=1;d.eval();d.clk=1;d.eval();}
  for(unsigned mask=0;mask<8;mask++){
   unsigned actual[2],hint[2];unsigned compute=(mask&3)|((mask&4)<<1);
   for(unsigned load=0;load<2;load++){
    d.clk=0;d.src_valid=compute|(load<<2);d.src_tag=1u|(2u<<6)|(3u<<12)|(4u<<18);for(unsigned i=0;i<4;i++)d.src_value[i]=0x11111111u*(i+1);d.src_exception=0;d.eval();actual[load]=d.src_ready;hint[load]=d.hint_ready_mask;
    unsigned seen=0;for(unsigned lane=0;lane<R;lane++)if(field(d.cdb_out,lane*CW,1)){unsigned tag=field(d.cdb_out,lane*CW+1,PW);expect(tag>=1&&tag<=4,"real source tag");unsigned bit=1u<<(tag-1);expect(!(seen&bit),"unique source grant");expect(d.src_valid&bit,"only valid source granted");seen|=bit;expect(field(d.cdb_out,lane*CW+7,32)==0x11111111u*tag,"source value");}expect(seen==actual[load],"ready exactly matches bus outputs");
   }
   unsigned expected=R>=2?(actual[0]&actual[1]&~4u):0;
   expect(hint[0]==hint[1],"guarantee independent of optional source");expect(hint[0]==expected,"guarantee exactly intersects both possible actual grants");
  }
 }
 std::printf("CDB_GUARANTEE R=%u checks=%u fails=%u\n",R,checks,fails);return fails?1:0;
}

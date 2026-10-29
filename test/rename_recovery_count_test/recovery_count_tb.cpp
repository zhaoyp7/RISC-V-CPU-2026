#include "Vrecovery_count_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <type_traits>
#ifndef TB_PRF
#define TB_PRF 64
#endif
template<class T>void clear(T&v){if constexpr(std::is_integral_v<T>)v=0;else for(unsigned i=0;i<(TB_PRF+31)/32;i++)v[i]=0;}
template<class T>void setbit(T&v,unsigned i){if constexpr(std::is_integral_v<T>)v|=T(1)<<i;else v[i/32]|=1u<<(i%32);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Vrecovery_count_top d;uint64_t rng=0x91827365abcdef03ull;unsigned checks=0,fails=0;
for(unsigned trial=0;trial<100000;trial++){clear(d.mask);unsigned expected=0;
 for(unsigned i=0;i<TB_PRF;i++){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;bool bit=(rng>>63)!=0;
 if(trial==0)bit=false;if(trial==1)bit=true;if(trial>=2&&trial<2+TB_PRF)bit=i==trial-2;
 if(bit){setbit(d.mask,i);expected+=i!=0;}}
 d.eval();checks++;if(d.count!=expected){if(fails++<5)std::printf("trial=%u count=%u expected=%u\n",trial,unsigned(d.count),expected);}}
std::printf("RECOVERY_COUNT_REFERENCE PRF=%u checks=%u fails=%u\n",TB_PRF,checks,fails);return fails?1:0;}

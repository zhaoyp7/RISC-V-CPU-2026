#ifndef TB_READ_ADDRESS_SLOTS
#define TB_READ_ADDRESS_SLOTS 16
#endif
#ifndef TB_WRITE_ADDRESS_SLOTS
#define TB_WRITE_ADDRESS_SLOTS 8
#endif
#include "Vaxi_mem_if.h"
#include "verilated.h"
#include <deque>
#include <random>
#include <cstdio>
#include <cstdlib>
struct Write {unsigned addr,data,mask;};
struct Bench {
 Vaxi_mem_if d; std::mt19937 rng{20261028};
 std::deque<unsigned> reads; std::deque<Write> aw,w;
 unsigned accepted_r=0,accepted_w=0,sent_r=0,sent_aw=0,sent_w=0,returned_r=0,returned_w=0,checks=0,cycle=0;
 [[noreturn]] void fail(const char* s){std::fprintf(stderr,"FAIL AXI credit cycle=%u %s\n",cycle,s);std::exit(1);}
 void check(bool ok,const char* s){++checks;if(!ok)fail(s);}
 void step(bool produce,bool addresses,bool responses,bool random=false){
  d.clk=0; d.rd_valid=produce;d.rd_addr=0x1000+accepted_r*4;
  d.wr_valid=produce;d.wr_addr=0x100000+accepted_w*4;d.wr_wdata=accepted_w^0x95316724;d.wr_wstrb=(accepted_w%15)+1;
  d.arready=addresses&&(!random||rng()%4);d.awready=addresses&&(!random||rng()%3);d.wready=addresses&&(!random||rng()%5);
  d.rvalid=responses&&returned_r<sent_r&&(!random||rng()%3);d.rdata=returned_r^0x3579abcd;d.rresp=0;
  d.bvalid=responses&&returned_w<sent_aw&&returned_w<sent_w&&(!random||rng()%4);d.bresp=0;d.eval();
  if(d.rd_valid&&d.rd_ready){reads.push_back(d.rd_addr);++accepted_r;}
  if(d.wr_valid&&d.wr_ready){Write x{d.wr_addr,d.wr_wdata,d.wr_wstrb};aw.push_back(x);w.push_back(x);++accepted_w;}
  if(d.arvalid){check(!reads.empty(),"AR without request");check(d.araddr==reads.front(),"AR address order/hold");if(d.arready){reads.pop_front();++sent_r;}}
  if(d.awvalid){check(!aw.empty(),"AW without request");check(d.awaddr==aw.front().addr,"AW address order/hold");if(d.awready){aw.pop_front();++sent_aw;}}
  if(d.wvalid){check(!w.empty(),"W without request");auto x=w.front();check(d.wdata==x.data&&d.wstrb==x.mask,"W payload order/hold");if(d.wready){w.pop_front();++sent_w;}}
  check(d.rready&&d.bready,"response channels remain ready");
  check(bool(d.rd_resp_valid)==bool(d.rvalid),"read response lost");if(d.rvalid){check(d.rd_resp_rdata==d.rdata,"read response value");++returned_r;}
  check(bool(d.wr_resp_valid)==bool(d.bvalid),"write response lost");if(d.bvalid)++returned_w;
  check(accepted_r-returned_r<=16,"read credit overflow");check(accepted_w-returned_w<=8,"write credit overflow");
  d.clk=1;d.eval();++cycle;
 }
 void run(){
  d.reset=1;for(int i=0;i<3;++i)step(false,false,false);d.reset=0;
  for(int round=0;round<8;++round){
   unsigned nr=accepted_r,nw=accepted_w;
   for(int i=0;i<24;++i)step(true,false,false);
   check(accepted_r-nr==TB_READ_ADDRESS_SLOTS,"read address FIFO capacity");check(accepted_w-nw==TB_WRITE_ADDRESS_SLOTS,"write address FIFO capacity");
   for(int i=0;i<40;++i)step(true,true,false,true);
   check(accepted_r-nr==16&&accepted_w-nw==8,"dispatched requests prematurely free credits");
   for(int i=0;i<2000;++i)step(true,true,true,true);
   for(int i=0;i<1000&&(returned_r!=accepted_r||returned_w!=accepted_w);++i)step(false,true,true,true);
   check(returned_r==accepted_r&&returned_w==accepted_w,"drain lost responses");check(reads.empty()&&aw.empty()&&w.empty(),"drain lost requests");
  }
  std::printf("PASS AXI read16/write8 credits, independent AW/W, ring wrap: %u checks %u reads %u writes\n",checks,accepted_r,accepted_w);
 }
};
int main(int argc,char** argv){Verilated::commandArgs(argc,argv);Bench b;b.run();}

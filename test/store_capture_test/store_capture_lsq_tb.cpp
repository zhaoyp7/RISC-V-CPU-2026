#include "Vstore_capture_lsq_top.h"
using Vlsq=Vstore_capture_lsq_top;
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <vector>
constexpr unsigned D=TB_DEPTH,W=TB_W,PW=6,CW=40;
constexpr unsigned idx_width(unsigned n){unsigned w=0;while(n>1){n>>=1;w++;}return w;}
constexpr unsigned LW=idx_width(D);
struct Bench {
 Vlsq d;unsigned checks=0,fails=0;uint32_t random=0x629cf18b;
 uint32_t rng(){random^=random<<13;random^=random>>17;random^=random<<5;return random;}
 void check(bool ok,const char* msg){checks++;if(!ok&&fails++<20)std::printf("FAIL %s checks=%u\n",msg,checks);}
 template<class T>static void put(T&v,unsigned off,unsigned width,uint32_t value){for(unsigned b=0;b<width;b++){uint32_t mask=1u<<((off+b)%32);if(value>>b&1)v[(off+b)/32]|=mask;else v[(off+b)/32]&=~mask;}}
 void clear_cdb(){for(unsigned i=0;i<3;i++)d.store_cdb[i]=0;}
 void cdb(unsigned tag,uint32_t value,unsigned lane=0){put(d.store_cdb,lane*CW,1,1);put(d.store_cdb,lane*CW+1,PW,tag);put(d.store_cdb,lane*CW+1+PW,32,value);}
 void tick(){d.clk=0;d.eval();d.clk=1;d.eval();d.clk=0;d.eval();}
 void reset(){d.reset=1;d.alloc_valid=0;d.alloc_fire=0;d.alloc_id=0;d.alloc_rob=0;d.alloc_is_store=0;d.seq_base=0;d.fill_valid=0;d.fill_id=0;d.fill_addr=0;d.fill_wdata=0;d.fill_wstrb=0;d.fill_is_store=1;d.prefill_valid=0;d.prefill_id=0;d.prefill_addr=0;d.prefill_data_tag=0;d.prefill_wstrb=0;d.commit_valid=0;d.commit_is_store=0;d.commit_is_load=0;d.commit_id=0;d.squash_valid=0;d.squash_seq=0;d.drain_fire=0;d.store_resp_valid=0;d.query_valid=0;d.query_seq=0;d.query_addr=0;d.query_resp_ready=0;d.query_flush=0;clear_cdb();tick();tick();d.reset=0;tick();}
 void alloc(unsigned id,unsigned seq,bool store=true){d.alloc_valid=1;d.alloc_id=id;d.alloc_is_store=store;d.alloc_fire=1;d.seq_base=seq;d.eval();check(d.alloc_ready,"allocation accepted");tick();d.alloc_valid=0;d.alloc_fire=0;d.eval();}
 void prefill(unsigned id,uint32_t addr,unsigned tag,unsigned mask){d.prefill_valid=1;d.prefill_id=id;d.prefill_addr=addr;d.prefill_data_tag=tag;d.prefill_wstrb=mask;tick();d.prefill_valid=0;d.eval();}
 void fill(unsigned id,uint32_t addr,uint32_t value,unsigned mask=15){d.fill_valid=1;d.fill_id=id;d.fill_addr=addr;d.fill_wdata=value;d.fill_wstrb=mask;tick();d.fill_valid=0;d.eval();}
 void commit(unsigned id){d.commit_valid=1;d.commit_is_store=1;d.commit_id=id;tick();d.commit_valid=0;d.commit_is_store=0;d.eval();}
 void broadcast(unsigned tag,uint32_t value,unsigned lane=0){cdb(tag,value,lane);tick();clear_cdb();d.eval();}
 void query(unsigned seq,uint32_t addr,bool blocked,bool forward,uint32_t data=0){d.query_valid=1;d.query_seq=seq;d.query_addr=addr;d.eval();check(d.query_ready,"query accepted");tick();d.query_valid=0;d.eval();check(d.query_resp_valid,"query response valid");check(bool(d.query_blocked)==blocked,"query block state");check(bool(d.query_fwd_valid)==forward,"query forward state");if(forward)check(d.query_fwd_data==data,"query data");}
 void consume(){d.query_resp_ready=1;tick();d.query_resp_ready=0;d.eval();}
 void expect_drain(unsigned id,uint32_t addr,uint32_t value,unsigned mask){d.eval();check(d.drain_valid,"oldest data-ready store valid");check(d.drain_id==id,"store order");check(d.drain_addr==addr,"store address");check(d.drain_wdata==value,"store aligned value");check(d.drain_wstrb==mask,"store byte enables");}
 void send(){d.drain_fire=1;tick();d.drain_fire=0;d.eval();}
 void response(){d.store_resp_valid=1;tick();d.store_resp_valid=0;d.eval();}
 void run(){
  reset();alloc(0,10);prefill(0,0x100,11,15);commit(0);
  alloc(1,20);fill(1,0x104,0x22334455);commit(1);
  check(!d.drain_valid,"younger ready store cannot pass oldest missing data");query(30,0x100,true,false);consume();
  broadcast(12,0xf00d);check(!d.drain_valid,"unrelated broadcast ignored");
  query(30,0x100,true,false);broadcast(11,0xaabbccdd,1);
  check(d.query_blocked&&!d.query_fwd_valid,"held snapshot does not change after capture");consume();
  query(30,0x100,false,true,0xaabbccdd);consume();
  broadcast(11,0xdeadbeef);expect_drain(0,0x100,0xaabbccdd,15);send();expect_drain(1,0x104,0x22334455,15);send();response();response();check(d.count==0,"sent owners released");
  for(unsigned off=0;off<4;off++){
   reset();alloc(0,10);cdb(9,0x89abcdef,1);prefill(0,0x200+off,9,1u<<off);clear_cdb();commit(0);
   expect_drain(0,0x200+off,0x89abcdefu<<(8*off),1u<<off);query(30,0x200,true,false);consume();send();response();check(d.count==0,"same-edge capture and byte lane released");
  }
  // The old LSU leaves full-word data unshifted even when address low bits
  // are set. A waiting word store must preserve that same interface behavior.
  for(unsigned off=0;off<4;off++){
   reset();alloc(0,10);prefill(0,0x400+off,9,15);broadcast(9,0x89abcdef);commit(0);
   expect_drain(0,0x400+off,0x89abcdef,15);send();response();
  }
  reset();alloc(0,10);prefill(0,0x100,7,15);d.squash_valid=1;d.squash_seq=9;cdb(7,0x11111111);tick();d.squash_valid=0;clear_cdb();check(d.count==0&&!d.drain_valid,"squash defeats pending capture");
  alloc(0,30);prefill(0,0x300,8,15);commit(0);broadcast(7,0x22222222);check(!d.drain_valid,"reallocated owner ignores stale source tag");broadcast(8,0x33333333);expect_drain(0,0x300,0x33333333,15);send();response();
  reset();alloc(0,10);prefill(0,0x100,9,15);alloc(1,20);fill(1,0x100,0x77777777);query(30,0x100,false,true,0x77777777);consume();
  if(W==2){
   reset();
   for(unsigned i=0;i<D-1;i++){
    alloc(2,10+i);fill(2,0x508,0x1000+i);commit(2);expect_drain(2,0x508,0x1000+i,15);send();response();
   }
   // Two committed stores cross the ring boundary in one retirement packet.
   alloc(D-1,100);fill(D-1,0x600,0x11112222);alloc(0,101);fill(0,0x604,0x33334444);
   d.commit_valid=3;d.commit_is_store=3;d.commit_id=(D-1);tick();d.commit_valid=0;d.commit_is_store=0;d.eval();
   expect_drain(D-1,0x600,0x11112222,15);send();expect_drain(0,0x604,0x33334444,15);send();response();response();check(d.count==0,"dual commit wraps shared ring");
   reset();alloc(0,10,false);alloc(1,20);fill(1,0x700,0x55aacc33);
   d.commit_valid=3;d.commit_is_load=1;d.commit_is_store=2;d.commit_id=1u<<LW;tick();d.commit_valid=0;d.commit_is_load=0;d.commit_is_store=0;d.eval();
   expect_drain(1,0x700,0x55aacc33,15);check(d.count==1,"load/store packet only enqueues store");send();response();
   reset();alloc(0,10);fill(0,0x800,0x1234);commit(0);alloc(1,20);fill(1,0x804,0x2345);alloc(2,30);fill(2,0x808,0x3456);
   expect_drain(0,0x800,0x1234,15);
   d.drain_fire=1;d.commit_valid=3;d.commit_is_store=3;d.commit_id=1u|(2u<<LW);tick();d.drain_fire=0;d.commit_valid=0;d.commit_is_store=0;d.eval();
   expect_drain(1,0x804,0x2345,15);send();expect_drain(2,0x808,0x3456,15);send();response();response();response();check(d.count==0,"dual enqueue overlaps send");
  }
  // An independent age list models complete rounds of shuffled physical ids,
  // arbitrary broadcast order, both CDB lanes, byte masks and delayed sends.
  reset();
  struct Store{unsigned id,tag,mask;uint32_t addr,value;bool known=false;};
  for(unsigned round=0;round<300;round++){
   std::array<unsigned,D> ids{};for(unsigned i=0;i<D;i++)ids[i]=i;
   for(unsigned i=D-1;i>0;i--)std::swap(ids[i],ids[rng()%(i+1)]);
   std::vector<Store> stores;std::vector<unsigned> broadcasts;
   for(unsigned i=0;i<D;i++){
    unsigned off=rng()%4,mask=1u<<off;switch(rng()%4){case 0:mask=15;break;case 1:off=(rng()%2)*2;mask=3u<<off;break;default:break;}
    Store st{ids[i],i+1,mask,0x1000+ids[i]*4+off,rng(),false};stores.push_back(st);alloc(st.id,100+i);prefill(st.id,st.addr,st.tag,st.mask);commit(st.id);broadcasts.push_back(i);
   }
   for(unsigned i=D-1;i>0;i--)std::swap(broadcasts[i],broadcasts[rng()%(i+1)]);
   unsigned next=0;
   for(unsigned n=0;n<D;n+=2){
    for(unsigned lane=0;lane<2&&n+lane<D;lane++){auto& st=stores[broadcasts[n+lane]];cdb(st.tag,st.value,lane);st.known=true;}
    tick();clear_cdb();d.eval();
    while(next<D&&stores[next].known){auto& st=stores[next];expect_drain(st.id,st.addr,(st.mask==15?st.value:st.value<<(8*(st.addr&3))),st.mask);for(unsigned hold=0;hold<rng()%3;hold++){tick();expect_drain(st.id,st.addr,(st.mask==15?st.value:st.value<<(8*(st.addr&3))),st.mask);}send();next++;}
    if(next<D)check(!d.drain_valid,"unready oldest continues to block ready younger entries");
   }
   check(next==D&&!d.drain_valid,"all committed stores sent once");for(unsigned i=0;i<D;i++)response();check(d.count==0,"random owners and FIFO wrap released");
   if(fails)break;
  }
  std::printf("store capture LSQ W=%u D=%u checks=%u fails=%u\n",W,D,checks,fails);
 }
};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Bench b;b.run();return b.fails?1:0;}

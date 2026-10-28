// -----------------------------------------------------------------------------
// cdb.sv — 公共数据总线仲裁器
//
// 源：W 个 ALU lane + 1 个 load + 1 个 divider = W+2 个结果源。
// 输出：R 条 CDB lane（默认 1）。
//
// 协议：
//   - 源保持 valid/tag/value 直到 src_ready=1（同一拍即被 CDB 吸收）；
//   - 每拍每条 CDB lane 最多选一个源，同一源不会在同一拍被选两次；
//   - 轮转优先级避免固定低编号源饿死高编号源；
//   - 未获胜的源必须由调用方保持，下一拍重试。
// -----------------------------------------------------------------------------

module cdb #(
  parameter integer W = `CPU_ISSUE_WIDTH,
  parameter integer R = `CPU_CDB_NUM,
  parameter integer PRIORITY_ALU0 = 0,
  parameter integer HINT_OPTIONAL_SOURCE = -1
) (
  input  logic clk,
  input  logic reset,

  input  logic [W+1:0]                   src_valid,
  input  logic [(W+2)*`CPU_PRF_IDX_W-1:0] src_tag,
  input  logic [(W+2)*32-1:0]            src_value,
  input  logic [W+1:0]                   src_exception,
  output logic [W+1:0]                   src_ready,

  output logic [W+1:0] hint_ready_mask,
  output logic [R*`CPU_CDB_W-1:0]        cdb_out
);

  localparam integer N  = W + 2;
  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer CW = `CPU_CDB_W;

  logic [3:0]     last;
  logic [N-1:0]   chosen;
  integer         r, k, idx;
  logic           found;

  always_comb begin
    cdb_out   = '0;
    src_ready = '0;
    chosen    = '0;

    for (r = 0; r < R; r = r + 1) begin
      found = 1'b0;
      // With a second lane available, reserve the first lane for source 0.
      // Remaining sources retain the rotating search and cannot be duplicated.
      if(PRIORITY_ALU0 && R>=2 && r==0 && src_valid[0])begin
        found=1'b1;chosen[0]=1'b1;src_ready[0]=1'b1;
        cdb_out[`CPU_CDB_VALID_OFF]=1'b1;
        cdb_out[`CPU_CDB_TAG_OFF +: PW]=src_tag[0 +: PW];
        cdb_out[`CPU_CDB_VALUE_OFF +: 32]=src_value[0 +: 32];
        cdb_out[`CPU_CDB_EXCEPTION_OFF]=src_exception[0];
      end
      for (k = 0; k < N; k = k + 1) begin
        idx = (last + r + k + 1) % N;
        if (!found && !chosen[idx] && src_valid[idx]) begin
          found             = 1'b1;
          chosen[idx]       = 1'b1;
          src_ready[idx]    = 1'b1;
          cdb_out[r*CW + `CPU_CDB_VALID_OFF] = 1'b1;
          cdb_out[r*CW + `CPU_CDB_TAG_OFF +: PW] = src_tag[idx*PW +: PW];
          cdb_out[r*CW + `CPU_CDB_VALUE_OFF +: 32] = src_value[idx*32 +: 32];
          cdb_out[r*CW + `CPU_CDB_EXCEPTION_OFF] = src_exception[idx];
        end
      end
    end
    if(PRIORITY_ALU0 && R>=2)src_ready[0]=src_valid[0];
  end


  generate if(HINT_OPTIONAL_SOURCE>=0 && HINT_OPTIONAL_SOURCE<N && R>=2)begin : gen_guaranteed_hint
    wire [N-2:0] registered_compute_valid;
    for(genvar c=0;c<N-1;c=c+1)begin : gen_compute_input
      assign registered_compute_valid[c]=src_valid[c+(c>=HINT_OPTIONAL_SOURCE)];
    end
    (* keep_hierarchy = "yes" *) cdb_compute_hint #(.N(N),.R(R),.PRIORITY_ALU0(PRIORITY_ALU0),.OPTIONAL(HINT_OPTIONAL_SOURCE)) u_hint(
      .last(last),.compute_valid(registered_compute_valid),.hint_mask(hint_ready_mask));
  end else begin : gen_no_guaranteed_hint
    assign hint_ready_mask='0;
  end endgenerate
  always_ff @(posedge clk) begin
    if (reset)
      last <= 4'b0;
    else if (|src_valid)
      last <= (last == N-1) ? 4'b0 : last + 4'b1;
  end

endmodule

// Only registered compute status and registered arbitration phase enter this
// cone. Keeping it separate prevents sharing with late optional-source logic.
(* keep_hierarchy = "yes" *) module cdb_compute_hint #(
  parameter integer N=4,R=2,PRIORITY_ALU0=1,OPTIONAL=2
)(input logic[3:0]last,input logic[N-2:0]compute_valid,output logic[N-1:0]hint_mask);
  function automatic [N-1:0] assumed_grants(input logic optional_present);
    logic[N-1:0]offered,granted;
    logic got;
    integer lane,offset,index,source;
    begin
      for(source=0;source<N;source=source+1)begin
        if(source==OPTIONAL)offered[source]=optional_present;
        else offered[source]=compute_valid[source-(source>OPTIONAL)];
      end
      granted='0;
      for(lane=0;lane<R;lane=lane+1)begin
        got=0;
        if(PRIORITY_ALU0 && lane==0 && offered[0])begin got=1;granted[0]=1;end
        for(offset=0;offset<N;offset=offset+1)begin
          index=(last+lane+offset+1)%N;
          if(!got && offered[index] && !granted[index])begin got=1;granted[index]=1;end
        end
      end
      assumed_grants=granted;
    end
  endfunction
  assign hint_mask=assumed_grants(1'b0)&assumed_grants(1'b1)&~(N'(1)<<OPTIONAL);
endmodule

// Readiness for a buffered consumer is independent of current load validity.
(* keep_hierarchy = "yes" *) module cdb_source_ready_hint #(
 parameter integer PW=`CPU_PRF_IDX_W
)(input logic[2*PW-1:0]source_tag,input logic[1:0]source_ready,
 input logic[3:0]compute_mask,input logic[3*PW-1:0]compute_tags,output logic[1:0]ready);
 for(genvar n=0;n<2;n=n+1)begin : gen_operand
  assign ready[n]=source_ready[n] ||
   (compute_mask[0]&&source_tag[n*PW+:PW]==compute_tags[0+:PW]) ||
   (compute_mask[1]&&source_tag[n*PW+:PW]==compute_tags[PW+:PW]) ||
   (compute_mask[3]&&source_tag[n*PW+:PW]==compute_tags[2*PW+:PW]);
 end
endmodule

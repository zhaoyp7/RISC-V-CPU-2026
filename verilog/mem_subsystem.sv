// -----------------------------------------------------------------------------
// mem_subsystem.sv — 存储器子系统 v2（多笔在途读 + 流水写）
//
// 客户口：
//   - if_refill：I-Cache 单字回填（单未完成事务，请求保持到响应）；
//   - ld_*     ：LSU load 流，支持多笔在途；响应按请求顺序返回；
//   - st_*     ：LSU store 流，写请求接受即完成；B 响应按序返回；
//   - data_*   ：P1 兼容的单事务口（单测使用；顶层不接）。
//
// 仲裁：
//   - 读：legacy > IF > LD。IF 是取指关键路径，优先于数据 load；
//   - 写：legacy > ST。
//   - 读/写共用 axi_mem_if 的两个独立队列，因此读和写可以同时在途。
//
// 响应路由：
//   - 每个被 AXI 接受的读请求把 owner 压入读 owner FIFO，R 返回时按序弹出；
//   - 写同理，B 返回时按序弹出；这样多个客户可以并发使用总线。
// -----------------------------------------------------------------------------

module mem_subsystem #(
  parameter integer QDEPTH = 8,
  parameter integer WRITE_DEPTH = QDEPTH,
  parameter integer IF_LINE_BUFFER = 0
) (
  input  logic        clk,
  input  logic        reset,

  // I-Cache refill client
  input  logic        if_req_valid,
  input  logic [31:0] if_req_addr,
  output logic        if_resp_valid,
  output logic [31:0] if_resp_rdata,

  // Second I-Cache refill client (dual-fetch)
  input  logic        if2_req_valid,
  input  logic [31:0] if2_req_addr,
  output logic        if2_resp_valid,
  output logic [31:0] if2_resp_rdata,

  // Pipelined load client (LSU)
  input  logic        ld_req_valid,
  input  logic [31:0] ld_req_addr,
  output logic        ld_req_ready,
  output logic        ld_resp_valid,
  output logic [31:0] ld_resp_rdata,

  // Pipelined store client (LSU)
  input  logic        st_req_valid,
  input  logic [31:0] st_req_addr,
  input  logic [31:0] st_req_wdata,
  input  logic [3:0]  st_req_wstrb,
  output logic        st_req_ready,
  output logic        st_resp_valid,

  // Legacy P1 data client (single outstanding; unit test)
  input  logic        data_req_valid,
  input  logic        data_req_we,
  input  logic [31:0] data_req_addr,
  input  logic [31:0] data_req_wdata,
  input  logic [3:0]  data_req_wstrb,
  output logic        data_resp_valid,
  output logic [31:0] data_resp_rdata,

  // AXI4-Lite
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);
 generate if(!IF_LINE_BUFFER)begin : gen_direct
  mem_subsystem_raw #(.QDEPTH(QDEPTH),.WRITE_DEPTH(WRITE_DEPTH)) u_raw(.*);
 end else begin : gen_instruction_line
  logic [1:0] client_wait;
  logic [1:0] owner;
  logic owner_head,owner_tail;
  logic [1:0] owner_count;
  wire select_second = !if_req_valid || client_wait[0];
  wire selected_valid = select_second ? (if2_req_valid&&!client_wait[1]) : (if_req_valid&&!client_wait[0]);
  wire [31:0] selected_addr = select_second ? if2_req_addr : if_req_addr;
  wire cache_ready,cache_response;
  (* keep *) wire unused_store_ready,unused_if0_valid,unused_if1_valid;
  (* keep *) wire [31:0] unused_if0_data,unused_if1_data;
  wire [31:0] cache_data;
  wire cache_accept=selected_valid&&cache_ready&&owner_count<2;
  wire cache_pop=cache_response&&owner_count!=0;
  wire line_mem_valid,line_mem_ready,line_mem_response;
  wire [31:0] line_mem_addr,line_mem_data;
  assign if_resp_valid=cache_pop&&!owner[owner_head];
  assign if2_resp_valid=cache_pop&&owner[owner_head];
  assign if_resp_rdata=cache_data;
  assign if2_resp_rdata=cache_data;
  load_line_cache #(.INDEX_BITS(2), .QDEPTH(2)) u_instruction_lines(
   .clk(clk),.reset(reset),.req_valid(selected_valid&&owner_count<2),.req_addr(selected_addr),.req_ready(cache_ready),
   .resp_valid(cache_response),.resp_data(cache_data),.mem_valid(line_mem_valid),.mem_addr(line_mem_addr),.mem_ready(line_mem_ready),
   .mem_resp_valid(line_mem_response),.mem_resp_data(line_mem_data),
   .store_fire(1'b0),.store_addr(32'b0),.store_data(32'b0),.store_mask(4'b0),.store_ready(unused_store_ready),.store_resp_valid(1'b0));
  always_ff @(posedge clk)begin
   if(reset)begin client_wait<=0;owner_head<=0;owner_tail<=0;owner_count<=0;end
   else begin
    if(cache_pop)begin client_wait[owner[owner_head]]<=0;owner_head<=!owner_head;end
    if(cache_accept)begin client_wait[select_second]<=1;owner[owner_tail]<=select_second;owner_tail<=!owner_tail;end
    owner_count<=owner_count+2'(cache_accept)-2'(cache_pop);
   end
  end
  // The raw pipelined read port carries both instruction prefetch and data
  // misses. One ownership bit per accepted beat preserves their responses.
  logic [15:0] read_owner;
  logic [3:0] read_head,read_tail;
  logic [4:0] read_count;
  wire raw_ready,raw_response;
  wire [31:0] raw_data;
  wire read_space=read_count<16;
  wire choose_instruction=line_mem_valid;
  wire shared_valid=read_space&&(line_mem_valid||ld_req_valid);
  wire [31:0] shared_addr=choose_instruction?line_mem_addr:ld_req_addr;
  wire shared_accept=shared_valid&&raw_ready;
  assign line_mem_ready=read_space&&raw_ready;
  assign ld_req_ready=read_space&&!line_mem_valid&&raw_ready;
  assign line_mem_response=raw_response&&read_count!=0&&read_owner[read_head];
  assign line_mem_data=raw_data;
  assign ld_resp_valid=raw_response&&read_count!=0&&!read_owner[read_head];
  assign ld_resp_rdata=raw_data;
  always_ff @(posedge clk)begin
   if(reset)begin read_head<=0;read_tail<=0;read_count<=0;end
   else begin
    if(shared_accept)begin read_owner[read_tail]<=choose_instruction;read_tail<=read_tail+1'b1;end
    if(raw_response)read_head<=read_head+1'b1;
    read_count<=read_count+5'(shared_accept)-5'(raw_response);
   end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk)if(!reset)begin
   if(raw_response&&read_count==0)$fatal(1,"instruction buffer response without owner");
   if(cache_response&&owner_count==0)$fatal(1,"instruction buffer response without client");
   if(owner_count!=u_instruction_lines.q_count)$fatal(1,"instruction queue and client ownership counts differ");
   if(cache_accept&&client_wait[select_second])$fatal(1,"instruction request accepted twice");
  end
`endif
  mem_subsystem_raw #(.QDEPTH(QDEPTH),.WRITE_DEPTH(WRITE_DEPTH)) u_raw(
   .if_req_valid(1'b0),.if_req_addr(32'b0),.if_resp_valid(unused_if0_valid),.if_resp_rdata(unused_if0_data),
   .if2_req_valid(1'b0),.if2_req_addr(32'b0),.if2_resp_valid(unused_if1_valid),.if2_resp_rdata(unused_if1_data),
   .ld_req_valid(shared_valid),.ld_req_addr(shared_addr),.ld_req_ready(raw_ready),
   .ld_resp_valid(raw_response),.ld_resp_rdata(raw_data),.*);
 end endgenerate
endmodule

module mem_subsystem_raw #(
  parameter integer QDEPTH = 8,
  parameter integer WRITE_DEPTH = QDEPTH
) (
  input  logic        clk,
  input  logic        reset,

  // I-Cache refill client
  input  logic        if_req_valid,
  input  logic [31:0] if_req_addr,
  output logic        if_resp_valid,
  output logic [31:0] if_resp_rdata,

  // Second I-Cache refill client (dual-fetch)
  input  logic        if2_req_valid,
  input  logic [31:0] if2_req_addr,
  output logic        if2_resp_valid,
  output logic [31:0] if2_resp_rdata,

  // Pipelined load client (LSU)
  input  logic        ld_req_valid,
  input  logic [31:0] ld_req_addr,
  output logic        ld_req_ready,
  output logic        ld_resp_valid,
  output logic [31:0] ld_resp_rdata,

  // Pipelined store client (LSU)
  input  logic        st_req_valid,
  input  logic [31:0] st_req_addr,
  input  logic [31:0] st_req_wdata,
  input  logic [3:0]  st_req_wstrb,
  output logic        st_req_ready,
  output logic        st_resp_valid,

  // Legacy P1 data client (single outstanding; unit test)
  input  logic        data_req_valid,
  input  logic        data_req_we,
  input  logic [31:0] data_req_addr,
  input  logic [31:0] data_req_wdata,
  input  logic [3:0]  data_req_wstrb,
  output logic        data_resp_valid,
  output logic [31:0] data_resp_rdata,

  // AXI4-Lite
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);

  localparam logic [1:0] OW_IF  = 2'd0;
  localparam logic [1:0] OW_LD  = 2'd1;
  localparam logic [1:0] OW_LEG = 2'd2;
  localparam logic [1:0] OW_IF2 = 2'd3;

  localparam integer RDQD = 16;
  localparam integer WRQD = 8;

  // ---- AXI 主机 -----------------------------------------------------------
  logic        axi_rd_valid, axi_rd_ready;
  logic [31:0] axi_rd_addr;
  logic        axi_rd_resp_valid;
  logic [31:0] axi_rd_resp_rdata;
  logic        axi_wr_valid, axi_wr_ready;
  logic [31:0] axi_wr_addr, axi_wr_wdata;
  logic [3:0]  axi_wr_wstrb;
  logic        axi_wr_resp_valid;

  axi_mem_if #(.QDEPTH(QDEPTH),.WRITE_DEPTH(WRITE_DEPTH)) u_axi (
    .clk            (clk),
    .reset          (reset),
    .rd_valid       (axi_rd_valid),
    .rd_addr        (axi_rd_addr),
    .rd_ready       (axi_rd_ready),
    .rd_resp_valid  (axi_rd_resp_valid),
    .rd_resp_rdata  (axi_rd_resp_rdata),
    .wr_valid       (axi_wr_valid),
    .wr_addr        (axi_wr_addr),
    .wr_wdata       (axi_wr_wdata),
    .wr_wstrb       (axi_wr_wstrb),
    .wr_ready       (axi_wr_ready),
    .wr_resp_valid  (axi_wr_resp_valid),
    .araddr         (araddr),
    .arvalid        (arvalid),
    .arready        (arready),
    .rdata          (rdata),
    .rresp          (rresp),
    .rvalid         (rvalid),
    .rready         (rready),
    .awaddr         (awaddr),
    .awvalid        (awvalid),
    .awready        (awready),
    .wdata          (wdata),
    .wstrb          (wstrb),
    .wvalid         (wvalid),
    .wready         (wready),
    .bresp          (bresp),
    .bvalid         (bvalid),
    .bready         (bready)
  );

  // ---- 读请求仲裁 ---------------------------------------------------------
  logic        if_pending, if_wait;
  logic        if2_pending, if2_wait;
  logic        leg_pending, leg_wait;
  logic        sel_if, sel_if2, sel_ld, sel_leg;
  logic        rd_fire;

  assign sel_leg = data_req_valid && !data_req_we && !leg_pending && !leg_wait;
  assign sel_if  = !sel_leg && if_req_valid && !if_pending && !if_wait;
  assign sel_if2 = !sel_leg && !sel_if && if2_req_valid &&
                   !if2_pending && !if2_wait;

  // ready 不能依赖 ld_req_valid，否则会和 LSU.issue_ready 形成组合环。
  assign ld_req_ready = !sel_leg && !sel_if && !sel_if2 && axi_rd_ready;
  assign sel_ld       = ld_req_valid && ld_req_ready;

  assign axi_rd_valid = sel_leg || sel_if || sel_if2 || sel_ld;
  assign axi_rd_addr  = sel_leg ? data_req_addr :
                        (sel_if ? if_req_addr :
                         (sel_if2 ? if2_req_addr : ld_req_addr));
  assign rd_fire      = axi_rd_valid && axi_rd_ready;

  // ---- 读 owner FIFO ------------------------------------------------------
  localparam integer RPTRW = $clog2(RDQD);
  logic [1:0]         rd_owner [0:RDQD-1];
  logic [RPTRW-1:0]   rd_head, rd_tail;
  logic [RPTRW:0]     rd_count;

  // ---- 写请求仲裁 ---------------------------------------------------------
  logic        leg_wr_pending, leg_wr_wait;
  logic        sel_st, sel_legwr;
  logic        wr_fire;

  assign sel_legwr = data_req_valid && data_req_we && !leg_wr_pending && !leg_wr_wait;
  assign st_req_ready = !sel_legwr && axi_wr_ready;
  assign sel_st       = st_req_valid && st_req_ready;

  assign axi_wr_valid = sel_legwr || sel_st;
  assign axi_wr_addr  = sel_legwr ? data_req_addr : st_req_addr;
  assign axi_wr_wdata = sel_legwr ? data_req_wdata : st_req_wdata;
  assign axi_wr_wstrb = sel_legwr ? data_req_wstrb : st_req_wstrb;
  assign wr_fire      = axi_wr_valid && axi_wr_ready;

  // ---- 写 owner FIFO ------------------------------------------------------
  localparam integer WPTRW = $clog2(WRQD);
  logic               wr_owner [0:WRQD-1];
  logic [WPTRW-1:0]   wr_head, wr_tail;
  logic [WPTRW:0]     wr_count;

  // ---- 响应路由 -----------------------------------------------------------
  logic [1:0] rd_owner_cur;
  logic [1:0] wr_owner_cur;

  assign rd_owner_cur = rd_owner[rd_head];
  assign wr_owner_cur = wr_owner[wr_head];

  always_comb begin
    if_resp_valid    = 1'b0;
    if_resp_rdata    = axi_rd_resp_rdata;
    if2_resp_valid   = 1'b0;
    if2_resp_rdata   = axi_rd_resp_rdata;
    ld_resp_valid    = 1'b0;
    ld_resp_rdata    = axi_rd_resp_rdata;
    data_resp_valid  = 1'b0;
    data_resp_rdata  = axi_rd_resp_rdata;

    if (axi_rd_resp_valid) begin
      case (rd_owner_cur)
        OW_IF:   if_resp_valid    = 1'b1;
        OW_IF2:  if2_resp_valid   = 1'b1;
        OW_LD:   ld_resp_valid    = 1'b1;
        default: data_resp_valid  = 1'b1;
      endcase
    end

    st_resp_valid = 1'b0;

    if (axi_wr_resp_valid) begin
      if (wr_owner_cur)
        st_resp_valid = 1'b1;
      else
        data_resp_valid = 1'b1;
    end
  end

  // ---- 时序 ---------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      if_pending    <= 1'b0;
      if_wait       <= 1'b0;
      if2_pending   <= 1'b0;
      if2_wait      <= 1'b0;
      leg_pending   <= 1'b0;
      leg_wait      <= 1'b0;
      leg_wr_pending <= 1'b0;
      leg_wr_wait   <= 1'b0;
      rd_head       <= '0;
      rd_tail       <= '0;
      rd_count      <= '0;
      wr_head       <= '0;
      wr_tail       <= '0;
      wr_count      <= '0;
    end else begin
      // ---- IF 去重 -------------------------------------------------------
      if (!if_req_valid) if_wait <= 1'b0;
      if (!if2_req_valid) if2_wait <= 1'b0;
      if (!data_req_valid) begin
        leg_wait    <= 1'b0;
        leg_wr_wait <= 1'b0;
      end

      // ---- 读请求入队 -----------------------------------------------------
      if (rd_fire) begin
        rd_owner[rd_tail] <= sel_leg ? OW_LEG :
                              (sel_if ? OW_IF :
                               (sel_if2 ? OW_IF2 : OW_LD));
        rd_tail  <= (rd_tail == RDQD - 1) ? '0 : rd_tail + 1'b1;
        if (sel_if) if_pending <= 1'b1;
        if (sel_if2) if2_pending <= 1'b1;
        if (sel_leg) leg_pending <= 1'b1;
      end

      // ---- 读响应出队 -----------------------------------------------------
      if (axi_rd_resp_valid && (rd_count != 0)) begin
        rd_head  <= (rd_head == RDQD - 1) ? '0 : rd_head + 1'b1;
        case (rd_owner_cur)
          OW_IF: begin
            if_pending <= 1'b0;
            if_wait    <= 1'b1;
          end
          OW_IF2: begin
            if2_pending <= 1'b0;
            if2_wait    <= 1'b1;
          end
          OW_LEG: begin
            leg_pending <= 1'b0;
            leg_wait    <= 1'b1;
          end
          default: ;
        endcase
      end

      if (rd_fire && !(axi_rd_resp_valid && (rd_count != 0)))
        rd_count <= rd_count + 1'b1;
      else if (!rd_fire && (axi_rd_resp_valid && (rd_count != 0)))
        rd_count <= rd_count - 1'b1;

      // ---- 写请求入队 -----------------------------------------------------
      if (wr_fire) begin
        wr_owner[wr_tail] <= sel_legwr ? 1'b0 : 1'b1;
        wr_tail <= (wr_tail == WRQD - 1) ? '0 : wr_tail + 1'b1;
        if (sel_legwr) leg_wr_pending <= 1'b1;
      end

      // ---- 写响应出队 -----------------------------------------------------
      if (axi_wr_resp_valid && (wr_count != 0)) begin
        wr_head <= (wr_head == WRQD - 1) ? '0 : wr_head + 1'b1;
        if (wr_owner_cur == 1'b0) begin
          leg_wr_pending <= 1'b0;
          leg_wr_wait    <= 1'b1;
        end
      end

      if (wr_fire && !(axi_wr_resp_valid && (wr_count != 0)))
        wr_count <= wr_count + 1'b1;
      else if (!wr_fire && (axi_wr_resp_valid && (wr_count != 0)))
        wr_count <= wr_count - 1'b1;
    end
  end

`ifdef LOCAL_STATS
  // 仅仿真统计；默认构建/综合不会实例化这些计数器。
  longint st_cycles, st_if0_req, st_if1_req, st_ld_req, st_st_req;
  longint st_rd_resp, st_wr_resp, st_axi_rd_wait, st_axi_wr_wait;
  longint st_rd_out_sum, st_wr_out_sum;
  integer st_max_rd_out, st_max_wr_out;

  always_ff @(posedge clk) begin
    if (reset) begin
      st_cycles      <= 0;
      st_if0_req     <= 0;
      st_if1_req     <= 0;
      st_ld_req      <= 0;
      st_st_req      <= 0;
      st_rd_resp     <= 0;
      st_wr_resp     <= 0;
      st_axi_rd_wait <= 0;
      st_axi_wr_wait <= 0;
      st_rd_out_sum  <= 0;
      st_wr_out_sum  <= 0;
      st_max_rd_out  <= 0;
      st_max_wr_out  <= 0;
    end else begin
      st_cycles <= st_cycles + 1;
      if (rd_fire && sel_if)  st_if0_req <= st_if0_req + 1;
      if (rd_fire && sel_if2) st_if1_req <= st_if1_req + 1;
      if (rd_fire && sel_ld)  st_ld_req <= st_ld_req + 1;
      if (wr_fire && sel_st)  st_st_req <= st_st_req + 1;
      if (axi_rd_resp_valid) st_rd_resp <= st_rd_resp + 1;
      if (axi_wr_resp_valid) st_wr_resp <= st_wr_resp + 1;
      if (axi_rd_valid && !axi_rd_ready) st_axi_rd_wait <= st_axi_rd_wait + 1;
      if (axi_wr_valid && !axi_wr_ready) st_axi_wr_wait <= st_axi_wr_wait + 1;

      st_rd_out_sum <= st_rd_out_sum + rd_count;
      st_wr_out_sum <= st_wr_out_sum + wr_count;
      if (rd_count > st_max_rd_out) st_max_rd_out <= rd_count;
      if (wr_count > st_max_wr_out) st_max_wr_out <= wr_count;
    end
  end

  final $fdisplay(32'h80000002,
      "[STATS] MEM cycles=%0d if0_req=%0d if1_req=%0d ld_req=%0d st_req=%0d rd_resp=%0d wr_resp=%0d axi_rd_wait=%0d axi_wr_wait=%0d rd_out_sum=%0d max_rd_out=%0d wr_out_sum=%0d max_wr_out=%0d",
      st_cycles, st_if0_req, st_if1_req, st_ld_req, st_st_req,
      st_rd_resp, st_wr_resp, st_axi_rd_wait, st_axi_wr_wait,
      st_rd_out_sum, st_max_rd_out, st_wr_out_sum, st_max_wr_out);
`endif

endmodule

// Ordered load-stream adapter for a nonblocking, 32-byte-line read cache.
// Data uses eight synchronous SRAM banks. Two fills may be outstanding while
// hits complete into an eight-entry order queue; the LSU still sees exactly
// one response per accepted request, in request order, including flushed loads.
// Stores are write-through outside this module; hits update byte lanes here.
module load_line_cache #(
  parameter integer INDEX_BITS = 7,
  parameter integer QDEPTH = 8,
  parameter integer FLIGHT_DEPTH = 8
) (
  input wire clk, reset,
  input wire req_valid,
  input wire [31:0] req_addr,
  output wire req_ready,
  output wire resp_valid,
  output wire [31:0] resp_data,
  output wire mem_valid,
  output wire [31:0] mem_addr,
  input wire mem_ready,
  input wire mem_resp_valid,
  input wire [31:0] mem_resp_data,
  input wire store_fire,
  input wire [31:0] store_addr, store_data,
  input wire [3:0] store_mask,
  output wire store_ready,
  input wire store_resp_valid
);
  localparam integer LINES = 1 << INDEX_BITS;
  localparam integer TAG_BITS = 23 - INDEX_BITS;
  localparam integer QW = $clog2(QDEPTH);
  localparam integer FW = $clog2(FLIGHT_DEPTH);
  logic [LINES-1:0] line_valid;
  logic [TAG_BITS-1:0] line_tag [0:LINES-1];
  logic [QDEPTH-1:0] q_valid, q_done, q_mshr;
  logic [2:0] q_word [0:QDEPTH-1];
  logic [31:0] q_data [0:QDEPTH-1];
  logic [QW-1:0] q_head, q_tail;
  logic [QW:0] q_count;

  logic [1:0] m_valid, m_unc, m_install;
  logic [31:2] m_addr [0:1];
  logic [2:0] m_first [0:1];
  logic [3:0] m_sent [0:1], m_returned [0:1];
  logic [7:0] m_words [0:1];
  wire [INDEX_BITS-1:0] r_index = req_addr[INDEX_BITS+4:5];
  wire [TAG_BITS-1:0] r_tag = req_addr[27:INDEX_BITS+5];
  wire r_cached = req_addr[31:28] == 0;
  wire [2:0] r_word = req_addr[4:2];
  logic match_valid, match_slot, free_valid, free_slot, row_busy;
  always_comb begin
    match_valid = 0; match_slot = 0;
    free_valid = 0; free_slot = 0; row_busy = 0;
    for (integer k=1; k>=0; k=k-1) begin
      if (!m_valid[k]) begin free_valid=1; free_slot=1'(k); end
      if (m_valid[k] && !m_unc[k]) begin
        if (m_addr[k][INDEX_BITS+4:5] == r_index) row_busy=1;
        if (m_install[k] && m_addr[k][31:5] == req_addr[31:5]) begin match_valid=1; match_slot=1'(k); end
      end
    end
  end

  // Downstream responses are ordered, so each accepted word carries a compact
  // {MSHR,word} record until its response. The external memory remains shared.
  logic [3:0] flight [0:FLIGHT_DEPTH-1];
  logic [FW-1:0] flight_head, flight_tail;
  logic [FW:0] flight_count;
  wire return_valid = mem_resp_valid && flight_count != 0;
  wire return_slot = flight[flight_head][3];
  wire [2:0] return_word = flight[flight_head][2:0];
  wire refill_write = return_valid && !m_unc[return_slot];
  logic send_slot, send_valid;
  always_comb begin
    send_slot=0; send_valid=0;
    for(integer k=1;k>=0;k=k-1)
      if(m_valid[k] && m_sent[k] < (m_unc[k] ? 4'd1 : 4'd8)) begin
        send_valid=1;send_slot=1'(k);
      end
  end
  wire [2:0] send_word = m_unc[send_slot] ? m_first[send_slot] :
                                              m_first[send_slot]+m_sent[send_slot][2:0];
  assign mem_valid = !reset && send_valid && flight_count < FLIGHT_DEPTH;
  assign mem_addr = {m_addr[send_slot][31:5],send_word,2'b00};
  wire send_fire = mem_valid && mem_ready;

  // Store payload is captured before driving SRAM, keeping the LSQ drain
  // selection out of the SRAM input path. Metadata survives until AXI B.
  logic store_pending;
  logic [31:0] store_addr_q, store_data_q;
  logic [3:0] store_mask_q;
  logic [26:0] store_line [0:7];
  logic [7:0] store_miss;
  logic [2:0] store_head, store_tail;
  logic [3:0] store_count;
  wire [INDEX_BITS-1:0] st_index = store_addr[INDEX_BITS+4:5];
  logic st_partial, pending_partial;
  // A word already written by this fill will not be overwritten again.
  // The queued byte update can therefore preserve the line, including when
  // the word arrives at the same edge as the store is accepted.
  always_comb begin
    st_partial=0;pending_partial=0;
    for(integer k=0;k<2;k=k+1)begin
      if(m_valid[k] && !m_unc[k] && m_install[k])begin
        if(m_addr[k][31:5]==store_addr[31:5] &&
           (m_words[k][store_addr[4:2]] ||
            (return_valid && return_slot==1'(k) && return_word==store_addr[4:2])))st_partial=1;
        if(m_addr[k][31:5]==store_addr_q[31:5] && m_words[k][store_addr_q[4:2]])pending_partial=1;
      end
    end
  end
  wire st_hit = store_addr[31:28] == 0 &&
       ((line_valid[st_index] && line_tag[st_index] == store_addr[27:INDEX_BITS+5]) || st_partial);
  wire store_pop = store_resp_valid && store_count != 0;
  wire [31:5] completed_store_line = store_line[store_head];
  wire completed_store_miss = store_pop && store_miss[store_head];
  wire [INDEX_BITS-1:0] sp_index = store_addr_q[INDEX_BITS+4:5];
  wire store_write = store_pending && !refill_write &&
     ((line_valid[sp_index] && line_tag[sp_index] == store_addr_q[27:INDEX_BITS+5]) || pending_partial);
  wire store_advance = store_pending && !refill_write;
  assign store_ready = !reset && store_count < 8 && (!store_pending || store_advance);

  // A just-returning word can satisfy a newly accepted waiter at this edge.
  wire arriving_word = r_cached && match_valid && return_valid &&
                          return_slot == match_slot && return_word == r_word;
  wire lookup_hit = r_cached &&
      ((line_valid[r_index] && line_tag[r_index] == r_tag) ||
       (match_valid && m_words[match_slot][r_word]));
  // Each word offset owns a separate single-port SRAM. Only writes to the
  // requested bank conflict with a hit read; other banks can run in parallel.
  wire bank_available = !(refill_write && return_word == r_word) &&
                        !(store_pending && store_addr_q[4:2] == r_word);
  wire can_allocate = free_valid && (!r_cached || !row_busy);
  assign req_ready = !reset && q_count < (QW+1)'(QDEPTH) &&
      (arriving_word || (lookup_hit ? bank_available : (match_valid || can_allocate)));
  wire accept = req_valid && req_ready;
  wire hit_read = accept && lookup_hit && !arriving_word;
  wire allocate = accept && !lookup_hit && !arriving_word && !match_valid;
  wire selected_mshr = match_valid ? match_slot : free_slot;

  logic lookup_pending;
  logic [QW-1:0] lookup_slot;
  logic [2:0] lookup_word;
  wire [31:0] bank_data [0:7];
  wire [31:0] hit_data = bank_data[lookup_word];
  wire head_lookup = lookup_pending && lookup_slot == q_head;
  // The oldest waiter can consume its returning word without storing and
  // re-reading it. Later completions still wait behind the ordered head.
  wire head_return = return_valid && q_count != 0 && !q_done[q_head] &&
      !head_lookup && q_mshr[q_head]==return_slot && q_word[q_head]==return_word;
  assign resp_valid = !reset && q_count != 0 && (q_done[q_head] || head_lookup || head_return);
  assign resp_data = head_lookup ? hit_data : (head_return ? mem_resp_data : q_data[q_head]);
  wire pop = resp_valid;

  wire [31:0] bank_wdata = refill_write ? mem_resp_data : store_data_q;
  wire [3:0] bank_mask = refill_write ? 4'hf : store_mask_q;
  for(genvar b=0;b<8;b=b+1) begin : gen_bank
    // Only this bank consumes its operation. Independent address/WE selects
    // prevent one final driver from feeding all 32 byte-lane macro pins.
    wire refill_this = refill_write && return_word==3'(b);
    wire store_this = store_write && store_addr_q[4:2]==3'(b);
    wire read_this = hit_read && r_word==3'(b);
    wire [INDEX_BITS-1:0] address = refill_this ? m_addr[return_slot][INDEX_BITS+4:5] :
                                               (store_this ? sp_index : r_index);
    sram_fakeram #(.DEPTH(LINES),.WIDTH(32),.WRITE_GRANULARITY(8)) u_data (
      .clk(clk), .en(refill_this || store_this || read_this),
      .we(refill_this || store_this), .wmask(bank_mask), .addr(address), .wdata(bank_wdata),
      .rdata(bank_data[b])
    );
  end

  wire publish = return_valid && !m_unc[return_slot] &&
                     m_returned[return_slot]==7 && m_install[return_slot];
  wire [INDEX_BITS-1:0] publish_index = m_addr[return_slot][INDEX_BITS+4:5];
  wire [TAG_BITS-1:0] publish_tag = m_addr[return_slot][27:INDEX_BITS+5];
  wire invalidate_completed = completed_store_miss &&
      line_tag[completed_store_line[INDEX_BITS+4:5]]==completed_store_line[27:INDEX_BITS+5];
  wire [1:0] poison_fill;
  for(genvar k=0;k<2;k=k+1)begin : gen_poison
    assign poison_fill[k] = m_valid[k] && !m_unc[k] &&
        ((store_fire && !st_hit && store_addr[31:5]==m_addr[k][31:5]) ||
         (completed_store_miss && completed_store_line==m_addr[k][31:5]));
  end
  // Constant row writes avoid wide shift/mask networks from variable-index
  // nonblocking writes into the valid vector and tag memory. Read semantics
  // and publication/invalidation priority are unchanged.
  for(genvar line=0;line<LINES;line=line+1)begin : gen_tag_row
    always_ff @(posedge clk)begin
      if(reset)line_valid[line]<=0;
      else begin
        if(publish && publish_index==INDEX_BITS'(line))line_valid[line]<=1;
        if(allocate && r_cached && r_index==INDEX_BITS'(line))line_valid[line]<=0;
        if(invalidate_completed && completed_store_line[INDEX_BITS+4:5]==INDEX_BITS'(line))
          line_valid[line]<=0;
        for(integer k=0;k<2;k=k+1)
          if(poison_fill[k] && m_addr[k][INDEX_BITS+4:5]==INDEX_BITS'(line))line_valid[line]<=0;
      end
      if(!reset && publish && publish_index==INDEX_BITS'(line))line_tag[line]<=publish_tag;
    end
  end

  always_ff @(posedge clk) begin
    if(reset) begin
      q_valid<='0; q_done<='0; q_mshr<='0;
      q_head<=0;q_tail<=0;q_count<=0;lookup_pending<=0;
      m_valid<=0;m_unc<=0;m_install<=0;
      m_words[0]<=0;m_words[1]<=0;m_sent[0]<=0;m_sent[1]<=0;
      m_returned[0]<=0;m_returned[1]<=0;
      flight_head<=0;flight_tail<=0;flight_count<=0;
      store_pending<=0;store_head<=0;store_tail<=0;store_count<=0;store_miss<=0;
    end else begin
      lookup_pending <= hit_read;
      if(hit_read)begin lookup_slot<=q_tail;lookup_word<=r_word;end
      if(lookup_pending && !(pop && lookup_slot==q_head))begin
        q_data[lookup_slot]<=hit_data;q_done[lookup_slot]<=1;
      end
      if(pop) begin q_valid[q_head]<=0;q_done[q_head]<=0;q_head<=q_head+1'b1;end
      if(accept)begin
        q_valid[q_tail]<=1;q_done[q_tail]<=arriving_word;
        q_mshr[q_tail]<=selected_mshr;q_word[q_tail]<=r_word;
        if(arriving_word)q_data[q_tail]<=mem_resp_data;
        q_tail<=q_tail+1'b1;
      end
      q_count<=q_count+{ {(QW){1'b0}},accept}-{ {(QW){1'b0}},pop};
      if(send_fire)begin
        flight[flight_tail]<={send_slot,send_word};flight_tail<=flight_tail+1'b1;
        m_sent[send_slot]<=m_sent[send_slot]+1'b1;
      end
      if(return_valid)begin
        flight_head<=flight_head+1'b1;
        m_returned[return_slot]<=m_returned[return_slot]+1'b1;
        m_words[return_slot][return_word]<=1;
        for(integer n=0;n<QDEPTH;n=n+1)
          if(q_valid[n] && !q_done[n] && !(pop && q_head==QW'(n)) &&
             !(lookup_pending && lookup_slot==QW'(n)) &&
             q_mshr[n]==return_slot && q_word[n]==return_word)begin
            q_data[n]<=mem_resp_data;q_done[n]<=1;
          end
        if(m_unc[return_slot] || m_returned[return_slot]==7)begin
          m_valid[return_slot]<=0;
        end
      end
      flight_count<=flight_count+{3'b0,send_fire}-{3'b0,return_valid};
      if(allocate)begin
        m_valid[free_slot]<=1;m_unc[free_slot]<=!r_cached;m_install[free_slot]<=r_cached;
        m_addr[free_slot]<=req_addr[31:2];m_first[free_slot]<=r_word;
        m_sent[free_slot]<=0;m_returned[free_slot]<=0;m_words[free_slot]<=0;
      end
      if(store_advance)store_pending<=0;
      if(store_fire)begin
        store_pending<=st_hit;store_addr_q<=store_addr;store_data_q<=store_data;
        store_mask_q<=store_mask;
        store_line[store_tail]<=store_addr[31:5];
        store_miss[store_tail]<=!st_hit && store_addr[31:28]==0;
        store_tail<=store_tail+1'b1;
      end
      if(store_pop)store_head<=store_head+1'b1;
      store_count<=store_count+{3'b0,store_fire}-{3'b0,store_pop};
      // A missed store can race a refill sampled before its write applied.
      // B confirms visibility; discard any such line and poison in-flight fills.
      for(integer k=0;k<2;k=k+1)begin
        if(poison_fill[k])begin
          m_install[k]<=0;
        end
        // Allocation and a store event may coincide; the old m_valid is zero.
        if(allocate && free_slot==1'(k) && r_cached &&
           ((store_fire && !st_hit && store_addr[31:5]==req_addr[31:5]) ||
            (completed_store_miss && completed_store_line==req_addr[31:5])))
          m_install[k]<=0;
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk)if(!reset)begin
    if(mem_resp_valid && flight_count==0)$fatal(1,"line cache response without owner");
    if(store_resp_valid && store_count==0)$fatal(1,"line cache store completion without owner");
    if(q_count>(QW+1)'(QDEPTH) || flight_count>FLIGHT_DEPTH || store_count>8)$fatal(1,"line cache credit overflow");
    if(store_fire && !store_ready)$fatal(1,"line cache store accepted without credit");
  end
  initial if(FLIGHT_DEPTH<2 || (FLIGHT_DEPTH & (FLIGHT_DEPTH-1))!=0)$fatal(1,"flight depth must be power of two");
  initial if(QDEPTH<2 || (QDEPTH & (QDEPTH-1))!=0)
    $fatal(1,"line cache ordered load window must be a power of two >= 2");
`endif
endmodule

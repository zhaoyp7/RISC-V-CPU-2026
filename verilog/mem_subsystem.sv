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
  parameter integer QDEPTH = 8
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

  axi_mem_if #(.QDEPTH(QDEPTH)) u_axi (
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

// -----------------------------------------------------------------------------
// axi_mem_if.sv — 支持多笔在途事务的 AXI4-Lite 主机适配器
//
// 把简单的 read/write 请求流转换成 AXI4-Lite 五通道：
//   - 读：请求按序进入地址 FIFO，AR 可连续发出；R 通道按 AR 顺序返回，
//     因此 read response 也是按序的；
//   - 写：请求进入数据 FIFO，AW/W 连续发出；B 响应按序返回；
//   - 同一时刻保留最多 QDEPTH 笔在途读和 QDEPTH 笔在途写。
//
// 上游握手：
//   rd_valid/rd_addr/rd_ready   读请求（ready 时接受，一条响应后回 rd_resp_valid）
//   wr_valid/wr_addr/.../wr_ready 写请求
//   rd_resp_valid/rd_resp_rdata  读响应（按请求顺序，单拍）
//   wr_resp_valid                写响应（按请求顺序，单拍）
//
// 约束：AR 的 valid 不依赖 ready；请求一旦进入 FIFO 就不会丢失。R/B 通道
// 始终 ready（内部有 QDEPTH 上限，上游只在有空位时才会继续接收）。
// -----------------------------------------------------------------------------

module axi_mem_if #(
  parameter integer QDEPTH = 8
) (
  input  logic        clk,
  input  logic        reset,

  // Read request stream
  input  logic        rd_valid,
  input  logic [31:0] rd_addr,
  output logic        rd_ready,

  // Read response stream (in request order)
  output logic        rd_resp_valid,
  output logic [31:0] rd_resp_rdata,

  // Write request stream
  input  logic        wr_valid,
  input  logic [31:0] wr_addr,
  input  logic [31:0] wr_wdata,
  input  logic [3:0]  wr_wstrb,
  output logic        wr_ready,

  // Write response stream (in request order)
  output logic        wr_resp_valid,

  // AXI4-Lite read address channel
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,

  // AXI4-Lite read data channel
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,

  // AXI4-Lite write address channel
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,

  // AXI4-Lite write data channel
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,

  // AXI4-Lite write response channel
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);

  localparam integer PTRW = (QDEPTH > 1) ? $clog2(QDEPTH) : 1;
  localparam integer CNTW = $clog2(QDEPTH + 1);

  // ---- 读请求 FIFO --------------------------------------------------------
  logic [31:0]      rdq_addr [0:QDEPTH-1];
  logic [PTRW-1:0]  rdq_head, rdq_tail;
  logic [CNTW-1:0]  rdq_queued;      // 已接收但 AR 尚未发出
  logic [CNTW-1:0]  rd_outstanding;  // AR 已发出、R 未返回

  logic rd_fire, r_fire;
  assign rd_fire = arvalid && arready;
  assign r_fire  = rvalid && rready;

  assign rd_ready = ((rdq_queued + rd_outstanding) < QDEPTH);
  assign arvalid  = (rdq_queued != 0);
  assign araddr   = rdq_addr[rdq_head];

  assign rd_resp_valid = rvalid;
  assign rd_resp_rdata = rdata;
  assign rready        = 1'b1;

  // ---- 写请求 FIFO --------------------------------------------------------
  logic [31:0]      wrq_addr  [0:QDEPTH-1];
  logic [31:0]      wrq_wdata [0:QDEPTH-1];
  logic [3:0]       wrq_wstrb [0:QDEPTH-1];
  logic [PTRW-1:0]  wrq_head, wrq_tail;
  logic [CNTW-1:0]  wrq_queued;      // 已接收但 AW/W 尚未完成
  logic [CNTW-1:0]  wr_outstanding;  // AW/W 已完成、B 未返回
  logic             aw_done, w_done;

  logic aw_fire, w_fire, b_fire;
  logic rd_acc, wr_acc, wr_dispatch;
  assign aw_fire = awvalid && awready;
  assign w_fire  = wvalid && wready;
  assign b_fire  = bvalid && bready;

  assign wr_ready = ((wrq_queued + wr_outstanding) < QDEPTH);
  assign awvalid  = (wrq_queued != 0) && !aw_done;
  assign wvalid   = (wrq_queued != 0) && !w_done;
  assign awaddr   = wrq_addr[wrq_head];
  assign wdata    = wrq_wdata[wrq_head];
  assign wstrb    = wrq_wstrb[wrq_head];

  assign wr_resp_valid = bvalid;
  assign bready        = 1'b1;

  // ---- 时序 ---------------------------------------------------------------
  integer i;

  always_ff @(posedge clk) begin
    if (reset) begin
      rdq_head        <= '0;
      rdq_tail        <= '0;
      rdq_queued      <= '0;
      rd_outstanding  <= '0;
      wrq_head        <= '0;
      wrq_tail        <= '0;
      wrq_queued      <= '0;
      wr_outstanding  <= '0;
      aw_done         <= 1'b0;
      w_done          <= 1'b0;
    end else begin
      // ---- 读 -------------------------------------------------------------
      rd_acc = rd_valid && rd_ready;
      if (rd_acc) begin
        rdq_addr[rdq_tail] <= rd_addr;
        rdq_tail           <= (rdq_tail == QDEPTH - 1) ? '0 : rdq_tail + 1'b1;
      end
      if (rd_fire)
        rdq_head <= (rdq_head == QDEPTH - 1) ? '0 : rdq_head + 1'b1;

      rdq_queued     <= rdq_queued + (rd_acc ? 1'b1 : 1'b0) -
                                    (rd_fire ? 1'b1 : 1'b0);
      rd_outstanding <= rd_outstanding + (rd_fire ? 1'b1 : 1'b0) -
                                        (r_fire  ? 1'b1 : 1'b0);

      // ---- 写 -------------------------------------------------------------
      wr_acc = wr_valid && wr_ready;
      if (wr_acc) begin
        wrq_addr[wrq_tail]  <= wr_addr;
        wrq_wdata[wrq_tail] <= wr_wdata;
        wrq_wstrb[wrq_tail] <= wr_wstrb;
        wrq_tail            <= (wrq_tail == QDEPTH - 1) ? '0 : wrq_tail + 1'b1;
      end

      if (aw_fire) aw_done <= 1'b1;
      if (w_fire)  w_done  <= 1'b1;

      wr_dispatch = (wrq_queued != 0) &&
                    (aw_done || aw_fire) && (w_done || w_fire);
      if (wr_dispatch) begin
        wrq_head <= (wrq_head == QDEPTH - 1) ? '0 : wrq_head + 1'b1;
        aw_done  <= 1'b0;
        w_done   <= 1'b0;
      end

      wrq_queued     <= wrq_queued + (wr_acc ? 1'b1 : 1'b0) -
                                    (wr_dispatch ? 1'b1 : 1'b0);
      wr_outstanding <= wr_outstanding + (wr_dispatch ? 1'b1 : 1'b0) -
                                        (b_fire      ? 1'b1 : 1'b0);
    end
  end

endmodule

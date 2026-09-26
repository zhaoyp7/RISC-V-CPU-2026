// -----------------------------------------------------------------------------
// student_top.sv — 顶层模块（OJ 指定的固定端口）
//
// 组成：
//   core        —— 顺序执行内核；
//   icache      —— 指令 Cache（命中 2 周期，缺失走 AXI 回填）；
//   axi_mem_if  —— 唯一的 AXI4-Lite 主机适配器。
//
// 全设计只有一套 AXI 接口，因此 icache 的回填读请求与 core 的数据访存
// 请求需要共享同一个 axi_mem_if。共享方式（mux）：
//   - 同一时刻只会有一个来源有效：cache 回填只在 core 处于 ST_FETCH 时
//     发生，而数据访存只在 ST_MEM 时发生；
//   - 因此 mem_req_* 直接用 refill_valid 选择地址来源，we 仅数据通路有效；
//   - axi_mem_if 的响应同时广播给 icache 和 core，各自只在自己等待的
//     状态采样，不会误收。
//
// 注意：AXI4-Lite 端口名称/位宽/方向必须与课程模板严格一致。
// -----------------------------------------------------------------------------

module student_top (
  input  wire        clock,
  input  wire        reset,

  // AXI4-Lite 读地址通道 (AR)
  output wire [31:0] araddr,
  output wire        arvalid,
  input  wire        arready,

  // AXI4-Lite 读数据通道 (R)
  input  wire [31:0] rdata,
  input  wire [1:0]  rresp,
  input  wire        rvalid,
  output wire        rready,

  // AXI4-Lite 写地址通道 (AW)
  output wire [31:0] awaddr,
  output wire        awvalid,
  input  wire        awready,

  // AXI4-Lite 写数据通道 (W)
  output wire [31:0] wdata,
  output wire [3:0]  wstrb,
  output wire        wvalid,
  input  wire        wready,

  // AXI4-Lite 写响应通道 (B)
  input  wire [1:0]  bresp,
  input  wire        bvalid,
  output wire        bready
);

  // core 取指接口
  logic        fetch_valid;
  logic [31:0] fetch_pc;
  logic        fetch_resp_valid;
  logic [31:0] fetch_inst;

  // core 数据访存接口
  logic        data_req_valid;
  logic        data_req_we;
  logic [31:0] data_req_addr;
  logic [31:0] data_req_wdata;
  logic [3:0]  data_req_wstrb;
  logic        data_resp_valid;
  logic [31:0] data_resp_rdata;

  // icache 回填接口
  logic        refill_valid;
  logic [31:0] refill_addr;
  logic        refill_resp_valid;
  logic [31:0] refill_rdata;

  // 共享 AXI 引擎请求
  logic        mem_req_valid;
  logic        mem_req_we;
  logic [31:0] mem_req_addr;
  logic [31:0] mem_req_wdata;
  logic [3:0]  mem_req_wstrb;
  logic        mem_resp_valid;
  logic [31:0] mem_resp_rdata;

  // 请求仲裁：回填与数据访存互斥，refill_valid 优先（无实际竞争）
  assign mem_req_valid = refill_valid | data_req_valid;
  assign mem_req_we    = data_req_valid & data_req_we;
  assign mem_req_addr  = refill_valid ? refill_addr : data_req_addr;
  assign mem_req_wdata = data_req_wdata;
  assign mem_req_wstrb = data_req_wstrb;

  // 响应广播
  assign refill_resp_valid = mem_resp_valid;
  assign refill_rdata      = mem_resp_rdata;
  assign data_resp_valid   = mem_resp_valid;
  assign data_resp_rdata   = mem_resp_rdata;

  core u_core (
    .clk             (clock),
    .reset           (reset),
    .fetch_valid     (fetch_valid),
    .fetch_pc        (fetch_pc),
    .fetch_resp_valid(fetch_resp_valid),
    .fetch_inst      (fetch_inst),
    .data_req_valid  (data_req_valid),
    .data_req_we     (data_req_we),
    .data_req_addr   (data_req_addr),
    .data_req_wdata  (data_req_wdata),
    .data_req_wstrb  (data_req_wstrb),
    .data_resp_valid (data_resp_valid),
    .data_resp_rdata (data_resp_rdata)
  );

  icache u_icache (
    .clk              (clock),
    .reset            (reset),
    .fetch_valid      (fetch_valid),
    .fetch_pc         (fetch_pc),
    .fetch_resp_valid (fetch_resp_valid),
    .fetch_inst       (fetch_inst),
    .refill_valid     (refill_valid),
    .refill_addr      (refill_addr),
    .refill_resp_valid(refill_resp_valid),
    .refill_rdata     (refill_rdata)
  );

  axi_mem_if u_mem_if (
    .clk        (clock),
    .reset      (reset),
    .req_valid  (mem_req_valid),
    .req_we     (mem_req_we),
    .req_addr   (mem_req_addr),
    .req_wdata  (mem_req_wdata),
    .req_wstrb  (mem_req_wstrb),
    .resp_valid (mem_resp_valid),
    .resp_rdata (mem_resp_rdata),
    .araddr     (araddr),
    .arvalid    (arvalid),
    .arready    (arready),
    .rdata      (rdata),
    .rresp      (rresp),
    .rvalid     (rvalid),
    .rready     (rready),
    .awaddr     (awaddr),
    .awvalid    (awvalid),
    .awready    (awready),
    .wdata      (wdata),
    .wstrb      (wstrb),
    .wvalid     (wvalid),
    .wready     (wready),
    .bresp      (bresp),
    .bvalid     (bvalid),
    .bready     (bready)
  );

endmodule

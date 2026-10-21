// -----------------------------------------------------------------------------
// student_top_ooo.sv — P1 集成用顶层（模块名仍为 student_top）
//
// 组成：
//   core_ooo     —— 甲：取指/BPU/I-Cache/decode/rename/ROB/commit
//   backend_ooo  —— 乙：PRF/IQ/CDB/ALU/divider/LSU/LSQ
//   mem_subsystem—— 乙：I$ 回填 + 数据访存 + axi_mem_if
//
// 该文件只用于 test/integration/filelist.f；官方 verilog/filelist.f 仍由甲
// 维护，替换 student_top 前双方需确认。
// -----------------------------------------------------------------------------

module student_top (
  input  wire        clock,
  input  wire        reset,

  output wire [31:0] araddr,
  output wire        arvalid,
  input  wire        arready,

  input  wire [31:0] rdata,
  input  wire [1:0]  rresp,
  input  wire        rvalid,
  output wire        rready,

  output wire [31:0] awaddr,
  output wire        awvalid,
  input  wire        awready,

  output wire [31:0] wdata,
  output wire [3:0]  wstrb,
  output wire        wvalid,
  input  wire        wready,

  input  wire [1:0]  bresp,
  input  wire        bvalid,
  output wire        bready
);

  // core_ooo <-> backend_ooo
  logic                    backend_ready;
  logic [`CPU_DISPATCH_BUS_W-1:0] dispatch;
  logic [`CPU_COMMIT_BUS_W-1:0]   commit;
  logic [`CPU_SQUASH_W-1:0]       squash;
  logic [`CPU_CDB_BUS_W-1:0]      cdb;
  logic [`CPU_COMPLETE_BUS_W-1:0] complete;
  logic [`CPU_BR_UPDATE_W-1:0]    br_update;
  logic                    halt;

  // I-Cache refill
  logic        if_refill_valid;
  logic [31:0] if_refill_addr;
  logic        if_refill_resp_valid;
  logic [31:0] if_refill_rdata;

  logic        if_refill_valid1;
  logic [31:0] if_refill_addr1;
  logic        if_refill_resp_valid1;
  logic [31:0] if_refill_rdata1;

  logic        unused_data_resp_valid;
  logic [31:0] unused_data_resp_rdata;

  // pipelined load interface
  logic        ld_req_valid;
  logic [31:0] ld_req_addr;
  logic        ld_req_ready;
  logic        ld_resp_valid;
  logic [31:0] ld_resp_rdata;

  // D-Cache <-> mem_subsystem load port
  logic        dl_req_valid;
  logic [31:0] dl_req_addr;
  logic        dl_req_ready;
  logic        dl_resp_valid;
  logic [31:0] dl_resp_rdata;
  logic        st_inv_valid;
  logic [31:0] st_inv_addr;

  // pipelined store interface
  logic        st_req_valid;
  logic [31:0] st_req_addr;
  logic [31:0] st_req_wdata;
  logic [3:0]  st_req_wstrb;
  logic        st_req_ready;
  logic        st_resp_valid;

  core_ooo u_core (
    .clk               (clock),
    .reset             (reset),
    .backend_ready     (backend_ready),
    .cdb               (cdb),
    .complete          (complete),
    .br_update         (br_update),
    .dispatch          (dispatch),
    .commit            (commit),
    .squash            (squash),
    .halt              (halt),
    .refill_valid      (if_refill_valid),
    .refill_addr       (if_refill_addr),
    .refill_resp_valid (if_refill_resp_valid),
    .refill_rdata      (if_refill_rdata),
    .refill_valid1     (if_refill_valid1),
    .refill_addr1      (if_refill_addr1),
    .refill_resp_valid1(if_refill_resp_valid1),
    .refill_rdata1     (if_refill_rdata1)
  );

  backend_ooo u_backend (
    .clk            (clock),
    .reset          (reset),
    .dispatch       (dispatch),
    .commit         (commit),
    .squash         (squash),
    .cdb            (cdb),
    .complete       (complete),
    .br_update      (br_update),
    .backend_ready  (backend_ready),
    .ld_req_valid   (ld_req_valid),
    .ld_req_addr    (ld_req_addr),
    .ld_req_ready   (ld_req_ready),
    .ld_resp_valid  (ld_resp_valid),
    .ld_resp_rdata  (ld_resp_rdata),
    .st_inv_valid   (st_inv_valid),
    .st_inv_addr    (st_inv_addr),
    .st_req_valid   (st_req_valid),
    .st_req_addr    (st_req_addr),
    .st_req_wdata   (st_req_wdata),
    .st_req_wstrb   (st_req_wstrb),
    .st_req_ready   (st_req_ready),
    .st_resp_valid  (st_resp_valid)
  );

  mem_subsystem u_mem (
    .clk             (clock),
    .reset           (reset),
    .if_req_valid    (if_refill_valid),
    .if_req_addr     (if_refill_addr),
    .if_resp_valid   (if_refill_resp_valid),
    .if_resp_rdata   (if_refill_rdata),
    .if2_req_valid   (if_refill_valid1),
    .if2_req_addr    (if_refill_addr1),
    .if2_resp_valid  (if_refill_resp_valid1),
    .if2_resp_rdata  (if_refill_rdata1),
    .ld_req_valid    (ld_req_valid),
    .ld_req_addr     (ld_req_addr),
    .ld_req_ready    (ld_req_ready),
    .ld_resp_valid   (ld_resp_valid),
    .ld_resp_rdata   (ld_resp_rdata),
    .st_req_valid    (st_req_valid),
    .st_req_addr     (st_req_addr),
    .st_req_wdata    (st_req_wdata),
    .st_req_wstrb    (st_req_wstrb),
    .st_req_ready    (st_req_ready),
    .st_resp_valid   (st_resp_valid),
    .data_req_valid  (1'b0),
    .data_req_we     (1'b0),
    .data_req_addr   (32'b0),
    .data_req_wdata  (32'b0),
    .data_req_wstrb  (4'b0),
    .data_resp_valid (unused_data_resp_valid),
    .data_resp_rdata (unused_data_resp_rdata),
    .araddr          (araddr),
    .arvalid         (arvalid),
    .arready         (arready),
    .rdata           (rdata),
    .rresp           (rresp),
    .rvalid          (rvalid),
    .rready          (rready),
    .awaddr          (awaddr),
    .awvalid         (awvalid),
    .awready         (awready),
    .wdata           (wdata),
    .wstrb           (wstrb),
    .wvalid          (wvalid),
    .wready          (wready),
    .bresp           (bresp),
    .bvalid          (bvalid),
    .bready          (bready)
  );

endmodule

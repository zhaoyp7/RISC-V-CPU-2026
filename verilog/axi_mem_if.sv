// -----------------------------------------------------------------------------
// axi_mem_if.sv — AXI4-Lite 总线主机适配器
//
// 把 AXI4-Lite 的五通道协议封装成简单的 req/resp 事务接口：
//   - core 给出 req_valid + 地址/写数据，本模块负责完成整个 AXI 握手，
//     完成后拉高 resp_valid（组合信号，与最后一次握手同拍）；
//   - 同一时刻只处理一笔事务（IDLE 时才接受新请求），因此不需要乱序/并发。
//
// 状态机：
//   ST_IDLE    —— 等待请求，锁存地址与写数据；
//   ST_RD_ADDR —— 驱动 AR 通道，等 arready；
//   ST_RD_DATA —— 驱动 rready，等 rvalid，握手即响应；
//   ST_WR_ADDR —— 同时驱动 AW 与 W 通道，分别记录各自是否已完成
//                 （AXI 允许两个通道先后握手）；
//   ST_WR_RESP —— 驱动 bready，等 bvalid，握手即响应。
//
// AXI 协议纪律：
//   - arvalid/awvalid/wvalid 只由状态与完成标志驱动，绝不组合依赖 ready；
//   - 请求一旦发出就保持地址/数据稳定，直到对应握手完成。
// -----------------------------------------------------------------------------

module axi_mem_if (
  input  logic        clk,
  input  logic        reset,

  // 事务请求（来自 core 数据通路或 icache 回填）
  input  logic        req_valid,
  input  logic        req_we,      // 0 = 读，1 = 写
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,

  // 事务响应
  output logic        resp_valid,  // 完成脉冲（组合，与握手同拍）
  output logic [31:0] resp_rdata,

  // AXI4-Lite 读地址通道
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,

  // AXI4-Lite 读数据通道
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,

  // AXI4-Lite 写地址通道
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,

  // AXI4-Lite 写数据通道
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,

  // AXI4-Lite 写响应通道
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_RD_ADDR,
    ST_RD_DATA,
    ST_WR_ADDR,
    ST_WR_RESP
  } state_t;

  state_t      state;
  logic [31:0] addr_q;   // 锁存的请求地址
  logic [31:0] wdata_q;  // 锁存的写数据
  logic [3:0]  wstrb_q;  // 锁存的写掩码
  logic        aw_done;  // 写地址已握手
  logic        w_done;   // 写数据已握手

  logic aw_fire;
  logic w_fire;

  assign araddr = addr_q;
  assign awaddr = addr_q;
  assign wdata  = wdata_q;
  assign wstrb  = wstrb_q;

  // 各通道 valid/ready 驱动（valid 均不依赖 ready）
  assign arvalid = (state == ST_RD_ADDR);
  assign rready  = (state == ST_RD_DATA);
  assign awvalid = (state == ST_WR_ADDR) && !aw_done;
  assign wvalid  = (state == ST_WR_ADDR) && !w_done;
  assign bready  = (state == ST_WR_RESP);

  assign aw_fire = awvalid && awready;
  assign w_fire  = wvalid && wready;

  // 读数据或写响应握手完成即产生一次响应
  assign resp_valid = ((state == ST_RD_DATA) && rvalid && rready) ||
                      ((state == ST_WR_RESP) && bvalid && bready);
  assign resp_rdata = rdata;

  always_ff @(posedge clk) begin
    if (reset) begin
      state   <= ST_IDLE;
      addr_q  <= 32'b0;
      wdata_q <= 32'b0;
      wstrb_q <= 4'b0;
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end else begin
      unique case (state)
        ST_IDLE: begin
          if (req_valid) begin
            addr_q  <= req_addr;
            wdata_q <= req_wdata;
            wstrb_q <= req_wstrb;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            state   <= req_we ? ST_WR_ADDR : ST_RD_ADDR;
          end
        end
        ST_RD_ADDR: begin
          if (arready) state <= ST_RD_DATA;
        end
        ST_RD_DATA: begin
          if (rvalid && rready) state <= ST_IDLE;
        end
        ST_WR_ADDR: begin
          // AW 与 W 相互独立，任意一个可以先完成
          if (aw_fire) aw_done <= 1'b1;
          if (w_fire)  w_done  <= 1'b1;
          if ((aw_done || aw_fire) && (w_done || w_fire)) state <= ST_WR_RESP;
        end
        ST_WR_RESP: begin
          if (bvalid && bready) state <= ST_IDLE;
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule

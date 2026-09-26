// -----------------------------------------------------------------------------
// icache.sv — 直接映射指令 Cache（每行 1 个字）
//
// 结构：
//   - 1024 行（INDEX_BITS=10），总容量 4 KiB 代码；
//   - 每行保存 32 位指令 + 20 位 tag（pc[31:12]）+ 1 位 valid（FF 阵列）；
//   - tag 与数据分别用 sram_fakeram 实现，同步 1 周期读延迟；
//   - valid 位用触发器阵列，复位时清零（SRAM 无复位值，故不入 SRAM）。
//
// 状态机：
//   ST_IDLE   —— 有取指请求时锁存 PC，并向 SRAM 发起 tag/data 读；
//   ST_LOOKUP —— 下一周期比较 tag + valid：
//                 命中：组合输出 fetch_resp_valid 与指令；
//                 缺失：向共享 AXI 引擎发起 refill 请求，进入 ST_REFILL；
//   ST_REFILL —— 等待 AXI 返回，把数据写入 data SRAM、tag 写入 tag SRAM、
//                置 valid；同时把返回的指令直接旁路给 core（无需重读）。
//
// 命中路径为 2 周期，缺失路径约 2 + AXI 延迟；顺序代码循环起来后
// 命中率接近 100%，这正是 pi 等大程序周期数大幅下降的原因。
// -----------------------------------------------------------------------------

module icache #(
  parameter integer INDEX_BITS = 10   // 行数 = 2^INDEX_BITS
) (
  input  logic        clk,
  input  logic        reset,

  // core 取指请求
  input  logic        fetch_valid,
  input  logic [31:0] fetch_pc,
  output logic        fetch_resp_valid,
  output logic [31:0] fetch_inst,

  // 回填请求（占用共享 AXI 引擎，读请求）
  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata
);

  localparam integer DEPTH    = 1 << INDEX_BITS;
  localparam integer TAG_BITS = 32 - INDEX_BITS - 2;  // 去掉 index 与字内偏移

  typedef enum logic [1:0] {ST_IDLE, ST_LOOKUP, ST_REFILL} state_t;

  state_t                state;
  logic [TAG_BITS-1:0]   req_tag;    // 本次访问锁存的 tag
  logic [INDEX_BITS-1:0] req_index;  // 本次访问锁存的 index

  // data SRAM 端口
  logic                  data_en, data_we;
  logic [INDEX_BITS-1:0] data_addr;
  logic [31:0]           data_wdata;
  logic [31:0]           data_rdata;

  // tag SRAM 端口
  logic                  tag_en, tag_we;
  logic [INDEX_BITS-1:0] tag_addr;
  logic [TAG_BITS-1:0]   tag_wdata;
  logic [TAG_BITS-1:0]   tag_rdata;

  // valid 位：每行 1 位
  logic [DEPTH-1:0]      valid;

  sram_fakeram #(
    .DEPTH (DEPTH),
    .WIDTH (32)
  ) data_ram (
    .clk   (clk),
    .en    (data_en),
    .we    (data_we),
    .wmask (1'b1),
    .addr  (data_addr),
    .wdata (data_wdata),
    .rdata (data_rdata)
  );

  sram_fakeram #(
    .DEPTH (DEPTH),
    .WIDTH (TAG_BITS)
  ) tag_ram (
    .clk   (clk),
    .en    (tag_en),
    .we    (tag_we),
    .wmask (1'b1),
    .addr  (tag_addr),
    .wdata (tag_wdata),
    .rdata (tag_rdata)
  );

  // 命中：valid 有效且 tag 相等
  logic hit;
  assign hit = valid[req_index] && (tag_rdata == req_tag);

  // ---- SRAM 读写控制 -------------------------------------------------------
  always_comb begin
    data_en    = 1'b0;
    data_we    = 1'b0;
    data_addr  = req_index;
    data_wdata = 32'b0;
    tag_en     = 1'b0;
    tag_we     = 1'b0;
    tag_addr   = req_index;
    tag_wdata  = req_tag;

    unique case (state)
      ST_IDLE: begin
        if (fetch_valid) begin
          // 发起读：下一周期 LOOKUP 时 rdata 有效
          data_en   = 1'b1;
          data_addr = fetch_pc[INDEX_BITS+1:2];
          tag_en    = 1'b1;
          tag_addr  = fetch_pc[INDEX_BITS+1:2];
        end
      end
      ST_REFILL: begin
        if (refill_resp_valid) begin
          // 回填：写 data 与 tag，并在时序逻辑里置 valid
          data_en    = 1'b1;
          data_we    = 1'b1;
          data_addr  = req_index;
          data_wdata = refill_rdata;
          tag_en     = 1'b1;
          tag_we     = 1'b1;
          tag_addr   = req_index;
          tag_wdata  = req_tag;
        end
      end
      default: ;
    endcase
  end

  // 命中或回填完成时向 core 返回指令
  assign fetch_resp_valid = ((state == ST_LOOKUP) && hit) ||
                            ((state == ST_REFILL) && refill_resp_valid);
  assign fetch_inst = (state == ST_LOOKUP) ? data_rdata : refill_rdata;

  // 缺失时向 AXI 引擎发回填读请求；行内偏移为 0（行宽 1 个字）
  assign refill_valid = ((state == ST_LOOKUP) && !hit) || (state == ST_REFILL);
  assign refill_addr  = {req_tag, req_index, 2'b00};

  // ---- 状态机 --------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state     <= ST_IDLE;
      req_tag   <= '0;
      req_index <= '0;
      valid     <= '0;   // 上电全部无效
    end else begin
      unique case (state)
        ST_IDLE: begin
          if (fetch_valid) begin
            req_tag   <= fetch_pc[31:INDEX_BITS+2];
            req_index <= fetch_pc[INDEX_BITS+1:2];
            state     <= ST_LOOKUP;
          end
        end
        ST_LOOKUP: begin
          if (hit) state <= ST_IDLE;
          else state <= ST_REFILL;
        end
        ST_REFILL: begin
          if (refill_resp_valid) begin
            valid[req_index] <= 1'b1;
            state <= ST_IDLE;
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule

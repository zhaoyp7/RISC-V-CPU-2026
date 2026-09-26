// -----------------------------------------------------------------------------
// core.sv — 顺序执行内核（单周期执行数据通路 + 多周期访存 FSM）
//
// 总体原理：
//   外部内存是 10 周期延迟的 AXI4-Lite 从机，因此真正的 1 CPI 单周期机不
//   可行。本设计取折中：执行阶段（译码、读寄存器、ALU、写回、PC 更新）
//   在一个周期内完成，而取指与 load/store 由 FSM 拆成多个周期完成。
//
// 状态机（每条指令依次经过）：
//   ST_FETCH —— 向 I-Cache 发起取指（fetch_valid/fetch_pc），等待命中或
//               AXI 回填完成，取回指令放入 instr_q；
//   ST_EXEC  —— 组合译码 instr_q、读寄存器、算 ALU 结果与下一条 PC。
//               - ALU/跳转/分支类：本周期末尾写回寄存器并更新 PC，回 FETCH；
//               - Load/Store：PC 先 +4，进入 ST_MEM；
//   ST_MEM   —— 通过数据通路访问内存（data_req_*），等 data_resp_valid，
//               Load 此时把内存数据写回 rd；遇到对 0x80000000 的完整字
//               store（退出协议）则进入 ST_HALT；
//   ST_HALT  —— 停机，不再发起任何总线请求（仿真器在写响应握手时已结束）。
//
// 因为同一时刻只有一条指令在飞，且寄存器写在指令边界发生，不存在数据
// 相关，不需要前递；分支也无需预测，EXEC 算出目标后直接更新 PC。
//
// 退出协议：程序最后执行一条 sw 到 0x80000000（wstrb = 4'hf），本模块把
// 它当普通 store 发给内存，等待写响应后停机；仿真器在写响应握手瞬间捕获
// WDATA 作为返回值并结束仿真。
// -----------------------------------------------------------------------------

module core (
  input  logic        clk,
  input  logic        reset,

  // 取指接口（接 icache）
  output logic        fetch_valid,
  output logic [31:0] fetch_pc,
  input  logic        fetch_resp_valid,
  input  logic [31:0] fetch_inst,

  // 数据访存接口（接 AXI 引擎）
  output logic        data_req_valid,
  output logic        data_req_we,
  output logic [31:0] data_req_addr,
  output logic [31:0] data_req_wdata,
  output logic [3:0]  data_req_wstrb,
  input  logic        data_resp_valid,
  input  logic [31:0] data_resp_rdata
);

  typedef enum logic [1:0] {ST_FETCH, ST_EXEC, ST_MEM, ST_HALT} state_t;

  state_t      state;
  logic [31:0] pc;       // 当前取指 PC（分支/跳转在下一条指令生效前更新）
  logic [31:0] instr_q;  // 已取回、正在执行的指令

  // ---- 译码器输出 ----------------------------------------------------------
  logic [4:0]  rs1, rs2, rd;
  logic        reg_we;
  logic [1:0]  wb_sel;
  logic [4:0]  alu_op;
  logic [1:0]  a_sel;
  logic        b_sel;
  logic [31:0] imm;
  logic        is_branch, is_jal, is_jalr, is_load, is_store;
  logic [1:0]  mem_size;
  logic        mem_unsigned;
  logic        illegal;

  decoder u_decoder (
    .instr        (instr_q),
    .rs1          (rs1),
    .rs2          (rs2),
    .rd           (rd),
    .reg_we       (reg_we),
    .wb_sel       (wb_sel),
    .alu_op       (alu_op),
    .a_sel        (a_sel),
    .b_sel        (b_sel),
    .imm          (imm),
    .is_branch    (is_branch),
    .is_jal       (is_jal),
    .is_jalr      (is_jalr),
    .is_load      (is_load),
    .is_store     (is_store),
    .mem_size     (mem_size),
    .mem_unsigned (mem_unsigned),
    .illegal      (illegal)
  );

  // ---- 寄存器堆 ------------------------------------------------------------
  logic [31:0] rdata1, rdata2;
  logic        rf_we;
  logic [4:0]  rf_waddr;
  logic [31:0] rf_wdata;

  regfile u_regfile (
    .clk    (clk),
    .we     (rf_we),
    .waddr  (rf_waddr),
    .wdata  (rf_wdata),
    .raddr1 (rs1),
    .raddr2 (rs2),
    .rdata1 (rdata1),
    .rdata2 (rdata2)
  );

  // ---- ALU：操作数选择与实例化 ---------------------------------------------
  logic [31:0] alu_a, alu_b, alu_y;

  always_comb begin
    unique case (a_sel)
      `A_PC:   alu_a = pc;       // AUIPC
      `A_ZERO: alu_a = 32'b0;    // LUI
      default: alu_a = rdata1;   // 常规 rs1
    endcase
  end

  assign alu_b = (b_sel == `B_IMM) ? imm : rdata2;

  alu u_alu (
    .a  (alu_a),
    .b  (alu_b),
    .op (alu_op),
    .y  (alu_y)
  );

  // ---- 分支/跳转：分支条件与下一条 PC --------------------------------------
  logic        br_taken;
  logic [31:0] next_pc;

  always_comb begin
    br_taken = 1'b0;
    if (is_branch) begin
      case (instr_q[14:12])  // 直接使用 funct3 区分 6 种分支
        3'b000:  br_taken = (rdata1 == rdata2);                   // BEQ
        3'b001:  br_taken = (rdata1 != rdata2);                   // BNE
        3'b100:  br_taken = ($signed(rdata1) <  $signed(rdata2)); // BLT
        3'b101:  br_taken = ($signed(rdata1) >= $signed(rdata2)); // BGE
        3'b110:  br_taken = (rdata1 <  rdata2);                   // BLTU
        3'b111:  br_taken = (rdata1 >= rdata2);                   // BGEU
        default: br_taken = 1'b0;
      endcase
    end
  end

  // JAL/JALR 无条件跳转；分支命中跳转；否则 PC+4
  assign next_pc =
    is_jalr              ? ((rdata1 + imm) & ~32'b1) :
    (is_jal || br_taken) ? (pc + imm) :
    (pc + 32'd4);

  // ---- 访存地址与写数据 ----------------------------------------------------
  logic [31:0] mem_addr, mem_wdata;
  logic [3:0]  mem_wstrb;

  assign mem_addr = rdata1 + imm;

  // 根据访存宽度把 rs2 放到正确的字节通道，并生成 wstrb；
  // 测试程序保证自然对齐，因此字节/半字不需要跨字处理。
  always_comb begin
    unique case (mem_size)
      `SZ_BYTE: begin
        mem_wstrb = 4'b0001 << mem_addr[1:0];
        mem_wdata = {4{rdata2[7:0]}} << (8 * mem_addr[1:0]);
      end
      `SZ_HALF: begin
        mem_wstrb = mem_addr[1] ? 4'b1100 : 4'b0011;
        mem_wdata = {2{rdata2[15:0]}} << (16 * mem_addr[1]);
      end
      default: begin
        mem_wstrb = 4'b1111;
        mem_wdata = rdata2;
      end
    endcase
  end

  // ---- Load 数据提取：从对齐字中选出字节/半字并扩展 ------------------------
  logic [7:0]  ld_byte;
  logic [15:0] ld_half;
  logic [31:0] load_data;

  assign ld_byte = data_resp_rdata[8 * mem_addr[1:0] +: 8];
  assign ld_half = data_resp_rdata[16 * mem_addr[1] +: 16];

  always_comb begin
    unique case (mem_size)
      `SZ_BYTE: load_data = mem_unsigned ? {24'b0, ld_byte} : {{24{ld_byte[7]}}, ld_byte};
      `SZ_HALF: load_data = mem_unsigned ? {16'b0, ld_half} : {{16{ld_half[15]}}, ld_half};
      default: load_data = data_resp_rdata;
    endcase
  end

  // ---- 退出协议检测：完整字（wstrb=4'hf）写入 0x80000000 --------------------
  logic halt_store;
  assign halt_store = is_store && (mem_addr == 32'h8000_0000) && (mem_wstrb == 4'hf);

  // ---- 取指 / 访存请求 -----------------------------------------------------
  assign fetch_valid = (state == ST_FETCH) && !reset;
  assign fetch_pc    = pc;

  assign data_req_valid = (state == ST_MEM) && !reset;
  assign data_req_we    = is_store;
  assign data_req_addr  = mem_addr;
  assign data_req_wdata = mem_wdata;
  assign data_req_wstrb = mem_wstrb;

  // ---- 寄存器写回 ----------------------------------------------------------
  // ALU/跳转类在 ST_EXEC 末尾写；Load 在 ST_MEM 收到响应时写。
  // 写回数据来源由 wb_sel 决定：ALU 结果 / 内存数据 / PC+4（JAL/JALR）。
  always_comb begin
    rf_we    = 1'b0;
    rf_waddr = rd;
    rf_wdata = alu_y;
    if (state == ST_EXEC) begin
      if (reg_we && !is_load && !is_store && !illegal) begin
        rf_we    = 1'b1;
        rf_wdata = (wb_sel == `WB_PC4) ? (pc + 32'd4) : alu_y;
      end
    end else if (state == ST_MEM) begin
      if (is_load && reg_we && data_resp_valid) begin
        rf_we    = 1'b1;
        rf_wdata = load_data;
      end
    end
  end

  // ---- 主状态机 ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state   <= ST_FETCH;
      pc      <= 32'b0;      // 程序入口固定为 0x0
      instr_q <= 32'b0;
    end else begin
      unique case (state)
        ST_FETCH: begin
          if (fetch_resp_valid) begin
            instr_q <= fetch_inst;
            state   <= ST_EXEC;
          end
        end
        ST_EXEC: begin
          if (illegal) begin
            // 收到非法指令则停机，便于定位问题（正常测试不会触发）
            state <= ST_HALT;
          end else if (is_load || is_store) begin
            // 访存指令：PC 已指向下一条，进入访存状态
            pc    <= pc + 32'd4;
            state <= ST_MEM;
          end else begin
            // ALU/分支/跳转：写回与 PC 更新都在本周期末完成
            pc    <= next_pc;
            state <= ST_FETCH;
          end
        end
        ST_MEM: begin
          if (data_resp_valid) begin
            if (is_store && halt_store) begin
              state <= ST_HALT;  // 退出 store 完成，停机
            end else begin
              state <= ST_FETCH;
            end
          end
        end
        default: state <= ST_HALT;
      endcase
    end
  end

endmodule

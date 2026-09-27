module divider (
  input  logic        clk,
  input  logic        reset,
  input  logic        start,        // 1 拍脉冲；busy=1 时应忽略
  input  logic        is_signed,    // 1: DIV/REM, 0: DIVU/REMU
  input  logic [31:0] a,            // 被除数
  input  logic [31:0] b,            // 除数
  output logic        busy,
  output logic        done,         // 完成时 1 拍脉冲
  output logic [31:0] quotient,
  output logic [31:0] remainder
);

  logic signed [31:0] a_s;
  logic signed [31:0] b_s;
  logic        [31:0] a_u;
  logic        [31:0] b_u;
  logic signed [31:0] quot_s;
  logic signed [31:0] rem_s;
  logic        [31:0] quot_u;
  logic        [31:0] rem_u;

  assign a_s = a;
  assign a_u = a;
  assign b_s = b;
  assign b_u = b;

endmodule
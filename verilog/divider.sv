module divider (
  input  logic        is_signed,    // 1: DIV/REM, 0: DIVU/REMU
  input  logic [31:0] a,            // 被除数
  input  logic [31:0] b,            // 除数
  output logic [31:0] quotient,
  output logic [31:0] remainder
);

  logic [31:0] a_u;
  logic [31:0] b_u;
  logic [31:0] quot_u;
  logic [31:0] rem_u;
  logic negative_a, negative_b;
  assign negative_a = is_signed && a[31];
  assign negative_b = is_signed && b[31];
  assign a_u = negative_a ? -$signed(a) : a;
  assign b_u = negative_b ? -$signed(b) : b;
  logic [31:0] rest_u [0:32];
  assign rest_u[32] = a_u;
  always_comb begin
    for (int i = 31; i >= 0; i--) begin
      rest_u[i] = 32'b0;
      quot_u[i] = 1'b0;
      if ((rest_u[i + 1] >> i) >= b_u) begin
        rest_u[i] = rest_u[i + 1] - (b_u << i);
        quot_u[i] = 1;
      end else begin
        rest_u[i] = rest_u[i + 1];
        quot_u[i] = 0;
      end
    end
  end
  assign rem_u = rest_u[0];
  assign quotient = (negative_a ^ negative_b) ? -$signed(quot_u) : quot_u;
  assign remainder = negative_a ? -$signed(rem_u) : rem_u;

endmodule

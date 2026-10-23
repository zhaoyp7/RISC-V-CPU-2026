// Test-only wrapper; never include in the official RTL filelist.
module alu_test_top (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [4:0]  op,
  output logic [31:0] y
);
  alu #(.ENABLE_DIV(`ALU_TEST_ENABLE_DIV)) dut (
    .a(a), .b(b), .op(op), .y(y)
  );
endmodule

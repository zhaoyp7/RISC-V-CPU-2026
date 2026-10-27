// Test-only two-entry completion queue, including data and store races.
module line_queue_top (
  input wire clk, reset,
  input wire req_valid,
  input wire [31:0] req_addr,
  output wire req_ready,
  output wire resp_valid,
  output wire [31:0] resp_data,
  output wire mem_valid,
  output wire [31:0] mem_addr,
  input wire mem_ready,
  input wire mem_resp_valid,
  input wire [31:0] mem_resp_data,
  input wire store_fire,
  input wire [31:0] store_addr, store_data,
  input wire [3:0] store_mask,
  output wire store_ready,
  input wire store_resp_valid
);
 load_line_cache #(.QDEPTH(2)) dut(.*);
endmodule

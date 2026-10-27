// Test-only wrapper for instruction refill coalescing and ownership.
module if_line_mem_top (
  input  logic        clk,
  input  logic        reset,

  // I-Cache refill client
  input  logic        if_req_valid,
  input  logic [31:0] if_req_addr,
  output logic        if_resp_valid,
  output logic [31:0] if_resp_rdata,

  // Second I-Cache refill client (dual-fetch)
  input  logic        if2_req_valid,
  input  logic [31:0] if2_req_addr,
  output logic        if2_resp_valid,
  output logic [31:0] if2_resp_rdata,

  // Pipelined load client (LSU)
  input  logic        ld_req_valid,
  input  logic [31:0] ld_req_addr,
  output logic        ld_req_ready,
  output logic        ld_resp_valid,
  output logic [31:0] ld_resp_rdata,

  // Pipelined store client (LSU)
  input  logic        st_req_valid,
  input  logic [31:0] st_req_addr,
  input  logic [31:0] st_req_wdata,
  input  logic [3:0]  st_req_wstrb,
  output logic        st_req_ready,
  output logic        st_resp_valid,

  // Legacy P1 data client (single outstanding; unit test)
  input  logic        data_req_valid,
  input  logic        data_req_we,
  input  logic [31:0] data_req_addr,
  input  logic [31:0] data_req_wdata,
  input  logic [3:0]  data_req_wstrb,
  output logic        data_resp_valid,
  output logic [31:0] data_resp_rdata,

  // AXI4-Lite
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);
 mem_subsystem #(.IF_LINE_BUFFER(1)) dut(.*);
endmodule

# RTL paths are relative to this file in verilog/.
# The top-level module must be named student_top.
#
# rv32_defs.sv MUST be first: it only contains `define macros that the other
# files consume, and both Verilator and Yosys share macros in file order.
rv32_defs.sv
alu.sv
regfile.sv
decoder.sv
core.sv
icache.sv
axi_mem_if.sv
student_top.sv

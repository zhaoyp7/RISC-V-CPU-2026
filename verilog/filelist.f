# RTL paths are relative to this file in verilog/.
# The top-level module must be named student_top.
#
# P1 OoO integration (2026-10-18):
#   - rv32_defs.sv / cpu_config.sv / if_defs.sv must stay first (macro order).
#   - The baseline core.sv/icache.sv/student_top.sv are kept in the tree for
#     rollback but are not part of this file list.
#   - student_top_ooo.sv intentionally declares module student_top.
rv32_defs.sv
cpu_config.sv
if_defs.sv

alu.sv
divider.sv
prf.sv
cdb.sv
issue_queue.sv
lsq.sv
lsu.sv
backend_ooo.sv

pc_unit.sv
bpu.sv
icache_pipe.sv
decoder.sv
rename.sv
commit.sv
rob.sv
frontend_ooo.sv
core_ooo.sv

mem_subsystem.sv
axi_mem_if.sv
student_top_ooo.sv

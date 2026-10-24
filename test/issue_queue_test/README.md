# IQ 行为与候选选择回归

运行 `APPIMAGE_EXTRACT_AND_RUN=1 sh test/issue_queue_test/run.sh`，已接入 run_all。

`issue_queue_tb.cpp` 保留原有 IW1 行为检查：W1/R1、W2/R1、W2/R2。
`issue_queue_select_top.sv` 仅用于参数化测试，不加入官方 filelist。
`issue_queue_select_tb.cpp` 使用独立 slot scoreboard 按 `(seq, slot)` 排序，
逐拍检查全部输出 uop 字段、seq、valid、地址预填、容量和握手后的状态。

矩阵为 W2/R2/IW1/D8、W1/R1/IW2/D8、W2/R2/IW2/D8/D6/D16；每档包含定向
预填/反压/唤醒检查及固定种子的40,000随机周期，覆盖槽位复用、相同年龄和
squash/dispatch 同拍。PRF64/ROB32/LSQ8固定，不修改默认核参数。

年龄关系状态实验增加定向边界：高位seq、UINT32_MAX跨界双分配、复位后重建、
以及squash同拍复用多个槽。仍使用外部端口与独立排序参考，不读取内部年龄矩阵。

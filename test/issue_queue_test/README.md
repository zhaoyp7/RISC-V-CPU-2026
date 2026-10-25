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

ALU1候选限制实验增加四档LANE1_ALU_ONLY=1矩阵：W1/R1/D8、W2/R2/D8/D6/D16（均IW2）。
独立参考按uop语义过滤第二通道，检查跳过访存、分支、JAL/JALR、四种DIV/REM、
illegal和无写回指令；lane0反压时仍保留其槽，年轻普通ALU可被lane1接收。
每档另有11类定向检查及40,000随机周期，覆盖保留项、独立握手、同龄、回绕、
store预填、唤醒、取消和槽位复用；原五档默认策略矩阵继续执行。

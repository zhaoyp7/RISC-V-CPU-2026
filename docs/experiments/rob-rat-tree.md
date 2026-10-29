# ROB恢复RAT固定槽选择树（2026-10-25）

## 结果与决定

基于9747662/feat/freq-rob32-match，分支feat/area-rob-recovery-rat；只改恢复RAT的组合计算。
默认配置文件保持不变，实验仍ROB32/PRF64/IQ8/CDB2/LSQ16。

| 版本（ROB32/PRF64/IQ8/LSQ16） | W2 IPC | diagnose面积 µm² | 频率 MHz |
| --- | ---: | ---: | ---: |
| 固定完成匹配9747662 | 0.607639 | 23,429.641 | 376.47 |
| 恢复RAT固定槽选择树 | 0.607639 | 23,281.158 | 376.47 |

总面积减少148.482720 µm²（0.634%），频率和IPC不变，IPC×Fmax/面积改善0.638%。
面积确有下降，保留独立检查点area-rob-rat-tree-20261025；它只是0.63%的小幅改善，尚未解决总面积偏大。
用户已授权连续推进，后续继续寻找减少恢复/查找网络实际资源的方法；不在此轮后等待新指令，不自动opt或合main。
本轮一次有效diagnose约9.35分钟；无中断/重试。未新增流水、寄存器阵列、队列容量或额外执行资源。

## 面积来源的测量

先对9747662的已映射网表追踪寄存器D端与组合输出的反向逻辑锥，遇到时序单元停止。
按ASAP7库单元真实面积计数，并核对单元总和、时序面积与正式ROB报告一致；共享单元在exclusive_partition只计一次。

| 区域 | 原锥面积 | 新锥面积 | 原独占面积 | 新独占面积 |
| --- | ---: | ---: | ---: | ---: |
| 恢复RAT | 1839.048 | 1646.009 | 1322.158 | 1191.230 |
| 恢复free/busy掩码 | 1374.384 | 1340.879 | 799.771 | 806.289 |
| 恢复LSQ指针 | 619.169 | 585.810 | 121.612 | 123.463 |
| 其余状态更新 | 1867.071 | 1853.031 | 1229.663 | 1258.444 |

逻辑锥面积包含共享逻辑，不可相加；独占仅表示相对本工具其他输出组未共享，不代表可全部删除。
原RAT独占约1,322 µm²是首要改写依据；实际重写后总面积只减少148.483 µm²，不能把整个锥当成可回收面积。
ROB模块从5,381.216降至5,232.733 µm²，时序面积及其他模块面积保持相同；全核面积下降全部来自ROB组合逻辑。
源网表及结果build/synth/rob_rat_tree/{baseline-area-cones.json,area-cones.json}，工具tools/perf_stats/rob_area_cones.py。

## 改动与等价性

原逻辑按head循环旋转读取rd/tag，再动态索引写入打包RAT。
新逻辑固定物理槽叶子，以(slot-head)的环形年龄筛选branch及更老表项，按rd独立选择最年轻存活写入者。
物理槽顺序由(wrapped,slot)排序：低于head的槽wrapped=1、在程序序上更年轻；同组取较大物理槽。
平衡树各子树物理槽连续，因此两个有效子候选同组时取右子树，跨组时取wrapped子树。
没有存活写入者时回退crat，保留branch自身jal/jalr写回、非写回项忽略、年轻项取消与rd0接口语义。
树节点采用独立generate层次信号，避免整数组调度带来的假依赖；首版数组组织的对拍通过，但有UNOPTFLAT，
已在综合前改成独立节点并重新验证，最终无新增假依赖（仍保留既有IQ两条提示）。这不是增加流水级。

## 新增验证先在基线上通过

原ROB单测没有逐项比较recover_rat。本轮有序deque参考从crat起按存活程序序重放，比较恢复脉冲的全部32项。
额外遍历所有32个head位置、branch自身写/不写两类、重复rd、reg_we=0、非零crat回退、年轻同rd取消、
rd0/rd31及跨32位字的字段；不使用RTL物理槽排序、wrapped位或选择树。
新增检查先在9747662的原RAT上通过，再在最终RTL通过；两档完整50,000拍随机检查115666/115664项零失败。
ROB32的W1/W2与默认ROB16的W1/W2四组均按qsort→hanoi→queens后全量19/19，19项正确性与6项perf周期逐项相同。
ROB32 W2/W1 IPC0.607638658854/0.549105278548；默认16项0.538262837589/0.504222699251，只作兼容性与IPC，不复用旧PPA。
完整run_all ALL PASS；普通/统计版输入、答案、周期及全部模块计数器与9747662逐项相同，所有分区/包含关系检查通过。

## 时序与后续

首条仍为ROB取消→LSU/CDB ready→分支资格→ROB/rename准入→前端I$，D端2.616 ns；最小周期2.65625 ns。
本轮优先面积，没有改变该路径，频率保持376.470588 MHz；恢复RAT不是当前最高延迟路径。
后续重点查看仍有约806 µm²独占逻辑的恢复掩码与物理槽存活判定，结合其余状态更新的共享部分减少动态旋转/写索引。
应继续保留精确周期与功能对照，不用缩队列或增加级数掩盖代价。

## 参数与归档

24个候选输入hash与报告/归档/统计一致；与9747662相比仅verilog/rob.sv改变，其余23个不变。
7个库hash、工具、SRAM、ABC约束及SDC相同；Yosys展开和五份仿真器实际容量已核对。
Makefile、config.mk、scripts/、官方filelist、默认cpu_config与SRAM模型不改；main仍f4a0555，默认main报告/仿真器不覆盖。
归档build/synth/rob_rat_tree/，含基线/候选inputs、configuration.json、诊断报告、四组仿真器与19项/性能日志、
statistics/、新旧面积锥、单测及validation-results.json、comparison.json、verification.json。
回归驱动validate_rob_rat_tree.py与宏wrapper也在归档；源码、配置和wrapper须成套保留。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/rob_rat_tree \
  YOSYS="$REPO_ROOT/build/synth/rob_rat_tree/yosys.py"
python3 tools/perf_stats/collect.py --skip-build \
  --plain-sim build/synth/rob_rat_tree/w2/sim --stats-sim build/synth/rob_rat_tree/stats/sim \
  --reference-report build/synth/rob_rat_tree/diagnose/report.json --out build/synth/rob_rat_tree/statistics
```

REPO_ROOT为仓库绝对路径。重跑须另设目录保护已测报告；只运行了一次完整diagnose，没有opt。

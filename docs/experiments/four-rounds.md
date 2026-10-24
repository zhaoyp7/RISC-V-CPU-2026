# 连续四轮频率优化（2026-10-24）

用户授权连续完成四轮优化，每轮测量、归档并决定保留或回退后直接进入下一轮。
本批次从550754f开始，RTL为e9390ce的322.42 MHz检查点。
不运行opt、不合main、不推送；诊断值不作为最终验收数据。

初始基线：W2/W1 IPC 0.522108164152558 / 0.4988444806718703，
面积20,441.848760 µm²，Fmax322.418136 MHz，最小周期3.1015625 ns。
报告、网表、24个输入快照和仿真器归档于`build/synth/four_rounds_baseline/`。

## 第一轮：branch update数据与valid解耦

在backend_ooo中直接提供分支PC、taken、target、is_jalr和tag字段，valid仍为原br_issue。
原实现把整个数据包置零后仅在br_issue时赋值，使CDB ready及squash通过br_issue
门控tag，再进入ROB的分支匹配和提交逻辑。新实现让tag匹配提前计算，valid最终
决定解析和训练是否生效。没有增加寄存器、流水拍数或改变发射/取消条件。

已检查消费者：ROB的entry_resolved、flush_young及br_update_uncond都由valid门控；
前端BPU训练寄存器也仅在valid时捕获数据。redirect_pc等组合无效数据不应被消费者
在redirect_valid为0时使用。此轮须重点回归分支、取消、CDB反压及提交。

三项冒烟按qsort、hanoi、queens顺序通过；W1/W2各19/19、run_all ALL PASS、配置检查通过。
两档perf六项周期逐项与基线相同，复用[既有benchmark表](frontend-response-capacity.md#perf)。
一次diagnose、24个hash一致，结构检查0 problems：20,430.432620 µm² / 322.519685 MHz，
最小周期3.10058594 ns，WNS -1.099716 ns。相对初始基线频率+0.0315%、面积-0.05585%。
首条路径仍为IQ→PRF→LSU→LSQ，累计1.759/2.087/2.878/3.040 ns。
单项收益很小，保留为第二轮组合的中间对照，不宣称取得显著频率提升。
归档`build/synth/freq_r1_branch_payload/`，日志`/tmp/freq-r1-branch-payload-*.log`。

## 复现与归档约定

每轮使用同一官方filelist和默认配置；W1包装器仅增加CPU_ISSUE_WIDTH=1。
验证脚本为本机`/tmp/freq_four_validate.py`，不修改Makefile或scripts目录。
依次构建、三项冒烟（首错即停），随后启动单项diagnose，与下列回归同时运行：

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/<round>_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/<round>_w1 SIM="$REPO_ROOT/build/<round>_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
python3 tools/config_gen.py --check
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

每轮综合顺序运行，不与下一轮重叠。候选目录`build/synth/freq_rN_<name>/`保存完整
诊断、24个源码输入、两档仿真器及日志；核对输入hash后再使用报告数据。

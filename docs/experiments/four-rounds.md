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

## 第二轮：branch update解耦＋IQ tag树

以第一轮5a9b982为基线，恢复6637367的issue_queue tag树实现，其余RTL不变。
两个源tag随first/second/prefill候选树传递，输出tag不再等待物理slot索引整个uop。
原最老优先、store预填、late squash、registered wake及双lane独立反压不变；无额外拍数。
本轮专门验证两个局部改动的组合效果，不以单项路径缩短作为采用依据。
W1/W2各19/19、run_all ALL PASS、配置检查通过，两档perf六项周期与初始基线相同。
一次diagnose、24个输入hash一致：20,426.670980 µm² / 340.765391 MHz，
最小周期2.93457031 ns，WNS -0.934097 ns；相对初始基线频率+5.6905%、面积-0.07425%。
相对第一轮频率+5.657%，面积-3.762 µm²。保留组合，tag为freq-r2-iq-combined-20261024。
首条路径仍是IQ→PRF→LSU地址→LSQ，累计1.603/1.920/2.712/2.875 ns。
归档目录`build/synth/freq_r2_iq_combined/`。第三轮优先改进入队年龄信息的保存方式，
将反复比较32位seq的工作移出发射选择，不增加发射拍数。

## 第三轮：分配时保存IQ年龄关系

基于423e9a3 / freq-r2-iq-combined-20261024。对每对IQ物理槽保存一位年龄关系，
任一端分配时，以两端分配后的完整32位seq比较；相同seq时较低槽优先。
两端同拍分配均使用新seq；squash槽复用也按新seq更新。复位只清有效位，关系位在
相关槽分配时建立，所有参与选择的有效槽对都已更新。不改变32位年龄比较语义。

发射时，每个候选查询比它更老的ready集合：平衡树仅记录有无、是否至少两个，
据此选完整候选第一/第二名。lane0从完整候选与store预填的并集中选最老项；
若lane0为预填，lane1选完整第一名，否则选完整第二名。one-hot输出索引、seq和源tag，
其余uop仍按索引读。registered wake、late squash、独立lane反压及IW>2 fallback不变。
无额外流水拍数，但新增年龄关系状态和分配比较逻辑，须测面积及新的入队路径。

原IQ五档scoreboard共1,466,671项零失败；新增高位年龄、UINT32_MAX跨界双分配、
复位后重建及squash同拍复用的外部端口对拍，使用独立排序参考，不读取内部矩阵。
新增边界后的五档共1,468,560项零失败（原三档行为61/60/64项同样通过）；
W1/W2各19/19、run_all ALL PASS、配置检查通过；两档perf六项周期与基线相同。
一次diagnose、24个输入hash一致、结构检查0 problems：20,505.023900 µm² / 402.357564 MHz，
最小周期2.48535156 ns，WNS -0.484783 ns。相对第二轮频率+18.075%、面积+78.353 µm²
（+0.384%）；相对初始频率+24.794%、面积+0.309%。保留tag freq-r3-age-matrix-20261024。
新的第一条路径ROB→backend→LSU结果valid→CDB→ROB完成搜索，累计0.070/0.528/1.072/1.442/2.425 ns。
IQ packed树节点产生Verilator UNOPTFLAT假依赖，实际为单向树；结构检查无环，全部功能检查通过。
第四轮将以独立unpacked节点消除警告，同时针对CDB仲裁做并行授权实验。
归档`build/synth/freq_r3_age_matrix/`，额外边界日志在/tmp/freq-r3-age-matrix-iq-boundary.log。

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

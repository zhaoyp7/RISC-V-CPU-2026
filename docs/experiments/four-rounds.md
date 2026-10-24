# 连续四轮频率优化（2026-10-24）

用户授权连续完成四轮优化，每轮测量、归档并决定保留或回退后直接进入下一轮。
本批次从550754f开始，RTL为e9390ce的322.42 MHz检查点。
不运行opt、不合main、不推送；诊断值不作为最终验收数据。

## 四轮结果与最终选择

| 轮次 | 改动 | diagnose面积 µm² | diagnose MHz | 决定 |
| --- | --- | ---: | ---: | --- |
| 起点 | e9390ce | 20,441.849 | 322.42 | 基线 |
| 1 | branch update数据提前输出 | 20,430.433 | 322.52 | 中间对照 |
| 2 | 组合IQ tag树 | 20,426.671 | 340.77 | 保留为后续基线 |
| 3 | 分配时记录IQ年龄关系 | 20,505.024 | 402.36 | 最终保留 |
| 4 | 并行CDB授权＋IQ节点声明清理 | 20,482.585 | 385.25 | 回退 |

最终选择第三轮，频率较起点+24.794%、面积+0.309%，W2/W1 IPC仍为0.5221/0.4988。
四轮分别W1/W2各19/19、run_all ALL PASS，各一次diagnose及24个输入hash一致。
四轮每档19项correctness周期和6项perf周期均与起点逐项一致，复用既有benchmark表。
未运行opt、未合main、未推送；main仍bc795ae。本批四轮结束，不继续第五轮。

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

## 第四轮：并行CDB授权＋IQ树节点声明清理

基于ba7ceb6 / freq-r3-age-matrix-20261024。原仲裁每lane动态循环扫描并排除前一lane
已选源；新实现为每个寄存轮转位置预计算有效源前缀数量，lane r选择前缀数量等于r
的有效源。各lane授权并行产生，通过one-hot掩码路由payload，轮转寄存器更新规则不变。

等价依据：前r条lane已选轮转序列的前r个有效源，序列前r个位置中任何有效源均已选，
因此原lane r从偏移r开始扫描，不会跳过任何尚未选择的有效源；其结果就是同一序列
的第r个有效源。空闲lane及ready保持原精确取值，不提前接收或新增缓冲。

同时将IQ any/multi树节点拆为独立unpacked信号，添加Verilator split_var提示，
只清理工具误判的数据依赖，不改变逻辑。CDB前缀数组同样按独立节点声明。
第三轮路径边界已从映射网表确认：LSU src_valid[2]经CDB到cdb_out[46]，进入ROB
的cdb_tag[11]，再捕获ROB状态，故本轮优先缩短仲裁后的tag路由。

CDB新增独立逐lane扫描参考，穷举全部有效位组合×全部合法轮转位置，精确比较lane
顺序、完整payload及ready掩码；矩阵扩展为W1/W2×R1/R2。初次四档全部通过，声明
提示清理后四档69,797项均通过；IQ矩阵1,468,560项通过，无上述假依赖警告。
W1/W2各19/19、run_all ALL PASS、配置及LOCAL_STATS lint通过。两档全部测试/perf周期相同。
一次diagnose、24个hash一致、结构检查0 problems：20,482.585280 µm² / 385.252069 MHz，
最小周期2.59570313 ns，WNS -0.594799 ns。相对第三轮频率-4.2513%、面积-22.439 µm²
（-0.1094%），不保留。完整trial保存在freq-r4-cdb-parallel-trial-20261024及
`build/synth/freq_r4_cdb_parallel/`，恢复第三轮两份RTL及其报告/仿真器，不另跑综合。

同类关键路径累计由0.070/0.528/1.072/1.442/2.425变为0.082/0.584/1.099/1.478/2.539 ns。
CDB段本身约0.370→0.379 ns，前后段也变慢；并行RTL表达未转化为更短的映射路径。
本轮同时含IQ节点表示清理，只将结论归于这个组合，不声称已隔离各单项物理影响。
保留新增CDB穷举参考及四档测试，回退RTL。第三轮原packed节点的Verilator UNOPTFLAT
假依赖警告随精确恢复保留，实际结构无反馈、完整回归通过；不以警告清理换取4.25%频率损失。

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

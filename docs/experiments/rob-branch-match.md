# ROB固定槽分支查找与晚资格限定（2026-10-25）

## 结果与决定

基于007bd09响应直通候选，分支feat/freq-rob-branch-match，默认参数不改，测量仍ROB32/PRF64/IQ8/LSQ16。

| 版本 | W2 IPC | W1 IPC | diagnose面积 µm² | MHz |
| --- | ---: | ---: | ---: | ---: |
| load直通007bd09 | 0.621226 | 0.558328 | 22,865.599 | 368.08 |
| 固定槽分支查找 | 0.621226 | 0.558328 | 22,903.492 | 393.39 |

频率+6.877%，面积+37.893 µm²（+0.166%），IPC和全部正确性/perf周期不变，W2 IPC×Fmax+6.877%。
保留检查点freq-rob-branch-match-20261025；没有面积下降，不将它称作面积优化成功，但频率代价交换明显有利。
首条仍ROB取消→LSU/CDB→分支资格→ROB/rename准入→前端I$，D端2.676→2.501 ns；最小周期2.541992 ns。
一次diagnose约9.92分钟，结构0 problems；时序面积不变，没有新增流水级、容量或执行资源。

## 改动与等价性

原分支查找从head旋转读取valid/control/tag，找到索引后再动态读取预测方向、目标、PC和uncond。
新逻辑固定物理槽并行匹配，复用later_slot年龄关系选择程序序最年轻命中，OR选择预测payload与索引。
预测是否失误先由payload算好，br_update_valid仅在输出flush/更新资格处限定；不把晚资格混入payload选择。
环形年龄由获胜索引减head得到；有命中时保留分支及更老表项。无命中不触发恢复，invalid时payload为无效值。
branch/jal/jalr种类、取非跳转时PC+4、已提交RAT回退及所有完成/恢复语义保留。

## 验证

原RTL在重复control tag接口输入下选择程序序最年轻项，旧参考模型此前取第一个命中。
参考改为有序deque从后向前查找，并独立检查br_update_uncond；新增32个head×3场景：
非跳转误预测PC、跳转目标误预测、正确jalr，以及无效更新、重复tag跨回绕与年轻尾项取消。
这些检查先在原ROB上通过141970/141968，再在新ROB上通过同样完整50,000拍随机测试；未以RTL物理槽优先矩阵构造参考。
四组（ROB32/默认16 × W1/W2）各19/19且19项正确性、6项perf周期逐项相同；普通/统计输入/答案/周期及全部计数器也相同。
默认16 W2/W1 IPC0.553419/0.517579，只作兼容性与IPC，没有当前默认16的PPA，不能复用旧400MHz。

完整模块回归初次在IQ的Verilator构建退出时出现Internal Error: attempted to destroy locked Thread Pool，
第二次在ALU构建退出时同样失败；不是CPU功能断言，失败日志unit-all.log与unit-all-retry.log保留。
原样生成的IQ二进制独立运行227199项零失败；仿真context原本已是单线程，不改其参考/断言。
通过tools/unit/build.py新增CPU_UNIT_JOBS环境覆盖（默认仍4），用CPU_UNIT_JOBS=1从头重跑unit-all-serial.log，最终ALL PASS。
该选项只影响单测Verilator构建任务数，不影响生产RTL、综合参数或功能时序。

## 面积与交叉核验

ROB模块4,802.448→4,848.477 µm²，时序面积不变；其他模块也有映射变化，全核净增37.893。
恢复控制逻辑锥380.421→257.658 µm²；锥共享不可相加，不把某个锥的下降当作全核面积收益。
24输入仅ROB改变，其余23相同；候选工作树/报告/归档/统计hash一致，7库/工具/SDC/ABC/SRAM一致。
Yosys展开及五份仿真器实际容量核验32/64/8/16。归档build/synth/rob_branch_match/含全部输入、宏wrapper、
源报告、新旧面积锥、四组测试/perf、完整随机ROB基线与候选日志、失败/最终单测日志、统计与verification/comparison。
统计等待器首次超时只因完整仿真耗时超过20分钟；延长等待后收集一次有效结果，没有重复综合或改变测试条件。

## 一小时累计（同容量、同diagnose模式）

| 指标 | 小时起点ce32682 | 最终候选 | 变化 |
| --- | ---: | ---: | ---: |
| W2 IPC | 0.607639 | 0.621226 | +2.236% |
| W1 IPC | 0.549105 | 0.558328 | +1.680% |
| 面积 µm² | 22,878.356 | 22,903.492 | +0.110% |
| Fmax MHz | 375.23 | 393.39 | +4.841% |
| W2 IPC×Fmax | — | — | +7.185% |

用户授权一小时自主工作，完成一次被动load分段测量及两轮RTL筛选；最终因工具构建故障补齐收尾回归。
未自动opt/合main/推送；main仍f4a0555，旧默认main报告/仿真器保留。
后续IPC仍以外部数据读等待和load-use为主；面积可继续研究完成pick的D×D年龄矩阵；继续频率须依据当前路径重新定位。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/rob_branch_match \
  YOSYS="$REPO_ROOT/build/synth/rob_branch_match/yosys.py"
APPIMAGE_EXTRACT_AND_RUN=1 CPU_UNIT_JOBS=1 sh test/run_all.sh
```

REPO_ROOT为仓库绝对路径；重跑另设归档保护已测结果。

# 32项窗口的diagnose对照（2026-10-25，三组完成）

## 结果与判断

基于1d142db的功能RTL，沿用4888a28的容量仿真测量，通过宏覆盖完成独立综合。
下表全部PPA为W2 diagnose、2 ns目标、同库和同约束，IPC为官方latency=10、MAX_CYCLES=50000000的六项几何平均。
W1仅为独立兼容性和IPC验证，没有将W2 PPA用作W1 PPA。

| 配置 ROB/PRF/IQ/LSQ | W2 IPC | W1 IPC | diagnose面积 µm² | MHz | W2 IPC×Fmax变化 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 原参数16/48/8/16 | 0.538263 | 0.504223 | 20,571.946 | 400.00 | — |
| 第一组：ROB32+PRF64（32/64/8/16） | 0.607639 | 0.549105 | 23,406.633 | 351.05 | -0.927% |
| 第二组：再加LSQ32（32/64/8/32） | 0.620532 | 0.558531 | 27,459.844 | 356.67 | +2.796% |
| 第三组：再加IQ16（32/64/16/32） | 0.639400 | 0.567505 | 29,817.241 | 347.71 | +3.260% |

当前已测IPC×Fmax最好为第三组：再加IQ16，较400 MHz原参数候选+3.260%，面积+44.941%。
第一组IPC提升被频率损失抵消，暂不采用；扩大窗口的IPC收益不能直接称为整核加速。

第三组相对第二组，IPC再提升3.041%，频率下降2.513%，IPC×Fmax仅再提升约0.452%，面积增加2,357.396 µm²（+8.585%）。
因此暂不把这三组设为默认。下一步优先在最小ROB32+PRF64组重审完成搜索/恢复控制链，
取得结构收益后再组合LSQ32；IQ16的追加成本与净收益仍需审慎比较。本轮不追加这项RTL工作。

这些都是参数对照，原默认配置、main和原候选的采纳决定保持不变；没有运行opt或推送。

## 面积来源（µm²）

| 模块（包含子模块） | 原配置 | 第一组 | 第二组 | 第三组 |
| --- | ---: | ---: | ---: | ---: |
| ROB | 2,705.392 | 5,322.006 | 5,347.098 | 5,342.666 |
| PRF | 2,520.984 | 2,536.628 | 2,536.628 | 2,536.628 |
| IQ | 2,010.101 | 1,747.005 | 1,948.252 | 4,311.379 |
| LSQ | 2,633.367 | 2,622.198 | 5,415.639 | 5,415.639 |
| LSU含LSQ | 4,475.404 | 4,464.236 | 8,312.452 | 8,312.452 |

LSU含LSQ与独立LSQ行存在包含关系，不可相加。SRAM均为1,160.951 µm²，I$参数未改。
扩大ROB、PRF以及LSQ/IQ后的逻辑与时序单元成本均已进入总面积，没有把扩容当作免费资源。

## 关键路径

- 第一组：ROB32+PRF64：u_core/u_rob/_120068_/QN → u_core/u_rob/_120171_/D，D端2.793 ns，完整有效综合约8.18分钟。
- 第二组：再加LSQ32：u_core/u_rob/_120056_/QN → u_core/u_rob/_120147_/D，D端2.744 ns，完整有效综合约8.73分钟。
- 第三组：再加IQ16：u_core/u_rob/_119764_/QN → u_core/u_rob/_119844_/D，D端2.816 ns，完整有效综合约9.35分钟。

第一组精确映射到squash_rob_idx[2]→后端rob_seq查找→LSU squash_seq[27]取消判断→
load_result_valid→CDB tag→ROB完成搜索/恢复busy掩码→recover_busy_mask[37]寄存器。
其中CDB tag到达约1.548 ns，ROB终点2.793 ns；PRF→ALU路径已不再是首条。
第二组仍属于同类ROB取消/恢复链，CDB tag约1.478 ns，recover_busy_mask[25]终点2.744 ns。
第三组同样从squash索引经过LSU/CDB返回ROB，CDB tag约1.597 ns，recover_busy_mask[12]终点2.816 ns。
边界信号、完整source_path和端点均保留在各目录comparison.json与critical_paths.json。

旧的ROB固定槽位匹配试验52d7c72在16项配置上曾把相关路径D端2.425→2.040 ns，
当时被相邻ALU路径限制，整核仅+0.474%而回退。现在32项的同类链成为首条，因此值得后续在32项重新评估；
本轮未移植该RTL，也不把旧16项数据当成32项的预期结果。详见[原试验](rob-completion-match.md)。

## 功能、参数与可比性核验

三组W1均重新通过qsort→hanoi→queens、官方19/19和六项perf；W2复用前置扫描中同宏、同源码且hash相同的
普通版19/19及普通/统计版perf，输入/答案/周期逐项一致，ROB提交数与软件指令数一致。
W1 IPC分别0.549105278548/0.558530845446/0.567504912996，较原W1提升8.901%/10.771%/12.550%；
它们与W2的12.889%/15.284%/18.790%属于不同宽度，不可交叉比较。

最终`sh test/run_all.sh`已ALL PASS，包含新增32项矩阵。
LSU矩阵W1/LSQ8、W2/LSQ16、W1/LSQ32、W2/LSQ32分别63757/63948/64228/64228项零失败；
LSQ查询W1/8、W1/16、W2/16、W1/32、W2/32分别677/1229/1242/2333/2346项零失败。
测试索引位宽由深度推导；覆盖32项高位槽号、最老选择、反压、取消、双lane打包及sent FIFO回绕。
修改仅限测试参考的位宽计算与参数矩阵，生产RTL、默认cpu_config、Makefile、config.mk、scripts/、官方filelist及SRAM不改。

每组configuration.json保存显式宏定义；Yosys执行脚本首行注入verilog_defines，展开后检查ROB/PRF/IQ/LSQ位宽。
24个源码输入及7个库hash、工具版本、SRAM模型、ABC驱动/负载、SDC（忽略时间注释）均与原参数诊断报告一致。
report.json中的源码hash没有包含宏覆盖语义，复现必须同时使用configuration.json、wrapper与with_defines脚本。
脚本与仿真器、输入快照及两档日志均归档；结构检查0 problems，无新增IMPLICIT/UNDRIVEN/LATCH。

## 宏覆盖重试记录

第一组首版wrapper通过CLI的-p注入宏，但实际展开仍ROB16；在容量检查时发现并主动终止，没有report.json。
相关中间产物保留在ipc_rob32_prf64/diagnose_macro_attempt1/，旧wrapper/manifest/driver日志也独立保留。
修正为实际执行的Yosys脚本首行注入宏后，预探针验证ROB32/PRF64，完整展开再次核对正确才继续。
后两组wrapper内置展开检查，位宽不符即退出，不会继续映射。
这次无效尝试不计为完成的diagnose，最终表仅包含通过参数和报告核验的完整有效运行。

## 复现与归档

```sh
python3 tools/perf_stats/prepare_window_ppa.py rob32_prf64
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose \
  SYNTH_OUT=build/synth/ipc_rob32_prf64 \
  YOSYS="$REPO_ROOT/build/synth/ipc_rob32_prf64/yosys.py"
# 同理逐组替换为rob32_lsq32、window32；不要同时运行多项综合。
python3 tools/perf_stats/prepare_window_ppa.py rob32_prf64 --verify
```

REPO_ROOT为仓库绝对路径。prepare会保护已有完整报告，重测需另建归档；W1与perf步骤见tools/perf_stats/README.md。
--verify还要求已有W1结果json/两档测试日志，可按归档validate_ipc_window.py重建。
归档根目录build/synth/ipc_{rob32_prf64,rob32_lsq32,window32}/，每组保留diagnose/、inputs/、sim_w2、w1/、
configuration.json、elaboration-verified.json、comparison.json、两档perf与19项正确性日志及单测记录。
默认build/sim、build/synth/diagnose和build/synth/opt继续属于main，不覆盖。

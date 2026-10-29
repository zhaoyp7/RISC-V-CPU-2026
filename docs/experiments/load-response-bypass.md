# 空结果FIFO的load响应直通（2026-10-25）

## 结果与决定

分支feat/ipc-load-response-bypass，生产基线ce32682（测量工具检查点4db5a62）；宏ROB32/PRF64/IQ8/LSQ16，默认不改。

| 版本 | W2 IPC | W1 IPC | diagnose面积 µm² | MHz |
| --- | ---: | ---: | ---: | ---: |
| 恢复网络ce32682 | 0.607639 | 0.549105 | 22,878.356 | 375.23 |
| 空FIFO响应直通 | 0.621226 | 0.558328 | 22,865.599 | 368.08 |

W2/W1 IPC+2.236%/+1.680%，频率-1.905%，面积-12.758 µm²（-0.056%）。
W2 IPC×Fmax净增0.288%，单位面积吞吐+0.344%；整体收益很小，保留独立检查点ipc-load-response-bypass-20261025，未升级默认。
一次diagnose约11.19分钟，结构0 problems；首条仍ROB取消→LSU/CDB→分支资格→准入→前端I$，D端2.676 ns。
下一轮针对ROB分支查找/资格控制，减少旋转选择并让预测payload在有效资格之前形成；继续按新报告验收。

## 改动

[被动分段测量](load-latency.md)显示六项请求→响应13拍，入结果FIFO后通常再等1拍。
RQ为空且返回项存活时，把格式化内存响应直接呈给CDB；握手成功则不重复入队，否则在本拍捕获到已预留的RQ槽。
RQ非空时旧队首保持优先，新响应入队；丢弃队首也不越过。MD响应仍按序出队，同拍/既有squash均按seq过滤。
只直通正常内存响应，store前递/非法load仍走原结果队列，不增加端口、容量或状态。
LOAD_BYPASS被动计数证明存活内存响应的92.98%～100%实际直通，qsort96.27%、rsort92.98%；这不是缓存命中率。

## 正确性与观测时刻

四组（32/默认16 × W1/W2）各19/19，所有六项perf正确；普通/统计版输入、答案和周期逐项相同。
默认16 W2/W1 IPC0.553419057461/0.517579119721，只作兼容性与IPC，未测本RTL默认16 PPA。
完整run_all-final ALL PASS；LSU四档63803/63994/64274/64274零失败。
新增46项覆盖同拍直通、反压缓存且不重复、旧结果优先、同时取消保留较老项/丢弃年轻项、字节/半字符号与零扩展。

backend测试台原在沿后采集组合CDB，直通在沿前握手后消失，导致初次run_all漏记结果。
采样改为沿前，与PRF/ROB实际接收时刻一致；此测试台分别在候选和原LSU通过W1/W2 586/612项。
依赖消费者仍在producer实际CDB握手后三个沿写回，未放宽数据与延迟断言。
初次失败日志unit-all.log保留；修正后从头重跑unit-all-final.log并ALL PASS，不将失败记录冒充通过。

## W2逐例

| perf | 基线cycles | 候选cycles | IPC变化 |
| --- | ---: | ---: | ---: |
| median | 16741 | 16387 | +2.16% |
| multiply | 23328 | 23229 | +0.43% |
| qsort | 352596 | 343192 | +2.74% |
| rsort | 291845 | 282211 | +3.41% |
| towers | 11491 | 11228 | +2.34% |
| vvadd | 4253 | 4155 | +2.36% |

## 核验与复现

24候选输入仅verilog/lsu.sv改变，其余23相同；报告、工作树、归档、普通/统计构建输入hash一致。
7库hash、工具/SRAM/时序参数/SDC/ABC约束相同，宏展开32/64/8/16与五份仿真器实际容量核验。
LOAD_BYPASS验证kept=direct+buffered、buffered=busy_fifo+busy_cdb及实际写回与响应计数，所有原分区守恒检查通过。
归档build/synth/load_response_bypass/，包括baseline-inputs/inputs、配置和wrapper、四组回归/perf、statistics、
初次/最终unit日志、原版与候选backend观测测试及comparison/verification、复现驱动。
main仍f4a0555；默认报告和仿真器保留，未opt/合main/推送。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/load_response_bypass \
  YOSYS="$REPO_ROOT/build/synth/load_response_bypass/yosys.py"
```

REPO_ROOT为仓库绝对路径，重跑另设目录保护已测报告；独立统计wrapper额外注入LOCAL_RESPONSE_BYPASS_STATS及load_response_stats.sv。

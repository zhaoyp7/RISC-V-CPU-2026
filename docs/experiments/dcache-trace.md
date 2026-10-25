# D-cache固定轨迹评估（2026-10-26）

## 结论

基于ba7f0a3/ROB32/PRF64/IQ8/LSQ16/W2，生产RTL不变。普通与跟踪版六perf输入、答案、周期和原有计数器完全相同。
请求接收、按序响应以及store issue/drain都记录实际时刻；候选数据按实际响应填入，store失效取消旧fill，同拍fill下拍才可命中。
模型每行一字，组内LRU，RAM范围0..0x0fffffff可缓存、MMIO旁路；存活cache hit数据逐笔与真实响应数据比对，全部相同。

| perf | 64B/2way读填充+失效 | 64B/2way整字写分配 | 128B/2way写分配 | 256B/2way写分配 |
| --- | ---: | ---: | ---: | ---: |
| median | 35.74% | 35.74% | 35.74% | 35.74% |
| multiply | 0.00% | 0.00% | 0.00% | 0.00% |
| qsort | 10.85% | 18.98% | 26.44% | 34.71% |
| rsort | 0.07% | 1.01% | 2.41% | 4.87% |
| towers | 0.00% | 55.74% | 82.11% | 96.19% |
| vvadd | 0.00% | 0.00% | 0.00% | 0.00% |

这些是固定基线时序上的命中可用机会，不是实测硬件命中率或IPC，命中后提前执行会改变后续访问和推测路径。
只做读填充、store失效时，rsort/towers几乎没有机会；写分配明显改善towers，但对rsort依然有限，vvadd等流式访问无时间局部性。
首个RTL原型选择64B/2way、每行4B：miss保留现有多笔在途，命中在LSU查询执行侧生成带tag结果，不在无tag按序响应口混入。
后续若做空间预取/多字行，必须另测带宽、填充队列和面积代价，本轮没有把整行瞬时填满当成免费命中。

## 写分配与一致性

store issue先失效，committed store drain若是整字写则用已知完整数据分配缓存行；部分字写只失效。
store与load fill共用一个数据写入端口，store优先，冲突的read fill放弃；不阻塞真实读结果返回。
同周期同地址store issue取消新drain分配，guard防止尚在途的旧响应再次填回；squash丢弃响应不填cache。
模型跟踪完整字地址与无回绕版本号实现待填充失效；RTL拟以每MD槽地址+fill许可实现，避免有限版本号回绕风险。

## 验证和范围

13个独立事件测试覆盖延迟填充、resident失效、旧miss与store竞争、同拍填充不可见、相联冲突、整字/部分字写、
共享填充端口、MMIO、取消以及故意错误数据能被识别。所有模型存活命中的缓存值均与真实返回字一致。
24生产输入hash与基线综合报告完全相同，两个被动构建均不加入官方filelist；没有新综合或新W1/默认16结论。
归档build/dcache_probe_20261026/（第一轮只看地址）、build/dcache_write_allocate_probe_20261026/（增加真实数据与写掩码）。
包括独立trace仿真器、全部输入/答案/周期/计数器捕获、monitor版本、模型输出和verification.json。

```sh
python3 test/cache_trace_test/cache_trace_test.py
python3 tools/perf_stats/analyze_cache_trace.py \
  --results build/dcache_write_allocate_probe_20261026/results \
  --baseline build/synth/rob_branch_match/statistics/results.json \
  --out build/dcache_write_allocate_probe_20261026/cache-models.json
```

本轮只测量，没有把假设命中率换算为IPC，也不在完整核心表添加未测PPA配置。

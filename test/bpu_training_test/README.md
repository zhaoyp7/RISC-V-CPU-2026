# BPU 训练入口与前端响应队列专项

`APPIMAGE_EXTRACT_AND_RUN=1 sh test/bpu_training_test/run.sh`，已接入run_all。
通过frontend外部更新、redirect、refill和decode接口验证一拍训练延迟与预测快照；
矩阵W1/W2，I-cache index=4、PRF64/ROB32/LSQ8固定，不修改默认核配置。

覆盖连续同索引训练、目标/tag替换、方向计数器更新、预测与指令配对、训练/redirect
同拍及reset丢弃pending训练。原BPU独立单测继续验证BPU模块本身的同拍旁路。

响应队列测试使两路refill分别延迟0/9和9/0拍，混合第一条taken、第二条taken和
双条顺序请求；用PC生成不同指令字，检查PC/指令/预测快照对应和响应顺序。
backend_ready=1、rename_ready=0持续128拍，再验证头部稳定并交错恢复供给/消费；
带反压redirect后检查旧响应全部丢弃。矩阵W1/W2共281/284项。

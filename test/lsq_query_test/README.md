# LSQ 查询快照与 store 排空专项

运行 `APPIMAGE_EXTRACT_AND_RUN=1 sh test/lsq_query_test/run.sh`。
通过现有 `tools/unit/build.py` 构建独立LSQ，固定PRF64/ROB32，矩阵为W1/LSQ8、
W1/LSQ16、W2/LSQ16、W1/LSQ32、W2/LSQ32，不修改默认核配置。已接入 `test/run_all.sh`。

查询覆盖最年轻匹配、年龄筛选、未知/partial阻塞、快照反压、消费/flush与捕获
同拍，以及store释放复用后快照稳定。

store排空覆盖提交前不发送、最老seq/同龄低id优先、双提交、反压payload稳定、
多笔在途无重复发送、B响应沿后复用id、sent FIFO回绕与按响应顺序释放新owner。
参考结果来自测试程序给定的年龄、数据和发送顺序，不读取RTL内部信号。

分配专项覆盖load提交/B响应不旁路占用、停顿组跨释放沿重试、双lane原子接收、
重复id拒绝与无效lane忽略、squash后新owner数据和已提交store保留。
矩阵分别为677/1229/1242/2333/2346项检查，分配只根据寄存valid判断空闲。
索引宽度由深度推导；32项覆盖高位id、双lane打包和全部槽位的sent FIFO回绕。

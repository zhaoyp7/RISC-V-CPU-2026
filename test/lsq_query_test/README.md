# LSQ 查询快照与 store 排空专项

运行 `APPIMAGE_EXTRACT_AND_RUN=1 sh test/lsq_query_test/run.sh`。
通过现有 `tools/unit/build.py` 构建独立LSQ，固定PRF64/ROB32，矩阵为W1/LSQ8、
W1/LSQ16、W2/LSQ16，不修改默认核配置。已接入 `test/run_all.sh`。

查询覆盖最年轻匹配、年龄筛选、未知/partial阻塞、快照反压、消费/flush与捕获
同拍，以及store释放复用后快照稳定。

store排空覆盖提交前不发送、最老seq/同龄低id优先、双提交、反压payload稳定、
多笔在途无重复发送、B响应当拍复用id、sent FIFO回绕与按响应顺序释放新owner。
参考结果来自测试程序给定的年龄、数据和发送顺序，不读取RTL内部信号。

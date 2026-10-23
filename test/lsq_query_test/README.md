# LSQ 查询快照专项

运行 `APPIMAGE_EXTRACT_AND_RUN=1 sh test/lsq_query_test/run.sh`。
通过现有 `tools/unit/build.py` 构建独立 LSQ，固定 W1/PRF64/ROB32，分别验证
LSQ8 与 LSQ16，不修改默认核配置。已接入 `test/run_all.sh`。

测试覆盖平衡树最年轻匹配、年轻 store 排除、未知与 partial 阻塞、响应反压、
消费与捕获同拍、flush 与捕获同拍，以及 store 写完成释放并复用后仍保持旧
快照的数据。参考结果来自测试程序给定的年龄和数据，不依赖 RTL 内部信号。

# CDB仲裁回归

运行`APPIMAGE_EXTRACT_AND_RUN=1 sh test/cdb_test/run.sh`，已接入run_all。
矩阵为W1/R1、W2/R2、W1/R2、W2/R1，覆盖3/4个源及1/2条结果总线。

独立参考沿原规则逐lane扫描`(last + lane + k + 1) % N`，跳过已选源。
穷举所有合法轮转位置与全部src_valid位图，比较每条总线的完整valid/tag/value/
exception及精确src_ready掩码。每个位置插入空闲周期，检查空闲不推进轮转。
保留单源、全部排空、公平性及5,000周期随机字段路由检查。

参考不使用实现中的有效源前缀计数，能检测lane顺序变化、重复授权或payload错配。

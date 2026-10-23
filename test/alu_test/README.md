# ALU 算术回归

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/alu_test/run.sh
```

分别编译 `ENABLE_DIV=0/1`，对 RV32I 算术逻辑操作和四种乘法做 C++ 宽整数
参考对拍；`ENABLE_DIV=1` 额外验证 DIV/DIVU/REM/REMU 的原有行为。

覆盖符号边界、零、全一、交错位、单比特/负单比特和 20,000 对固定种子随机
输入。种子为 `0x20261023`，两种配置共 713,728 次检查，首次不匹配即失败。
乘法参考直接计算 64 位有符号/无符号乘积，不复用 RTL 的高位修正公式。

`alu_test_top.sv` 仅供测试，不能加入官方 `verilog/filelist.f`。
本测试已接入 `sh test/run_all.sh`。

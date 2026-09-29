# decoder_test — `decoder.sv` 单元测试

用 Verilator 把 `verilog/decoder.sv` 编成一个 C++ 单元测试，对 RV32IM
译码器做**穷举 + 定向 + 随机 + 真实程序**四层自检。

```
test/decoder_test/
├── run.sh         # 编译并运行（一条命令）
├── decoder_tb.cpp # 测试台（Verilator C++ harness + 独立参考译码器）
├── README.md      # 本文件
└── build/         # 编译产物（已被 .gitignore 忽略）
```

> 这个文件夹**不要**加进 `verilog/filelist.f`；它只用于本地测试，不参与 OJ
> 综合和提交。

---

## 1. 环境要求

- Verilator 5.020（课程 AppImage 内置版本一致）；
- 宿主机 g++（C++17）、GNU Make。

Verilator 解析顺序：`$VERILATOR` > AppImage 环境（`$CPU2026_APPDIR`）> PATH >
自动借仓库根目录的 `cpu2026-tools-x86_64.AppImage` 重入。因此本机不需要预装
Verilator。

## 2. 怎么跑

```sh
sh test/decoder_test/run.sh                    # 完整测试（约 33 万次译码）
sh test/decoder_test/run.sh path/to/program.S  # 只对指定反汇编做交叉验证
sh test/decoder_test/run.sh path/to/dir        # 递归扫描目录下的 program.S
```

输出示例（全过）：

```text
field mismatches:
failing opcodes:
decoder_tb: checked=334224 fails=0
PASS
```

退出码：`0` = 全过；`1` = 有失败；`2` = 环境/参数错误。可以直接挂到 CI。

## 3. 测试假设的接口约定

```systemverilog
module decoder (
  input  logic [31:0] instr,
  output logic [4:0]  rs1, rs2, rd,
  output logic        reg_we,
  output logic [1:0]  wb_sel,
  output logic [4:0]  alu_op,
  output logic [1:0]  a_sel,
  output logic        b_sel,
  output logic [31:0] imm,
  output logic        is_branch, is_jal, is_jalr, is_load, is_store,
  output logic [1:0]  mem_size,
  output logic        mem_unsigned,
  output logic        illegal
);
```

纯组合逻辑，无时钟；`instr` 变化后当拍输出有效。

## 4. 测试分组

| 组 | 数量 | 内容 |
| --- | ---: | --- |
| `exhaustive` | 131,072 | 穷举 `opcode × funct3 × funct7`，覆盖全部合法与非法组合 |
| `immediates` | 40 | 五种立即数格式的边界值（0/1/±最大最小） |
| `random` | 200,000 | 随机 32 位指令 fuzz |
| `program.S` | ~3,100 | 解析 `testcases/*/program.S` 的真实指令交叉验证 |

比较字段：`rs1/rs2/rd/reg_we/wb_sel/alu_op/a_sel/b_sel/imm/is_*/mem_size/`
`mem_unsigned/illegal`，全部逐位核对。

**don't-care 说明**：`illegal=1` 的指令不会执行（core 收到后停机），因此
不比较其 `imm`。例如 RTL 对 SYSTEM（`0x73`）仍按 I 型拼装立即数，参考模型
则不关心这个值。

## 5. 这个测试是怎么写的

1. **独立参考译码器**：在 C++ 里按 RISC-V 规范另写一份 `ref_decode()`，
   立即数用与 RTL 不同的位运算方式构造（`sext` + 字段移位），避免"照抄 RTL
   的错误"；
2. **正向编码器**：`enc_i/enc_s/enc_b/enc_u/enc_j` 从期望字段构造指令，用于
   立即数边界测试；编码器和参考译码器互相独立，构成双向核验；
3. **真实程序交叉验证**：扫描 `program.S`，取每行 `:` 后的 8 位十六进制机器码，
   RTL 与参考模型同时译码比对；
4. **失败分类统计**：输出按字段和 opcode 聚合的失败数，方便定位。

## 6. 当前状态

- 已通过：`checked=334224 fails=0`（全过）；
- 发现并处理的唯一分歧：SYSTEM 的 `imm`（见第 4 节 don't-care）。

## 7. 与 `divider_test` 的关系

目录结构、`run.sh` 用法、README 组织与 `test/divider_test/` 保持一致；后续
模块（`pc_unit`、`bpu` 等）也按同样方式在 `test/<module>_test/` 下新建。

# divider_test — `divider.sv` 单元测试

用 Verilator 把 `verilog/divider.sv` 编成一个 C++ 单元测试，对多周期除法器做
**定向 + 随机**自检，覆盖 RISC-V M 扩展的除法/取余语义和握手协议。

```
test/divider_test/
├── run.sh         # 编译并运行（一条命令）
├── divider_tb.cpp # 测试台（Verilator C++ harness + 参考模型）
├── README.md      # 本文件
└── build/         # 编译产物（已被 .gitignore 忽略）
```

> 这个文件夹**不要**加进 `verilog/filelist.f`；它只用于本地测试，不参与 OJ
> 综合和提交。

---

## 1. 环境要求

- Verilator 5.020（与课程 AppImage 内置版本一致）；
- 宿主机 g++（C++17）、GNU Make；
- 本机已按 `docs/environment.md` 装好本地 Verilator，默认在 `~/.local/bin`。
  新开终端如果提示找不到 verilator：

```sh
export PATH="$HOME/.local/bin:$PATH"
```

其它情况可显式指定：`VERILATOR=/path/to/verilator sh test/divider_test/run.sh`。

## 2. 怎么跑

在仓库根目录（或任意目录）执行：

```sh
sh test/divider_test/run.sh              # 完整：约 100k 组随机 + 定向
sh test/divider_test/run.sh --quick      # 快速：约 5k 组随机（开发时用）
sh test/divider_test/run.sh --no-boundary  # 跳过边界用例（见第 5 节）
```

可用的环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `VERILATOR` | PATH 里的 `verilator` | 指定 Verilator 可执行文件 |
| `DIVIDER_SRC` | `<repo>/verilog/divider.sv` | 换一个被测文件（对拍不同版本） |

例子：

```sh
# 用当前 verilog/divider.sv 跑快速测试
sh test/divider_test/run.sh --quick

# 临时测另一份实现
DIVIDER_SRC=/tmp/divider_old.sv sh test/divider_test/run.sh --quick
```

输出示例（全过）：

```text
checked=100031  fails=0  boundary_fails=0
PASS
```

退出码：`0` = 全过；`1` = 有失败；`2` = 环境/参数错误。可以直接挂到 CI。

## 3. 测试假设的接口约定

```systemverilog
module divider (
  input  logic        clk, reset,       // reset 高有效
  input  logic        start,            // 1 拍脉冲；busy=1 时忽略
  input  logic        is_signed,        // 1=DIV/REM, 0=DIVU/REMU
  input  logic [31:0] a, b,
  output logic        busy,
  output logic        done,             // 1 拍脉冲
  output logic [31:0] quotient, remainder
);
```

时序约定（测试就是按这个检查的，实现必须满足）：

1. `reset` 后 `busy=0, done=0`；
2. `start=1` 的时钟沿被接受，`a/b/is_signed` 在此后到 `done` 之前必须保持稳定；
3. 运算期间 `busy=1`；
4. `done=1` 是**单拍脉冲**，并且 **`done=1` 那一拍 `quotient/remainder` 已经有效**；
5. `done` 后下一拍回到空闲（`done=0`），可以立刻接受下一次 `start`。

```
clk    _/‾\_/‾\_/‾\_/‾\_
start  ‾‾\_____________
busy   __/‾‾‾‾‾‾‾‾‾\___
done   _____________/‾\_
quot   ..........有效值..    (done=1 当拍)
```

## 4. 参考语义（RISC-V M 扩展）

| 情况 | quotient | remainder |
| --- | --- | --- |
| 正常 | 向零截断 | 符号跟**被除数** |
| 除零 | `0xffffffff` | 被除数 |
| `INT_MIN / -1` | `INT_MIN` | `0` |

参考模型用 `int64_t` 计算，避免 C++ 里 `INT_MIN / -1` 的 UB。

## 5. 测试分组

| 组 | 内容 |
| --- | --- |
| `directed` | ±7/±2、4/2、0/x、x/1、`INT_MIN` 系列、`INT_MAX/-1`、除零等 |
| `reset` | 运算中途异步复位，随后再跑一次运算 |
| `random` | 有/无符号随机（默认 100k），1/8 概率偏向边界值 |
| `boundary` | 除零、`INT_MIN/-1`（失败单独计数） |

边界用例：因为你们的计划里 `alu.sv` 会自己兜住除零和 `INT_MIN/-1`，如果
divider 有意不处理它们，用 `--no-boundary` 跳过；默认仍然按完整 RISC-V
语义检查。跳过时输出会带 `(boundary cases skipped)`。

失败信息格式：

```text
FAIL [random] mismatch signed   a=fffffff9 b=00000002 | q=00000003 want=fffffffd | r=00000001 want=ffffffff
```

每组最多打印有限条（directed/random 前 10 条，boundary 前 5 条），最后给
总数，避免刷屏。

## 6. 这个测试是怎么写的

`divider_tb.cpp` 的套路（也适用于以后其它模块）：

1. **Verilator C++ harness**：`--cc --exe` 生成 `Vdivider` 类，测试里直接
   `dut->a = ...; dut->eval();` 读写端口，比写 SV testbench 更灵活，
   参考模型可以直接写在 C++ 里。
2. **时钟**：`tick()` = `clk=0; eval(); clk=1; eval();`。在上升沿之后
   读输出，等价于"下一拍开头"。
3. **发起一次运算**：给出 `a/b/is_signed`，`start=1` 一拍，然后等 `done`
   （带 200 拍超时保护），断言 `done` 只持续一拍。
4. **采样点**：在观察到 `done=1` 的那次 `eval` 之后立刻取
   `quotient/remainder`，所以实现必须保证"done 当拍结果有效"（见第 3 节）。
5. **参考模型**：C++ 函数按第 4 节语义算期望值，和 RTL 输出逐位比较。
6. **随机**：xorshift 生成操作数，1/8 概率从边界值集合
   `{0,1,2,3,0x40000000,0x7fffffff,0x80000000,0xffffffff,-2,-3}` 里抽，
   保证除零、INT_MIN、-1 等都会经常被覆盖。

## 7. 当前状态提示

- 本测试台已经用一个**修正版多周期实现**验证过：`--quick` 下
  `checked=5031, fails=0`，默认 `100k` 同样全过。
- 当前 `verilog/divider.sv` 还**编译不过**（`state <= IDLE` 缺分号、
  `negative_a/negative_b` 未声明等）；只修编译错误后跑测试仍会大量失败
  （`new_quot_u` 未初始化、符号在 DONE 拍用输入而非锁存值、结果比 done
  晚一拍有效等）。具体修复点见代码审查结论。
- `verilog/naive_divider.sv`（纯组合参考版）不要注册进 `filelist.f`，
  也不要拿来直接综合；它的价值是作为参考模型/对照。

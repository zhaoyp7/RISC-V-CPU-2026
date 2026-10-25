# rob_test — `rob.sv` + `commit.sv` 单元测试

用 Verilator 对 ROB 做**分配、乱序完成、按序提交、分支解析、误预测恢复**的
单元测试；`commit.sv` 的窗口选择逻辑由 ROB 测试间接覆盖。

```
test/rob_test/
├── run.sh      # 编译并运行
├── rob_tb.cpp  # 测试台 + 顺序 ROB 参考模型
├── README.md
└── build/      # 编译产物（已忽略）
```

> 测试台不加入正式filelist；`rob.sv`与`commit.sv`已用于正式OoO核心。

## 1. 怎么跑

```sh
sh test/rob_test/run.sh                 # W=1，定向 + 5 万拍随机
sh test/rob_test/run.sh --quick         # W=1，1 万拍随机
ROB_W=2 sh test/rob_test/run.sh         # W=2，额外验证双 lane 提交
ROB_W=2 sh test/rob_test/run.sh --quick
```

`ROB_W` 同时覆盖 `CPU_ISSUE_WIDTH` 与 C++ 的 `TB_W`；切换宽度时 `run.sh`
会清理旧 build 目录。

## 2. 接口与语义

- **分配**：按in_ready和低位连续in_capacity接收有效前缀，接收rename的`in_uop` / `in_old_tag`，按程序序分配`rob_idx`
  （循环缓冲索引），同时保存前端给出的 `pred_taken/pred_target`。
- **完成**：`cdb` 与 `complete[W]` 按 `dest_tag` 定位表项，置 `done`；
  `exception` 一并记录。若接口测试给出多个同tag有效项，保持原实现的规则：
  只更新从head开始扫描的最后一个命中，即程序序最年轻的一项。
- **提交**：`commit.sv` 从头部选择前缀连续的
  `valid && done && (非控制 || br_resolved)` 表项。异常/非法指令可以提交，
  但产生 `commit_halt` 且其后的 lane 不提交。
- **分支**：控制指令必须收到 `br_update` 才允许提交。`br_update` 按 tag
  定位表项；实际方向/目标与保存的预测比较，不一致时：
  - 输出 `redirect_valid/redirect_pc`；
  - 输出 `squash_valid/squash_rob_idx`；
  - 冲刷比该分支年轻的表项；
  - 给 rename 输出 `recover_free_mask/recover_busy_mask/recover_lsq_ptr`。
- **提交反馈**：给 rename 输出 `commit_rd/dest_tag/reg_we` 与释放 tag；
  `reg_we=1` 释放 `old_tag`，`reg_we=0` 释放该 uop 的 `dest_tag`。
- **ROB 内部 commit RAT**：仅用于恢复时计算空闲物理寄存器掩码；架构 RAT
  仍由 rename 维护。

## 3. 时序约定

- `commit_valid` 与提交字段是组合输出，ROB 在时钟沿出队；
- `redirect_valid`、`squash_valid`、`recover_valid` 是时钟沿后的一拍脉冲；
- `in_ready` 在 `recover_valid/redirect_valid` 脉冲期间为 0，避免恢复同拍
  再接收新 uop；
- 分配与提交同拍时，新表项索引按**提交前**的 head/count 计算；ROB 满时
  本拍不接收（保守但正确）。仅剩一槽时容量为01，可接收lane0；不借当拍提交空间。

## 4. 测试分组

| 组 | 内容 |
| --- | --- |
| 非控制指令 | 未完成不提交；完成后提交；旧 tag 释放 |
| store | `is_store/lsq_id` 透传；非架构写释放 dest tag |
| 分支 | done 但未收到 `br_update` 不提交；解析后提交 |
| 误预测 | 冲刷年轻项、redirect/squash 脉冲、恢复掩码/lsq_ptr |
| 随机 | 5 万拍随机分配/完成/分支解析/提交，逐拍对拍组合输出与沿后脉冲 |
| W=2 | 双 lane 分配、前缀提交、双 lane 完成 |
| 完成搜索边界 | 遍历所有head位置；重复tag跨回绕、无效广播、年轻项被squash后的再次匹配 |
| 恢复RAT | 用crat和存活有序队列重放，核对所有32个映射；遍历全部head和分支自身写回/不写回 |
| 恢复掩码边界 | 满窗口、全部head位置、branch年龄0/15/31、非写回完成tag、高位已提交tag63、同拍完成与LSQ指针回绕 |

完成参考在时钟沿前的有序队列中从后向前查找匹配项，保存其槽位；更新后仅修改
仍存活的匹配槽。它不使用RTL中的物理槽位优先矩阵，适合检验搜索结构改写。

恢复RAT参考按程序顺序覆盖架构寄存器映射，不使用物理槽排序或选择树。
定向覆盖非零已提交映射回退、同rd多次写入、reg_we=0、分支自身jalr写回、
年轻同rd写入取消、rd0/rd31和跨32位字的打包字段；每次恢复脉冲均检查全部32项。
新增检查先在原恢复逻辑上通过，再用于固定槽选择树，W1/W2完整随机共115666/115664项。

恢复掩码边界仍使用有序deque参考，核对free/busy、LSQ指针与存活队列；
branch年龄0覆盖无存活访存项，年龄15覆盖LSQ指针回绕，年龄31覆盖全窗口保留。
同拍CDB与complete分别命中较老、branch及年轻项，非写回uop仍占用其完成tag。
该组先在dca7d77原实现上通过，再用于固定槽恢复网络；加入后两档完整随机检查如下。

完整输出示例：

```text
rob_tb: W=1 checked=131698 fails=0
PASS
rob_tb: W=2 checked=131696 fails=0
PASS
```

## 5. 当前状态

- W=1/W=2 随机对拍通过；
- Yosys `proc; opt; check` 0 problems；
- 已纳入正式OoO核心；测试台和其参考模型保持独立。

容量边界覆盖：填到仅剩一槽、只接收所提供前缀、满队列同拍commit不借空间、释放沿后绕回复用。
参考以有序队列剩余容量限定接受条数，逐拍核对容量mask及提交/恢复状态。

# 环境配置记录（environment.md）

> 按 `README-ZH.md`「快速上手」流程配置本机开发环境。
> 主机：WSL2 Ubuntu 24.04（x86-64），Python 3.12.3 / GNU Make 4.3 /
> g++ 13.3.0 / GNU ar 2.42 / git 2.43.0。
> 仓库路径：`/mnt/c/Users/Lenovo/Desktop/大二上/CPU/repo/RISC-V-CPU-2026`。

## 0. 最终状态（一句话）

- **仿真链路**：Verilator 5.020（课程 AppImage 内置）→ `make build / run / test / perf` 可用；
- **综合链路**：Yosys 0.63 + ABC + OpenSTA + ASAP7 7.5T（课程 AppImage 内置）→ `make synth` 可用；
- 全部 19 个 `correctness_*` 通过；`perf` 几何平均 IPC 0.1380（与基线报告一致）；
- 另装了一份**本地 Verilator 5.020** 作为无 AppImage 时的回落（无 sudo）。

| 组件 | 版本 | 位置 | 状态 |
| --- | --- | --- | --- |
| cpu2026-tools-x86_64.AppImage | 37,181,944 B | 仓库根目录 | ✅ 已就位（用户提供） |
| Verilator（AppImage 内置） | 5.020 | AppImage 内部 | ✅ `make build` 默认使用 |
| Yosys / ABC / OpenSTA / ASAP7 | 0.63 / - / - / r28 7.5T | AppImage 内部 | ✅ `make synth` 使用 |
| 本地 Verilator（回落） | 5.020-1（Ubuntu noble） | `~/.local/opt/verilator-kit` | ✅ 可选，`~/.local/bin/verilator` |
| testcases 子模块 | `29f9807` | `testcases/` | ✅ 已拉取（HTTPS） |
| Python / Make / g++ / ar | 3.12.3 / 4.3 / 13.3.0 / 2.42 | 宿主 | ✅ 满足要求 |

---

## 1. 前置检查

依次执行并确认：

```sh
uname -a
python3 --version
make --version
g++ --version
ar --version
git --version
which verilator yosys abc yosys-abc sta docker
sudo -n true
```

结果：

- `uname -a`：`Linux LAPTOP-BR1IA2V1 6.6.87.2-microsoft-standard-WSL2 ... x86_64`；
- Python 3.12.3、GNU Make 4.3、g++ 13.3.0、GNU ar 2.42、git 2.43.0，均满足 README 要求；
- `verilator / yosys / sta / docker` 都不在 PATH 中（初始状态）；
- `sudo` 需要密码，因此**无法用 apt 安装系统级软件包**（本记录中的所有安装均不使用 sudo）。

---

## 2. 初始化测试用例子模块（README 第 1 步）

`.gitmodules` 里的 URL 是 SSH（`git@github.com:...`），本机没有 SSH key，
直接 `git submodule update --init` 会失败。改为 HTTPS 后成功：

```sh
git config submodule.testcases.url https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026-Testcases.git
git submodule sync --recursive
git submodule update --init --recursive
ls testcases | head
git submodule status
```

结果：

- `testcases/` 出现 `correctness_*`、`perf_*` 等目录；
- `git submodule status` 显示 `29f980727f7d99a1842a58f34091c7579ba3fe85 testcases (heads/main)`；
- 该 URL 只写在本地 `.git/config`（`submodule.testcases.url`），**不影响提交内容**。

---

## 3. 准备硬件工具链（README 第 2 步）

README 给了三个方案。最终采用**方案 A（AppImage）**，并额外做了**方案 C 的本地
Verilator 回落**。Docker（方案 B）本机未安装，未使用。

### 3.1 本地 Verilator 回落（无 sudo，选用）

在 AppImage 还没就位时先跑通仿真，用 `apt-get download`（非 root 可执行）取出
Ubuntu 24.04 的 `verilator 5.020-1` 并解包到用户目录：

```sh
mkdir -p /tmp/opencode/verilator
cd /tmp/opencode/verilator
apt-get download verilator
dpkg-deb -x verilator_5.020-1_amd64.deb ~/.local/opt/verilator
```

再按 Verilator 的 `VERILATOR_ROOT` 目录约定拼一个可用的安装前缀：

```sh
mkdir -p ~/.local/opt/verilator-kit/bin
ln -sf ~/.local/opt/verilator/usr/bin/verilator        ~/.local/opt/verilator-kit/bin/verilator
ln -sf ~/.local/opt/verilator/usr/bin/verilator_bin    ~/.local/opt/verilator-kit/bin/verilator_bin
ln -sfn ~/.local/opt/verilator/usr/share/verilator/include ~/.local/opt/verilator-kit/include
for f in ~/.local/opt/verilator/usr/share/verilator/bin/*; do ln -sf "$f" ~/.local/opt/verilator-kit/bin/; done
```

创建 `~/.local/bin/verilator` 包装脚本（`~/.local/bin` 已在 `~/.profile` 的 PATH 中）：

```sh
#!/bin/sh
export VERILATOR_ROOT="$HOME/.local/opt/verilator-kit"
exec "$VERILATOR_ROOT/bin/verilator" "$@"
```

验证：

```sh
export PATH="$HOME/.local/bin:$PATH"
verilator --version
# Verilator 5.020 2024-01-01 rev (Debian 5.020-1)
```

> 说明：这是**回落方案**。之后放入 AppImage 时，`scripts/build.py` 会优先使用
> AppImage 内置 Verilator（见 3.2），本地这份仅在 AppImage 缺失时生效。

### 3.2 课程 AppImage（最终采用）

将 `cpu2026-tools-x86_64.AppImage` 放在**仓库根目录**（`.gitignore` 已忽略
`*.AppImage`），权限已可执行。验证：

```sh
./cpu2026-tools-x86_64.AppImage --version
```

输出（即 README 方案 A 预期内容）：

```text
Yosys 0.63: 70a11c6bf0e8dd669f56c7da3587f78b405138e2
ASAP7 7.5-track r28 RVT TT NLDM: f970bd3c3292b79ae4d022a3ec80533534614066
OpenSTA: f89887b59600cd3a2a10c3de31bda4235d904cdf
CUDD: f54f533303640afd5dbe47a05ebeabb3066f2a25
Verilator 5.020 2024-01-01 rev (Debian 5.020-1)
```

WSL2 内核自带 `/dev/fuse`，AppImage 可直接运行，无需设置
`APPIMAGE_EXTRACT_AND_RUN`。

---

## 4. 发现并修复的问题：非 ASCII 路径导致 `make synth` 崩溃

### 4.1 症状

AppImage 就位后第一次综合：

```sh
make synth MODE=diagnose
```

报错：

```text
ERROR: Unsupported \uXXXX sequence in JSON string: FFFF.
make: *** [Makefile:83: synth] Error 1
```

`build/synth/diagnose/synth.log` 显示 Yosys 在读 `ram/prepared.json` 时失败。

### 4.2 定位

检查 Yosys 生成的 JSON：

```sh
grep -o '\\u[0-9a-fA-F]\{4\}' build/synth/diagnose/elaborated.json | sort | uniq -c
grep -o '.\{80\}\\uFFFF.\{30\}' build/synth/diagnose/elaborated.json | head
```

发现 13,608 处 `\uFFFF`，上下文是仓库路径中的中文（`大二上`）：

```text
"src": "/mnt/c/Users/Lenovo/Desktop/\uFFFFFFE5\uFFFFFFA4\uFFFFFFA7...
```

原因链：

1. Yosys 0.63 的 JSON writer 把非 ASCII 路径字节编码成 `\uFFFFFFxx`
   （8 位十六进制，属于非法 JSON 转义）；
2. 框架 `scripts/fakeram.py` 用 Python `json.loads` 读 `elaborated.json`
   时按 `\uFFFF` + 字面 `"FFE5"` 解析，再用 `json.dumps` 写成 `\uffffFFE5`；
3. Yosys 自己的 JSON reader 拒绝 `\uFFFF` → 报错。

为确认“非 ASCII 路径”是唯一原因，把仓库复制到纯 ASCII 路径重试：

```sh
mkdir -p /tmp/opencode/ascii-check
cp -r Makefile config.mk scripts verilog /tmp/opencode/ascii-check/
cp cpu2026-tools-x86_64.AppImage /tmp/opencode/ascii-check/
cd /tmp/opencode/ascii-check
make synth MODE=diagnose
```

综合成功，结果与 `docs/report-stage1.md` 完全一致（5396.164 µm² / 48.04 MHz）。

### 4.3 修复（保留当前中文路径）

新增 `tools/yosys-wrap.sh`：先调用真正的 Yosys（AppImage 内为
`$CPU2026_APPDIR/bin/yosys`），成功后把它通过脚本里 `write_json` 写出的
JSON 文件中的坏转义 `\uFFFFFFxx` 替换为 `_`（只影响 `src` 路径字符串，
不影响模块名和网表结构）。然后修改 `config.mk`：

```make
# Local workaround: this checkout lives under a non-ASCII path (大二上), which
# Yosys 0.63's JSON writer mangles. Route Yosys through tools/yosys-wrap.sh;
# it is a pass-through everywhere else. Remove this line after moving the repo
# to an ASCII-only path.
YOSYS ?= $(FRAMEWORK_DIR)/tools/yosys-wrap.sh
```

验证修复：

```sh
chmod +x tools/yosys-wrap.sh
make synth MODE=diagnose
```

成功输出（节选）：

```text
Total area:           5,396.164 um^2
  Combinational:      2,521.363 um^2
  Sequential:           638.896 um^2
  SRAM:               2,235.905 um^2
Estimated frequency:  48.04 MHz
Minimum period:       20.8164 ns
```

> 备选方案：把整个仓库移到纯 ASCII 路径（如 `C:\Users\Lenovo\Desktop\cpu-repo\`），
> 然后删掉 `config.mk` 里那行 `YOSYS ?=` 即可。当前方案不需要移动目录。

---

## 5. 验证结果

### 5.1 编译（使用 AppImage Verilator）

```sh
make build JOBS=8
```

stderr 出现 `[build] Using AppImage Verilator`，产物 `build/sim`。

### 5.2 正确性

```sh
make test Case=correctness_add_to_100 MAX_CYCLES=200000000
make test MAX_CYCLES=200000000 SIM="$PWD/build/sim"
```

```text
[correctness_add_to_100]
PASS cycles=2978

Results: 19 passed, 0 failed
```

### 5.3 性能基线

```sh
make perf MAX_CYCLES=200000000 SIM="$PWD/build/sim"
```

```text
benchmark                  instructions       cycles        IPC
perf_median                        6961        55275     0.1259
perf_multiply                     21722        73221     0.2967
perf_qsort                       139900      1048405     0.1334
perf_rsort                       195719      1521960     0.1286
perf_towers                        5278        63202     0.0835
perf_vvadd                         4524        35093     0.1289
GEOMEAN                                                  0.1380
```

### 5.4 综合与时序

```sh
make synth MODE=diagnose     # 逐模块面积，见 4.3
make synth                  # opt 模式（最终面积/频率）
```

产物在 `build/synth/diagnose/`（或 `build/synth/opt/`）：`report.txt`、
`report.json`、`timing.rpt`、`area.json`、`timing.json` 等。

---

## 6. 日常使用

```sh
make build JOBS=8                                  # 编译（自动用 AppImage）
make test MAX_CYCLES=200000000                     # 全量正确性
make test Case=correctness_pi MAX_CYCLES=200000000
make perf MAX_CYCLES=200000000                     # IPC
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 LOG=run.log
make synth MODE=diagnose                           # 面积热点
make synth MODE=opt                                # 最终指标
make                                               # OJ 产物 ./code
```

小技巧：`make test/perf` 会先重新编译。已有 `build/sim` 时可用
`SIM="$PWD/build/sim"` 跳过编译，加快回归：

```sh
make test MAX_CYCLES=200000000 SIM="$PWD/build/sim"
```

---

## 7. 排障与注意事项

1. **`make synth` 报 JSON `\uFFFF` 错**：说明 `config.mk` 里的 `YOSYS` 覆盖被
   去掉了，或仓库被移到/复制到别的非 ASCII 路径。恢复 `YOSYS ?=
   $(FRAMEWORK_DIR)/tools/yosys-wrap.sh`，或把仓库放到纯 ASCII 路径。
2. **不需要 AppImage 的纯仿真环境**：`make build APPIMAGE= ...` 会退回本地
   Verilator（已装在 `~/.local`，版本 5.020，与课程一致）。注意新开的终端需
   让 `~/.profile` 生效（`~/.local/bin` 才会在 PATH 里）。
3. **没有 FUSE 的环境**（部分容器/WSL1）：把 `config.mk` 里被注释的
   `# export APPIMAGE_EXTRACT_AND_RUN = 1` 打开，AppImage 会解包运行。
4. **不要改 `scripts/`、`Makefile`、`config.mk` 的工具路径除外的内容**；
   `tools/yosys-wrap.sh` 是本地补充，不影响 OJ 评测（OJ 只跑 `make code`，
   不经过 Yosys）。
5. **RTL 里不要直接 `$display`**：会污染 OJ 模式 stdout，导致 `make test`
   全部 FAIL；调试用 `make run ... LOG=run.log`，或把打印放在
   `` `ifdef LOCAL_TRACE `` 里。
6. `cpu2026-tools-x86_64.AppImage` 与 `build/` 均被 `.gitignore` 忽略，
   不会误提交；`testcases/` 是 submodule，URL 改动只在本地 `.git/config`。
7. `tools/` 目录（含 `yosys-wrap.sh`）与 `config.mk` 的改动用 `git status`
   可以查看；是否提交由两人自行决定（提交后 甲 在其它机器上也能用，
   包裹脚本在 ASCII 路径下是透明直通）。

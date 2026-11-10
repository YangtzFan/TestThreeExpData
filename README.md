# Multi

一仓多小模块的 [Verilua](https://github.com/cyril0124/verilua) UT 示例：多个独立 DUT 共用同一仓库，避免「一个小模块一个验证仓」。

| 模块 | 路径 | DUT |
| --- | --- | --- |
| fifo | `modules/fifo` | 同步 FIFO（Driver + Checker） |
| counter | `modules/counter` | 计数器（env 内直接驱动） |
| mux | `modules/mux` | 二选一 MUX（env 内直接驱动） |

布局：`common/` 共享代码，`modules/<name>/` 各自是独立 xmake 工程；`TestZhuJiangDocs` 在 Multi 根一份。

## 目录

```text
Multi/
├── common/lua/
├── modules/{fifo,counter,mux}/   # 各自 xmake.lua / main.lua
├── scripts/
│   ├── emmylua_format.py         # CodeFormat wrapper
│   ├── emmylua_ls_check.py       # 单文件/目录 Lua 类型检查
│   └── jobs_gen.lua              # 回归 jobs 目录生成器（xmake 模块）
├── TestZhuJiangDocs/
└── init.sh                       # 拉 Docs submodule
```

## 使用

```bash
cd TestExample
./examples/Multi/init.sh

cd examples/Multi/modules/fifo
SIM=verilator xmake b
SIM=verilator TC=001 xmake r
SIM=verilator TC=002 xmake r
xmake build tp

cd ../counter
SIM=verilator xmake b && SIM=verilator TC=001 xmake r

cd ../mux
SIM=verilator xmake b && SIM=verilator TC=001 xmake r
```

## Lua 格式化与检查

在任一 `modules/<name>/` 工程中，`format` 默认递归格式化该模块的 `src/` 与 `test_points/`，并格式化模块根目录的 `xmake.lua` 和 `main.lua`，底层调用 `Multi/scripts/emmylua_format.py`；wrapper 会在缺失时自动安装官方 CodeFormat，格式化风格取路径上方最近的 `.editorconfig`，没有则用 CodeFormat 默认风格。`lsp-check` 默认检查该模块的 `src/`。两者都接受环境变量 `F` 指定一个 Lua 文件或目录；相对路径以当前模块目录为基准，也支持绝对路径。设置 `F` 时，`format` 只处理 `F` 指定的路径。`lsp-check` 底层调用 `Multi/scripts/emmylua_ls_check.py`。

```bash
xmake r format
F=src/env.lua xmake r format
F=src/test_fifo xmake r format
F=/absolute/path/to/file.lua xmake r format

xmake r lsp-check
F=src/env.lua xmake r lsp-check
F=/absolute/path/to/file.lua xmake r lsp-check

../../scripts/emmylua_format.py src test_points xmake.lua main.lua
../../scripts/emmylua_format.py --check src test_points xmake.lua main.lua
../../scripts/emmylua_ls_check.py src
```

| 变量 | 含义 |
| --- | --- |
| `TC` | 用例前缀 / 名 / `.lua` 路径 |
| `SIM` | `vcs`（默认）/ `verilator` |
| `DUMP` | 非空则导出波形，见下节 |

## 波形（DUMP）

设置 `DUMP=1`（任意非空值即可）时，`main.lua` 会调用 `sim.dump_wave("<TC_NAME>.vcd")` 打开波形。

```bash
DUMP=1 TC=001 xmake r
```

波形文件名与用例名一致（如 `001_basic_push_pop.vcd`），一般落在当前工程的 `build/<仿真器>/<target>/` 目录下（例如 `build/verilator/fifo/`）。

共享：`require "test_example_common"`（`common/lua/`）。

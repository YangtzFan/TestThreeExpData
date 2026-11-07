# fifo

同步 FIFO 模块（`DEPTH=4`，`DATA_WIDTH=8`）。含 Driver + Checker，习惯对齐 `Single`。

组件在 `src/test_example/`（namespace）：`require "test_example.FifoDriver"`，类型注释写 `---@class test_example.FifoDriver`。说明见仓库 [`Single/README.md`](../../../Single/README.md)「为什么要有 namespace」。

```bash
SIM=verilator xmake b
SIM=verilator TC=001 xmake r
SIM=verilator TC=002 xmake r
xmake build tp
```

波形：`DUMP=1 TC=001 xmake r` → `build/<sim>/<target>/<用例名>.vcd`

## 回归目录生成

`jobs-gen` 调用 `examples/Multi/scripts/jobs_gen.lua`，在 `./.regression/` 生成 `jobs.sh`（每行一条仿真）及 `run.sh` / `clean.sh` / `summarize.sh` 等，用于并行回归与失败复现。

日志约定同 [`Single/README`](../../../../Single/README.md)：pass 须打印 `=== test passed ===`（本模块经 `common.test_success()` 输出）。

```bash
JOBS=10 xmake r jobs-gen          # default_target=fifo
TC=001 JOBS=10 xmake r jobs-gen
cd .regression && bash run.sh -j 4
```

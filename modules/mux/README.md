# mux

8-bit 二选一：`out = sel ? b : a`。env 内 `apply(sel,a,b)`。

```bash
SIM=verilator xmake b
SIM=verilator TC=001 xmake r
SIM=verilator TC=002 xmake r
xmake build tp
```

波形：`DUMP=1 TC=001 xmake r` → `build/<sim>/<target>/<用例名>.vcd`

## 回归目录生成

`jobs-gen` 调用 `examples/Multi/scripts/jobs_gen.lua`，在 `./.regression/` 生成 `jobs.sh`（每行一条仿真）及 `run.sh` / `clean.sh` / `summarize.sh` 等，用于并行回归与失败复现。

```bash
JOBS=10 xmake r jobs-gen          # default_target=mux
TC=001 JOBS=10 xmake r jobs-gen
cd .regression && bash run.sh -j 4
```

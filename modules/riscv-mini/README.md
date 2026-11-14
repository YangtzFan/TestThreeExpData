# riscv-mini 验证环境

参照 [TestTemplate](https://github.com/YangtzFan/TestTemplate) / [ChiselTemplate](https://github.com/YangtzFan/ChiselTemplate)，构建分为 `rtl` 和 `sim` 两个目标。子模块使用 Mill 1.0.6、Scala 2.13.18、Chisel 7.9.0。

## 生成 RTL 和编译仿真

```bash
cd modules/riscv-mini
xmake b rtl
SIM=verilator xmake b sim
SIM=verilator TC=001 xmake r sim
```

`rtl` 在子模块中执行：

```bash
mill -i riscvMini.runMain mini.Main \
  --target systemverilog --split-verilog -td build/rtl
```

RTL 先生成到子模块的 `riscv-mini/build/rtl/`，随后完整复制到验证工程的 `build/rtl/`。顶层为 `Tile`。仿真目标沿用模板的 `cfg.*` 配置和 verification 子目录搜索规则，默认使用 Verilator，也可设置 `SIM=vcs` 或 `SIM=iverilog`。每次修改 Chisel 源码后，重新执行 RTL 生成和仿真编译。

子模块也提供独立入口：在 `riscv-mini/` 中执行 `xmake r rtl`。验证工程中 `xmake r clean` 清理生成的 `build/`，`xmake r format` 和 `xmake r lsp-check` 使用主仓库的 Lua 工具脚本。

## 激励

环境通过 `test_zhujiang_utils.AXI4Memory` 响应 Tile 的 NASTI 读写请求，并按小端字节序将 `.hex` 镜像预加载到其 64 位内存中。`DiffMonitor` 在写回阶段按指令推进参考模拟器，只比较提交记录中的 PC、标量/矩阵写回、存储写入及异常/ECALL 信息；执行阶段请求用于对齐存储写入，周期计数用于同步参考模型的 CSR。停顿和流水线气泡不会推进模拟器。默认加载 `programs/rv32ui-p-simple.hex`。`TC` 支持用例前缀、完整名称或 Lua 文件路径。

构建时默认从仓库同级的 `TestZhuJiangUtils/` 加载 AXI4Memory；其他位置可设置 `TEST_ZHUJIANG_UTILS_ROOT`。若比对失败，监视器会报告提交序号、PC 及 DUT/EMU 的不同值并终止测试。

```bash
RISCV_HEX=programs/rv32ui-p-add.hex RISCV_RUN_CYCLES=20000 \
  SIM=verilator TC=001 DUMP=1 xmake r sim
```

`RISCV_HEX` 可指定绝对路径，或相对于验证工程 `modules/riscv-mini/` 的镜像路径；`RISCV_RUN_CYCLES` 控制运行周期，`DUMP=1` 导出波形。仿真至少需要看到一条写回指令，否则会报错。

local AXI4Memory = require "test_zhujiang_utils.AXI4Memory"
local DiffMonitor = require "test_riscv_mini.DiffMonitor"

local env = {}
env.clock = dut.clock:chdl()
env.reset = dut.reset:chdl()
env.host_fromhost_valid = dut.io_host_fromhost_valid:chdl()
env.host_fromhost_bits = dut.io_host_fromhost_bits:chdl()
env.host_tohost = dut.io_host_tohost:chdl()

local axi_hier = "tb_top"
---@type verilua.handles.AliasBundle
local ar = ([[
    | valid
    | ready
    | bits_id => id
    | bits_addr => addr
    | bits_len => len
    | bits_size => size
    | bits_burst => burst
    | bits_cache => cache
    | bits_qos => qos
]]):abdl { hier = axi_hier, prefix = "io_nasti_ar_", name = "MiniAXI_AR" }
---@type verilua.handles.AliasBundle
local r = ([[
    | valid
    | ready
    | bits_id => id
    | bits_data => data
    | bits_resp => resp
    | bits_last => last
]]):abdl { hier = axi_hier, prefix = "io_nasti_r_", name = "MiniAXI_R" }
---@type verilua.handles.AliasBundle
local aw = ([[
    | valid
    | ready
    | bits_id => id
    | bits_addr => addr
    | bits_len => len
    | bits_size => size
    | bits_burst => burst
    | bits_cache => cache
    | bits_qos => qos
]]):abdl { hier = axi_hier, prefix = "io_nasti_aw_", name = "MiniAXI_AW" }
---@type verilua.handles.AliasBundle
local w = ([[
    | valid
    | ready
    | bits_data => data
    | bits_strb => strb
    | bits_last => last
]]):abdl { hier = axi_hier, prefix = "io_nasti_w_", name = "MiniAXI_W" }
---@type verilua.handles.AliasBundle
local b = ([[
    | valid
    | ready
    | bits_id => id
    | bits_resp => resp
]]):abdl { hier = axi_hier, prefix = "io_nasti_b_", name = "MiniAXI_B" }

local dpath_hier = "tb_top.u_Tile.core.dpath"
---@type verilua.handles.AliasBundle
local writeback = ([[
    | ew_reg_inst => inst
    | ew_reg_pc => pc
    | stall
    | _csr_io_expt => exception
    | fe_reg_pc => execute_pc
    | started
    | io_ctrl_inst_kill => fetch_kill
    | _brCond_io_taken => branch_taken
    | ew_reg_matrixResult_0 => matrix_0
    | ew_reg_matrixResult_1 => matrix_1
    | ew_reg_matrixResult_2 => matrix_2
    | ew_reg_matrixResult_3 => matrix_3
    | ew_reg_matrixResult_4 => matrix_4
    | ew_reg_matrixResult_5 => matrix_5
    | ew_reg_matrixResult_6 => matrix_6
    | ew_reg_matrixResult_7 => matrix_7
    | ew_reg_matrixResult_8 => matrix_8
    | ew_reg_matrixResult_9 => matrix_9
]]):abdl { hier = dpath_hier, prefix = "", name = "MiniWriteback" }
---@type verilua.handles.AliasBundle
local regfile = ([[
    | io_wen => wen
    | io_waddr => waddr
    | io_wdata => wdata
    | matrix_valid
]]):abdl { hier = dpath_hier .. ".regFile", prefix = "", name = "MiniRegFile" }
---@type verilua.handles.AliasBundle
local dcache = ([[
    | io_dcache_req_valid => valid
    | io_dcache_req_bits_addr => addr
    | io_dcache_req_bits_data => data
    | io_dcache_req_bits_mask => mask
]]):abdl { hier = dpath_hier, prefix = "", name = "MiniDcacheRequest" }
---@type verilua.handles.AliasBundle
local counters = ([[
    | cycle
    | mcause
]]):abdl { hier = dpath_hier .. ".csr", prefix = "", name = "MiniCSRCounters" }

local image = cfg.hex_image
if not image:find("^/") then
    image = assert(os.getenv("RISCV_ENV_ROOT"), "RISCV_ENV_ROOT is not set") .. "/" .. image
end

---@return test_zhujiang_utils.AXI4Memory
local function init_memory()
    local memory = AXI4Memory("riscv-mini memory", ar, r, aw, w, b, {
        data_width = 64,
        clock_chdl = env.clock,
        cycles_chdl = dut.cycles:chdl(),
        enable_randomize_fields = false,
        enable_ar_delay = true,
        ar_delay_min = 5,
        enable_aw_delay = true,
        aw_delay_min = 5,
        enable_w_delay = true,
        w_delay_min = 5,
        enable_r_delay = true,
        r_delay_min = 5,
        enable_b_delay = true,
        b_delay_min = 5,
        r_burst_continuous_prob = 0,
    })
    local file = assert(io.open(image, "r"), "cannot open hex image: " .. image)
    local address = 0
    for line in file:lines() do
        line = line:gsub("%s+", "")
        if #line > 0 then
            assert(#line % 16 == 0 and line:match("^%x+$"), "invalid hex image line: " .. line)
            -- 每行高地址在左，MemoryCfg 的每个 64-bit 字也以高地址在左。
            for i = #line, 16, -16 do
                assert(address + 8 <= cfg.memory_size, "hex image exceeds RISCV_MEMORY_SIZE")
                memory.mem:write(address, line:sub(i - 15, i), "ff")
                address = address + 8
            end
        end
    end
    file:close()
    return memory
end

env.memory = init_memory()
---@type test_riscv_mini.DiffMonitor
env.diff_monitor = DiffMonitor("riscv-mini", writeback, regfile, dcache, counters, image, { pc = 0x200 })

local function monitor_task()
    local cycles = 0
    local armed = false
    local was_in_reset = false
    while true do
        if env.reset:get() ~= 0 then
            if not was_in_reset then env.diff_monitor:reset_all() end
            was_in_reset = true
            armed = true
        elseif armed then
            was_in_reset = false
            env.diff_monitor:sample_all(cycles)
        end
        env.clock:posedge()
        cycles = cycles + 1
    end
end

local has_monitor_task = false
local function launch_monitor_task()
    if not has_monitor_task then
        scheduler:append_task(nil, "diff_monitor_task", monitor_task, true)
        has_monitor_task = true
    end
end

function env.dut_reset()
    launch_monitor_task()
    env.host_fromhost_valid:set_imm(0)
    env.host_fromhost_bits:set_imm(0)
    env.clock:negedge()
    env.reset:set_imm(1)
    env.clock:posedge(5)
    env.clock:negedge()
    env.reset:set_imm(0)
    env.clock:posedge(2)
end

function env.run_cycles(cycles)
    env.clock:posedge(cycles or cfg.run_cycles)
    assert(env.diff_monitor.checked > 0, "[DiffMonitor] 未观察到任何指令提交")
end

function env.run_until_ecall(max_cycles)
    for _ = 1, max_cycles or 200000 do
        if env.diff_monitor.ecall_cycle then
            return env.diff_monitor.ecall_cycle, env.diff_monitor.checked
        end
        env.clock:posedge()
    end
    error(string.format("[riscv-mini] 未在周期上限内执行到 ECALL，已提交 %d 条指令",
        env.diff_monitor.checked))
end

function env.print_host_state()
    if cfg.verbose_driver then
        print(string.format("[riscv-mini] tohost=0x%08x checked=%d",
            env.host_tohost:get(), env.diff_monitor.checked))
    end
end

return env

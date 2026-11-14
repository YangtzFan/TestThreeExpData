-- Run with: luajit modules/riscv-mini/tests/diff_monitor_test.lua
local src = debug.getinfo(1, "S").source:match("@?(.*/)") .. "../src/"
package.path = src .. "?.lua;" .. src .. "?/?.lua;" .. package.path

local ADDI_X1 = 0x00500093
local SW_X1 = 0x00102023
local NOP = 0x00000013
local ADDI_X7 = 0x00200393
local MAMUL = 0x0000007F
local FENCE = 0x0000000F
local ECALL = 0x00000073

local function signal(value)
    local s = { __type = "CallableHDL", value = value or 0 }
    function s:get() return self.value end
    return s
end

local function bundle(fields)
    fields.__type = "AliasBundle"
    for key, value in pairs(fields) do
        if key ~= "__type" then fields[key] = signal(value) end
    end
    return fields
end

local program = {
    { pc = 0x200, inst = ADDI_X1, reg_wen = true, reg_waddr = 1, reg_wdata = 5 },
    { pc = 0x204, inst = SW_X1, ram_wen = true, ram_waddr = 0, ram_wdata = 5, ram_wmask = 2 },
    { pc = 0x208, inst = NOP },
    { pc = 0x20C, inst = ADDI_X7, reg_wen = true, reg_waddr = 7, reg_wdata = 2 },
    { pc = 0x210, inst = MAMUL, matrix_wen = true, matrix_wdata = { 10, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    { pc = 0x214, inst = FENCE },
    { pc = 0x218, inst = ECALL, trap = true, trap_cause = 11, ecall = true },
}

local function new_model()
    local model = {}
    function model:reset() self.index, self.pc, self.cycles = 1, program[1].pc, 0 end
    function model:advance_cycles(n) self.cycles = self.cycles + n end
    function model:commit_step()
        local entry = program[self.index]
        self.index = self.index + 1
        self.pc = program[self.index] and program[self.index].pc or 0x1C0
        self.cycles = self.cycles + 1
        return {
            commit_index = self.index - 1, pc = entry.pc,
            reg_wen = entry.reg_wen or false, reg_waddr = entry.reg_waddr or 0,
            reg_wdata = entry.reg_wdata or 0, ram_wen = entry.ram_wen or false,
            ram_waddr = entry.ram_waddr or 0, ram_wdata = entry.ram_wdata or 0,
            ram_wmask = entry.ram_wmask or 0, matrix_wen = entry.matrix_wen or false,
            matrix_wdata = entry.matrix_wdata or {}, trap = entry.trap or false,
            trap_cause = entry.trap_cause or 0, ecall = entry.ecall or false,
        }
    end
    return model
end

package.preload["test_riscv_mini.emu"] = function()
    return function(image, options)
        assert(image == "fixture.hex" and options.pc == 0x200)
        return new_model()
    end
end
local DiffMonitor = require "test_riscv_mini.DiffMonitor"

local function fixture()
    local wb = bundle {
        inst = NOP, pc = 0, stall = 0, exception = 0,
        execute_pc = 0,
        started = 1, fetch_kill = 0, branch_taken = 0,
        matrix_0 = 0, matrix_1 = 0, matrix_2 = 0, matrix_3 = 0, matrix_4 = 0,
        matrix_5 = 0, matrix_6 = 0, matrix_7 = 0, matrix_8 = 0, matrix_9 = 0,
    }
    local rf = bundle { wen = 0, waddr = 0, wdata = 0, matrix_valid = 0 }
    local bus = bundle { valid = 0, addr = 0, data = 0, mask = 0 }
    local counters = bundle { cycle = 1, mcause = 0 }
    local monitor = DiffMonitor("test", wb, rf, bus, counters, "fixture.hex", { pc = 0x200 })
    return monitor, wb, rf, bus, counters
end

local function drive(wb, rf, bus, entry, next_entry)
    wb.pc.value, wb.inst.value = entry.pc, entry.inst
    wb.execute_pc.value = next_entry and next_entry.pc or 0
    wb.exception.value = entry.trap and 1 or 0
    rf.wen.value = entry.reg_wen and 1 or (entry.inst == NOP and 1 or 0)
    rf.waddr.value, rf.wdata.value = entry.reg_waddr or 0, entry.reg_wdata or 0
    rf.matrix_valid.value = entry.matrix_wen and 1 or 0
    bus.valid.value = next_entry and next_entry.ram_wen and 1 or 0
    bus.addr.value, bus.data.value = 0, 5
    bus.mask.value = bus.valid.value == 1 and 15 or 0
    if entry.matrix_wen then
        for i = 0, 9 do wb["matrix_" .. i].value = entry.matrix_wdata[i + 1] end
    end
end

local function prime_pipeline(monitor, wb)
    monitor:sample_all(0) -- reset bubble
    wb.execute_pc.value = 0x1FC
    wb.started.value = 0
    monitor:sample_all(1) -- started inserts one more NOP
    wb.pc.value = 0x1FC
    wb.execute_pc.value = 0x200
    monitor:sample_all(2) -- first real instruction is in FE, not yet WB
end

local monitor, wb, rf, bus, counters = fixture()
prime_pipeline(monitor, wb)
assert(monitor.checked == 0)
for i, entry in ipairs(program) do
    drive(wb, rf, bus, entry, program[i + 1])
    monitor:sample_all(i + 2)
end
assert(monitor.checked == #program)
assert(#monitor.store_requests == 0)
assert(monitor.model.cycles == #program + 4)
wb.exception.value = 0
counters.mcause.value = 11
monitor:sample_all(#program + 3) -- stale EW after trap is not a second commit
assert(monitor.checked == #program)
monitor:reset_all()
assert(monitor.checked == 0 and monitor.model.pc == 0x200)

monitor, wb, rf, bus = fixture()
prime_pipeline(monitor, wb)
drive(wb, rf, bus, program[1], program[2])
rf.wdata.value = 6
local ok, err = pcall(function() monitor:sample_all(3) end)
assert(not ok and err:find("register data", 1, true))

monitor, wb, rf, bus = fixture()
prime_pipeline(monitor, wb)
drive(wb, rf, bus, program[1], program[2])
bus.mask.value = 7
monitor:sample_all(3)
drive(wb, rf, bus, program[2], program[3])
ok, err = pcall(function() monitor:sample_all(4) end)
assert(not ok and err:find("store mask", 1, true))

monitor, wb, rf, bus = fixture()
prime_pipeline(monitor, wb)
drive(wb, rf, bus, program[1], program[2])
wb.execute_pc.value = program[1].pc -- 无存储提交却出现同一 PC 的存储请求
ok, err = pcall(function() monitor:sample_all(3) end)
assert(not ok and err:find("store write enable", 1, true))

monitor, wb, rf, bus = fixture()
prime_pipeline(monitor, wb)
drive(wb, rf, bus, program[1], program[2])
wb.inst.value = FENCE -- 普通指令编码不在提交记录中，不单独比对
monitor:sample_all(3)
assert(monitor.checked == 1)

monitor, wb, rf, bus = fixture()
prime_pipeline(monitor, wb)
for i, entry in ipairs(program) do
    drive(wb, rf, bus, entry, program[i + 1])
    if entry.ecall then wb.inst.value = FENCE end
    ok, err = pcall(function() monitor:sample_all(i + 2) end)
    if entry.ecall then
        assert(not ok and err:find("ecall", 1, true))
    else
        assert(ok, err)
    end
end
print("DiffMonitor unit checks passed")

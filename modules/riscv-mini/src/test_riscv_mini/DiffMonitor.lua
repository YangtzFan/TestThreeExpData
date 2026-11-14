local class = require "pl.class"
local texpect = require "verilua.TypeExpect"
local bit = require "bit"
local Emu = require "test_riscv_mini.emu"

local band, bor, lshift, tobit = bit.band, bit.bor, bit.lshift, bit.tobit
local f = string.format

local function u32(value)
    return value < 0 and value + 0x100000000 or value
end

local function check_equal(label, actual, expected, pc, index)
    assert(actual == expected, f("[DiffMonitor] #%d PC=0x%08X %s: DUT=0x%08X EMU=0x%08X",
        index, pc, label, u32(actual), u32(expected)))
end

---@class (exact) test_riscv_mini.DiffMonitor
---@overload fun(name: string, writeback: verilua.handles.AliasBundle, regfile: verilua.handles.AliasBundle, dcache: verilua.handles.AliasBundle, counters: verilua.handles.AliasBundle, image: string, options?: table): test_riscv_mini.DiffMonitor
---@field writeback verilua.handles.AliasBundle
---@field regfile verilua.handles.AliasBundle
---@field dcache verilua.handles.AliasBundle
---@field counters verilua.handles.AliasBundle
---@field model test_riscv_mini.emu
---@field cycles integer
---@field checked integer
---@field ecall_cycle integer?
---@field private _log_name_prefix string
---@field private store_requests table[]
---@field private cycle_offset integer?
---@field private model_cycle integer
---@field private fe_valid boolean?
---@field private ew_valid boolean
---@field private pending_trap test_riscv_mini.commit_entry?
local DiffMonitor = class() --[[@as test_riscv_mini.DiffMonitor]]

function DiffMonitor:_init(name, writeback, regfile, dcache, counters, image, options)
    self._log_name_prefix = "[" .. name .. "_DiffMonitor]"
    self.cycles = 0
    self.writeback = writeback
    self.regfile = regfile
    self.dcache = dcache
    self.counters = counters
    self.model = Emu(image, options)
    texpect.expect_abdl(writeback, "writeback", {
        "inst", "pc", "stall", "exception",
        "execute_pc", "started", "fetch_kill", "branch_taken",
        "matrix_0", "matrix_1", "matrix_2",
        "matrix_3", "matrix_4", "matrix_5", "matrix_6", "matrix_7",
        "matrix_8", "matrix_9",
    })
    texpect.expect_abdl(regfile, "regfile", { "wen", "waddr", "wdata", "matrix_valid" })
    texpect.expect_abdl(dcache, "dcache", { "valid", "addr", "data", "mask" })
    texpect.expect_abdl(counters, "counters", { "cycle", "mcause" })
    self:reset_all()
end

function DiffMonitor:_log(...)
    print(f("[%d]\t%s", self.cycles, self._log_name_prefix), ...)
end

function DiffMonitor:reset_all()
    self.store_requests = {}
    self.cycle_offset = nil
    self.model_cycle = 0
    self.fe_valid = nil
    self.ew_valid = false
    self.pending_trap = nil
    self.checked = 0
    self.ecall_cycle = nil
    self.model:reset()
end

-- Execute-stage store requests precede their writeback by one pipeline register.
function DiffMonitor:sample_store_request()
    local bus = self.dcache
    if not self.fe_valid or bus.valid:get() == 0 or bus.mask:get() == 0 or
        self.writeback.exception:get() ~= 0 then return end
    self.store_requests[#self.store_requests + 1] = {
        pc = u32(tobit(self.writeback.execute_pc:get())),
        addr = u32(tobit(bus.addr:get())),
        data = tobit(bus.data:get()),
        mask = bus.mask:get(),
    }
end

function DiffMonitor:check_store(reference)
    local request = self.store_requests[1]
    if request and request.pc == reference.pc then
        table.remove(self.store_requests, 1)
    else
        request = nil
    end
    -- 陷入的 store 可能已发出请求，但不会提交内存写入。
    if reference.trap then return end
    check_equal("store write enable", request and 1 or 0, reference.ram_wen and 1 or 0,
        reference.pc, reference.commit_index)
    if not reference.ram_wen then return end
    local offset = band(reference.ram_waddr, 3)
    local width = lshift(1, reference.ram_wmask)
    local expected_mask = lshift(lshift(1, width) - 1, offset)
    local expected_data = lshift(reference.ram_wdata, 8 * offset)
    local byte_mask = 0
    for lane = 0, 3 do
        if band(expected_mask, lshift(1, lane)) ~= 0 then
            byte_mask = bor(byte_mask, lshift(0xFF, lane * 8))
        end
    end
    check_equal("store address", request.addr, band(reference.ram_waddr, 0xFFFFFFFC),
        reference.pc, reference.commit_index)
    check_equal("store mask", request.mask, expected_mask, reference.pc, reference.commit_index)
    check_equal("store data", u32(band(request.data, byte_mask)), u32(band(expected_data, byte_mask)),
        reference.pc, reference.commit_index)
end

function DiffMonitor:check_commit(reference)
    local pc, index = reference.pc, reference.commit_index
    check_equal("PC", u32(tobit(self.writeback.pc:get())), pc, pc, index)
    local actual_wen = self.regfile.wen:get() ~= 0 and self.regfile.waddr:get() ~= 0
    local expected_wen = reference.reg_wen and reference.reg_waddr ~= 0
    check_equal("scalar write enable", actual_wen and 1 or 0, expected_wen and 1 or 0, pc, index)
    if expected_wen then
        check_equal("register address", self.regfile.waddr:get(), reference.reg_waddr, pc, index)
        check_equal("register data", u32(tobit(self.regfile.wdata:get())),
            u32(reference.reg_wdata), pc, index)
    end
    local matrix_wen = self.regfile.matrix_valid:get() ~= 0
    check_equal("matrix write enable", matrix_wen and 1 or 0, reference.matrix_wen and 1 or 0, pc, index)
    if matrix_wen then
        for i = 0, 9 do
            check_equal(f("matrix x%d", i + 22), u32(tobit(self.writeback["matrix_" .. i]:get())),
                u32(reference.matrix_wdata[i + 1]), pc, index)
        end
    end
    check_equal("exception", self.writeback.exception:get() ~= 0 and 1 or 0,
        reference.trap and 1 or 0, pc, index)
    check_equal("ecall", u32(tobit(self.writeback.inst:get())) == 0x00000073 and 1 or 0,
        reference.ecall and 1 or 0, pc, index)
    self:check_store(reference)
end

-- Sample just before the active edge; only a retiring instruction steps the model.
function DiffMonitor:sample_all(cycles)
    self.cycles = cycles
    if self.pending_trap then
        local trap = self.pending_trap
        check_equal("trap cause", u32(tobit(self.counters.mcause:get())), trap.trap_cause,
            trap.pc, trap.commit_index)
        self.pending_trap = nil
    end
    if self.writeback.stall:get() ~= 0 then return end
    if self.cycle_offset == nil then
        local initial = self.counters.cycle:get()
        self.cycle_offset = initial - cycles
        if initial > 0 then self.model:advance_cycles(initial) end
        self.model_cycle = initial
    end
    local extra = cycles + self.cycle_offset - self.model_cycle
    if extra > 0 then
        self.model:advance_cycles(extra)
        self.model_cycle = self.model_cycle + extra
    end
    if self.fe_valid == nil then
        -- 监视任务在复位释放后的第一个上升沿才被调度，以 FE PC 对齐首条指令。
        self.fe_valid = u32(tobit(self.writeback.execute_pc:get())) == self.model.pc
    end
    local retiring = self.ew_valid
    local exception = self.writeback.exception:get() ~= 0
    self:sample_store_request()
    self.ew_valid = self.fe_valid and not exception
    self.fe_valid = self.writeback.started:get() == 0 and
        self.writeback.fetch_kill:get() == 0 and
        self.writeback.branch_taken:get() == 0 and not exception
    if not retiring then return end
    local reference = self.model:commit_step()
    self.model_cycle = self.model_cycle + 1 -- execute advances cycle/time once
    self:_log(f("[WRITEBACK]\t#%d\tPC: 0x%08X\tInst: 0x%08X",
        reference.commit_index, u32(tobit(self.writeback.pc:get())), u32(tobit(self.writeback.inst:get()))))
    self:check_commit(reference)
    if reference.ecall then self.ecall_cycle = self.counters.cycle:get() end
    if reference.trap then self.pending_trap = reference end
    self.checked = self.checked + 1
end

return DiffMonitor

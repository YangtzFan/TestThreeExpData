local common = require "test_example_common"

local clock = dut.clock:chdl()
local reset = dut.reset:chdl()
local sel = dut.sel:chdl()
local a = dut.a:chdl()
local b = dut.b:chdl()
local out = dut.out:chdl()

local env = {}
env.clock = clock
env.sel = sel
env.a = a
env.b = b
env.out = out

---@param reset_cycles integer | nil
function env.dut_reset(reset_cycles)
    sel:set_imm(0)
    a:set_imm(0)
    b:set_imm(0)
    reset:set(1)
    clock:posedge(reset_cycles or 5)
    reset:set(0)
    clock:posedge(1)
end

function env.initialize_all()
    sel:set_imm(0)
    a:set_imm(0)
    b:set_imm(0)
end

---@param sel_v integer
---@param a_v   integer
---@param b_v   integer
---@return integer
function env.apply(sel_v, a_v, b_v)
    sel:set_imm(sel_v)
    a:set_imm(a_v)
    b:set_imm(b_v)
    clock:posedge()
    return out:get()
end

function env.test_success()
    common.test_success()
end

---@param reason string | nil
function env.test_skipped(reason)
    common.test_skipped(reason)
end

return env

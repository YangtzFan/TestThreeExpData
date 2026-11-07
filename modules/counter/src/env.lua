local common = require "test_example_common"

local clock = dut.clock:chdl()
local reset = dut.reset:chdl()
local incr = dut.incr:chdl()
local value = dut.value:chdl()

local env = {}
env.clock = clock
env.reset = reset
env.incr = incr
env.value = value

---@param reset_cycles integer | nil
function env.dut_reset(reset_cycles)
    incr:set_imm(0)
    reset:set(1)
    clock:posedge(reset_cycles or 10)
    reset:set(0)
    clock:posedge(2)
end

function env.initialize_all()
    incr:set_imm(0)
end

---@param n integer
function env.step_incr(n)
    n = n or 1
    incr:set_imm(1)
    clock:posedge(n)
    incr:set_imm(0)
end

function env.test_success()
    common.test_success()
end

---@param reason string | nil
function env.test_skipped(reason)
    common.test_skipped(reason)
end

return env

local FifoDriver = require "test_fifo.FifoDriver"
local FifoChecker = require "test_fifo.FifoChecker"
local common = require "test_example_common"

local clock = dut.clock:chdl()
local reset = dut.reset:chdl()

local checker = FifoChecker.new({
    verbose = cfg.verbose_checker
})

local driver = FifoDriver.new({
    clock = clock,
    wr_valid = dut.wr_valid:chdl(),
    wr_ready = dut.wr_ready:chdl(),
    wr_data = dut.wr_data:chdl(),
    rd_valid = dut.rd_valid:chdl(),
    rd_ready = dut.rd_ready:chdl(),
    rd_data = dut.rd_data:chdl(),
    checker = checker,
    timeout = cfg.driver_timeout,
    verbose = cfg.verbose_driver
})

local env = {}
env.driver = driver
env.checker = checker
env.clock = clock
env.reset = reset

---@param reset_cycles integer | nil
function env.dut_reset(reset_cycles)
    reset:set(1)
    clock:posedge(reset_cycles or 10)
    reset:set(0)
    clock:posedge(2)
end

function env.initialize_all()
    driver:idle()
    checker:reset()
end

function env.test_success()
    checker:expect_empty()
    common.test_success()
end

---@param reason string | nil
function env.test_skipped(reason)
    common.test_skipped(reason)
end

return env

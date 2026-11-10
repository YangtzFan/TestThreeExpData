local string_format = string.format

---@class test_example.FifoDriver
---@field clock    verilua.handles.CallableHDL
---@field wr_valid verilua.handles.CallableHDL
---@field wr_ready verilua.handles.CallableHDL
---@field wr_data  verilua.handles.CallableHDL
---@field rd_valid verilua.handles.CallableHDL
---@field rd_ready verilua.handles.CallableHDL
---@field rd_data  verilua.handles.CallableHDL
---@field checker  test_example.FifoChecker
---@field timeout  integer
---@field verbose  boolean
local FifoDriver = {}
FifoDriver.__index = FifoDriver

---@param opts {
---  clock: verilua.handles.CallableHDL,
---  wr_valid: verilua.handles.CallableHDL,
---  wr_ready: verilua.handles.CallableHDL,
---  wr_data: verilua.handles.CallableHDL,
---  rd_valid: verilua.handles.CallableHDL,
---  rd_ready: verilua.handles.CallableHDL,
---  rd_data: verilua.handles.CallableHDL,
---  checker: test_example.FifoChecker,
---  timeout?: integer,
---  verbose?: boolean,
--- }
---@return test_example.FifoDriver
function FifoDriver.new(opts)
    local self = setmetatable({}, FifoDriver)
    self.clock = opts.clock
    self.wr_valid = opts.wr_valid
    self.wr_ready = opts.wr_ready
    self.wr_data = opts.wr_data
    self.rd_valid = opts.rd_valid
    self.rd_ready = opts.rd_ready
    self.rd_data = opts.rd_data
    self.checker = opts.checker
    self.timeout = opts.timeout or 1000
    self.verbose = opts.verbose == true
    return self
end

function FifoDriver:idle()
    self.wr_valid:set_imm(0)
    self.wr_data:set_imm(0)
    self.rd_ready:set_imm(0)
end

---@param data integer
function FifoDriver:push(data)
    local ok = self.clock:posedge_until(self.timeout, function()
        return self.wr_ready:is(1)
    end)
    assert(ok, string_format("FifoDriver:push timeout waiting wr_ready, data=0x%02x", data))

    -- set_imm so valid/data are visible on the next sampled posedge.
    self.wr_data:set_imm(data)
    self.wr_valid:set_imm(1)
    if self.verbose then
        print(string_format("[FifoDriver] push data=0x%02x", data))
    end
    self.clock:posedge()
    self.wr_valid:set_imm(0)
    self.checker:on_push(data)
end

---@return integer
function FifoDriver:pop()
    local ok = self.clock:posedge_until(self.timeout, function()
        return self.rd_valid:is(1)
    end)
    assert(ok, "FifoDriver:pop timeout waiting rd_valid")

    local data = self.rd_data:get() --[[@as integer]]
    self.rd_ready:set_imm(1)
    if self.verbose then
        print(string_format("[FifoDriver] pop data=0x%02x", data))
    end
    self.clock:posedge()
    self.rd_ready:set_imm(0)
    self.checker:on_pop(data)
    return data
end

---@return boolean
function FifoDriver:is_full()
    return self.wr_ready:is(0)
end

---@return boolean
function FifoDriver:is_empty()
    return self.rd_valid:is(0)
end

---@param cycles integer | nil
function FifoDriver:wait_cycles(cycles)
    self.clock:posedge(cycles or 1)
end

return FifoDriver

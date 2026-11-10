local insert = table.insert
local remove = table.remove
local string_format = string.format

---@class test_fifo.FifoChecker
---@field expected integer[]
---@field verbose  boolean
local FifoChecker = {}
FifoChecker.__index = FifoChecker

---@param opts { verbose?: boolean } | nil
---@return test_fifo.FifoChecker
function FifoChecker.new(opts)
    opts = opts or {}
    local self = setmetatable({}, FifoChecker)
    self.expected = {}
    self.verbose = opts.verbose == true
    return self
end

function FifoChecker:reset()
    self.expected = {}
end

---@param data integer
function FifoChecker:on_push(data)
    insert(self.expected, data)
    if self.verbose then
        print(string_format("[FifoChecker] expect push data=0x%02x (q=%d)", data, #self.expected))
    end
end

---@param data integer
function FifoChecker:on_pop(data)
    assert(#self.expected > 0, "FifoChecker: pop while expected queue is empty")
    local exp = remove(self.expected, 1)
    if self.verbose then
        print(string_format("[FifoChecker] check pop data=0x%02x exp=0x%02x (q=%d)", data, exp, #self.expected))
    end
    assert(data == exp, string_format("FifoChecker data mismatch: got=0x%02x exp=0x%02x", data, exp))
end

function FifoChecker:expect_empty()
    assert(#self.expected == 0, string_format("FifoChecker: expected empty, leftover=%d", #self.expected))
end

---@return integer
function FifoChecker:pending()
    return #self.expected
end

return FifoChecker

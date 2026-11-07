local env = require "env"

local function test()
    local o = env.apply(0, 0x12, 0x34)
    assert(o == 0x12, string.format("sel=0 expect a, got 0x%02x", o))
end

return test

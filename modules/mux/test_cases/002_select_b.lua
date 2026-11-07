local env = require "env"

return function()
    local o = env.apply(1, 0x12, 0x34)
    assert(o == 0x34, string.format("sel=1 expect b, got 0x%02x", o))
end

local env = require "env"

local function test()
    env.value:expect(0)

    env.step_incr(1)
    env.value:expect(1)

    env.step_incr(3)
    env.value:expect(4)

    env.clock:posedge(2)
end

return test

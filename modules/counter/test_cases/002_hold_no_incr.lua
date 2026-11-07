local env = require "env"

return function()
    env.step_incr(5)
    env.value:expect(5)

    -- Hold: incr stays 0.
    env.incr:set_imm(0)
    env.clock:posedge(10)
    env.value:expect(5)
end

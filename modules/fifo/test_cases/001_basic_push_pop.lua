local env = require "env"
local driver = env.driver

local function test()
    driver:push(0x11)
    driver:push(0x22)
    driver:push(0x33)

    assert(driver:pop() == 0x11)
    assert(driver:pop() == 0x22)
    assert(driver:pop() == 0x33)

    driver:wait_cycles(2)
end

return test

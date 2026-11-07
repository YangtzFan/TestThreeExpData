local env = require "env"
local driver = env.driver
local depth = cfg.fifo_depth

return function()
    for i = 1, depth do
        driver:push(i)
    end
    assert(driver:is_full(), "FIFO should be full after DEPTH pushes")

    for i = 1, depth do
        assert(driver:pop() == i)
    end
    assert(driver:is_empty(), "FIFO should be empty after DEPTH pops")

    driver:wait_cycles(2)
end

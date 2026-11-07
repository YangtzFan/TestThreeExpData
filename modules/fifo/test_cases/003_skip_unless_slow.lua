-- Demo skip marker for jobs_gen summarize.
-- Default: return "skipped" → main.lua prints === test skipped ===
-- Force run: RUN_SLOW=1 TC=003 xmake r
local env = require "env"
local driver = env.driver

return function()
    if os.getenv("RUN_SLOW") ~= "1" then
        print("[003] optional slow case; set RUN_SLOW=1 to execute")
        return "skipped"
    end

    for i = 1, cfg.fifo_depth do
        driver:push(i)
    end
    for i = 1, cfg.fifo_depth do
        assert(driver:pop() == i)
    end
    driver:wait_cycles(2)
end

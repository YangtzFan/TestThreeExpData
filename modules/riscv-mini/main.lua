local tc_name = assert(os.getenv("TC_NAME"), "TC_NAME is empty; run with TC=001 xmake r")
local tc_path = os.getenv("TC_PATH")

fork {
    main_task = function()
        if os.getenv("DUMP") then
            sim.dump_wave(tc_name .. ".vcd")
        end

        local env = require "env"
        env.memory:initialize()
        env.dut_reset()

        local tc = tc_path and dofile(tc_path) or require(tc_name)
        assert(type(tc) == "function", "testcase must return a function")
        print(string.rep("=", 50))
        print("TestCase: ", tc_name)
        print(string.rep("=", 50))
        tc(env)
        sim.finish()
    end
}

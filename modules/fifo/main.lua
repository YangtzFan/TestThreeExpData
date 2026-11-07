local tc_name = assert(os.getenv("TC_NAME"), "TC_NAME is empty; run with TC=001 xmake r")
local tc_path = os.getenv("TC_PATH") -- optional absolute path from TC=/path/to/xxx.lua

fork {
    main_task = function()
        if os.getenv("DUMP") then
            sim.dump_wave(tc_name .. ".vcd")
        end

        local env = require "env"
        env.dut_reset()
        env.initialize_all()

        local tc
        if tc_path then
            tc = dofile(tc_path)
        else
            tc = require(tc_name)
        end
        assert(
            type(tc) == "function",
            string.format(
                "testcase must return a function, got %s (TC_NAME=%s%s)",
                type(tc),
                tostring(tc_name),
                tc_path and (", TC_PATH=" .. tostring(tc_path)) or ""
            )
        )

        print(string.rep("=", 50))
        print("TestCase: ", tc_name)
        print(string.rep("=", 50))

        local status = tc()
        if status == "skipped" then
            env.test_skipped()
        else
            env.test_success()
        end
        sim.finish()
    end
}

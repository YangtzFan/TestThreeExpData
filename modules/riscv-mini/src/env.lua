local RiscvMemory = require "test_riscv_mini.RiscvMemory"

local env = {}
env.clock = dut.clock:chdl()
env.reset = dut.reset:chdl()
env.host_fromhost_valid = dut.io_host_fromhost_valid:chdl()
env.host_fromhost_bits = dut.io_host_fromhost_bits:chdl()
env.host_tohost = dut.io_host_tohost:chdl()

---@return test_riscv_mini.RiscvMemory
function env.start_memory()
    local image = cfg.hex_image
    if not image:find("^/") then
        image = assert(os.getenv("RISCV_ENV_ROOT"), "RISCV_ENV_ROOT is not set") .. "/" .. image
    end
    local memory = RiscvMemory.new(image, cfg.memory_size)
    fork {
        memory_task = function()
            memory:run()
        end
    }
    env.memory = memory
    return memory
end

function env.dut_reset()
    env.host_fromhost_valid:set_imm(0)
    env.host_fromhost_bits:set_imm(0)
    env.clock:negedge()
    env.reset:set_imm(1)
    env.clock:posedge(5)
    env.clock:negedge()
    env.reset:set_imm(0)
    env.clock:posedge(2)
end

function env.run_cycles(cycles)
    env.clock:posedge(cycles or cfg.run_cycles)
end

function env.print_host_state()
    if cfg.verbose_driver then
        print(string.format("[riscv-mini] tohost=0x%08x", env.host_tohost:get()))
    end
end

return env

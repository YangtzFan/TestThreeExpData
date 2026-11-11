local utils = require "verilua.LuaUtils"
local get_env_or_else = utils.get_env_or_else

local cfg = {}
cfg.memory_size = get_env_or_else("RISCV_MEMORY_SIZE", "number", 16 * 1024 * 1024)
cfg.run_cycles = get_env_or_else("RISCV_RUN_CYCLES", "number", 10000)
cfg.hex_image = get_env_or_else("RISCV_HEX", "string", "programs/rv32ui-p-simple.hex")
cfg.verbose_driver = get_env_or_else("VERBOSE_DRIVER", "boolean", true)
return cfg

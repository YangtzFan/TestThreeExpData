local utils = require "verilua.LuaUtils"
local get_env_or_else = utils.get_env_or_else

local cfg = {}

-- FIFO geometry (must match rtl/simple_fifo.sv)
cfg.fifo_depth = 4
cfg.fifo_data_width = 8

-- Driver / checker knobs
cfg.driver_timeout = get_env_or_else("DRIVER_TIMEOUT", "number", 1000)
cfg.verbose_driver = get_env_or_else("VERBOSE_DRIVER", "boolean", true)
cfg.verbose_checker = get_env_or_else("VERBOSE_CHECKER", "boolean", true)

-- Random test defaults
cfg.random_ops_min = get_env_or_else("RANDOM_OPS_MIN", "number", 20)
cfg.random_ops_range = get_env_or_else("RANDOM_OPS_RANGE", "number", 20)

return cfg

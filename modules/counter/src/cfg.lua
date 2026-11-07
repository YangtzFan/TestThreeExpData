local utils = require "verilua.LuaUtils"
local get_env_or_else = utils.get_env_or_else

local cfg = {}
cfg.verbose = get_env_or_else("VERBOSE", "boolean", true)
return cfg

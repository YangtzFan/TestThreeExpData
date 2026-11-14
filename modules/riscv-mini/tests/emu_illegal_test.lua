-- Run with: luajit modules/riscv-mini/tests/emu_illegal_test.lua
local root = debug.getinfo(1, "S").source:match("@?(.*/)") .. "../"
package.path = root .. "src/?.lua;" .. root .. "src/?/?.lua;" .. package.path

local Emu = require "test_riscv_mini.emu"
local model = Emu(root .. "programs/rv32mi-p-illegal.hex", { pc = 0x258 })
assert(model:fetch() == 0)
assert(model:decode(0).illegal)

local commit = model:commit_step()
assert(commit.pc == 0x258 and commit.trap and commit.trap_cause == 2)
assert(not commit.reg_wen and not commit.ram_wen and not commit.ecall)
print("Emu illegal instruction check passed")

local tspace = assert(_G.tspace, "initialize TestPointSpace in test_points/main.lua first")
local numbered_lines = tspace.utils.numbered_lines

local g = tspace.new_group("FIFO")

g:with_tp("basic")("in-order") {
    cond = numbered_lines("连续 push", "再 pop"),
    check = numbered_lines("数据顺序一致"),
    test_case = "001_basic_push_pop"
}

g:with_tp("boundary")("full/empty") {
    cond = numbered_lines("push 满 DEPTH", "再 pop 空"),
    check = numbered_lines("full 与 empty 标志正确"),
    test_case = "002_full_empty"
}

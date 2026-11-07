local tspace = assert(_G.tspace, "initialize TestPointSpace in test_points/main.lua first")
local numbered_lines = tspace.utils.numbered_lines
local g = tspace.new_group("Counter")

g:with_tp("incr")("basic") {
    cond = numbered_lines("reset 后 value=0", "incr 若干拍"),
    check = numbered_lines("value 按拍递增"),
    test_case = "001_basic_incr"
}

g:with_tp("hold")("no incr") {
    cond = numbered_lines("incr=0 持续多拍"),
    check = numbered_lines("value 保持不变"),
    test_case = "002_hold_no_incr"
}

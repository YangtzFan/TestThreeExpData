local tspace = assert(_G.tspace, "initialize TestPointSpace in test_points/main.lua first")
local numbered_lines = tspace.utils.numbered_lines
local g = tspace.new_group("Mux")

g:with_tp("sel")("a") {
    cond = numbered_lines("sel = 0"),
    check = numbered_lines("out == a"),
    test_case = "001_select_a"
}

g:with_tp("sel")("b") {
    cond = numbered_lines("sel = 1"),
    check = numbered_lines("out == b"),
    test_case = "002_select_b"
}

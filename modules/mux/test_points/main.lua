local tspace = require "test_zhujiang_docs.TestPointSpace"

tspace.initialize("Multi mux test points")
require "basic"

for tp in tspace.iter_test_points() do
    if tp.test_case ~= "" then
        tp:set_color("green")
    end
end

tspace.set_color_legend { green = "已有测试用例覆盖" }

tspace.to_markdown({ filename = "./build/mux_test_points.md" })
tspace.to_html({ filename = "./build/mux_test_points.html" })

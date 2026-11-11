---@diagnostic disable: undefined-global, undefined-field

local prj_dir = os.scriptdir()
local multi_dir = path.join(prj_dir, "..", "..")
local tc_dir = path.join(prj_dir, "test_cases")
local src_dir = path.join(prj_dir, "src")
local riscv_dir = path.join(prj_dir, "riscv-mini")
local rtl_dir = path.join(prj_dir, "build", "rtl")

target("rtl", function()
    set_kind("phony")
    set_default(false)
    on_build(function ()
        local generated_dir = path.join(riscv_dir, "build", "rtl")
        os.execv("mill", {
            "-i", "riscvMini.runMain", "mini.Main",
            "--target", "systemverilog", "--split-verilog", "-td", generated_dir
        }, { curdir = riscv_dir })
        if not os.isfile(path.join(generated_dir, "Tile.sv")) then
            raise("riscv-mini generation produced no Tile.sv under " .. generated_dir)
        end
        os.tryrm(rtl_dir)
        os.mkdir(rtl_dir)
        os.cp(path.join(generated_dir, "*"), rtl_dir)
        print("riscv-mini RTL ready: " .. rtl_dir)
    end)
end)

target("format", function()
    set_kind("phony")
    set_default(false)
    on_run(function()
        import("lib.detect.find_tool")
        local python = find_tool("python3") or find_tool("python")
        if not python then
            raise("python3 not found in PATH")
        end
        local input = os.getenv("F")
        local paths = {}
        if input and input ~= "" then
            table.insert(paths, path.absolute(input, prj_dir))
        else
            table.insert(paths, src_dir)
            table.insert(paths, tc_dir)
            table.insert(paths, path.join(prj_dir, "xmake.lua"))
            table.insert(paths, path.join(prj_dir, "main.lua"))
        end
        local script = path.join(multi_dir, "scripts", "emmylua_format.py")
        if not os.isfile(script) then
            raise("format script not found: " .. script)
        end
        local args = { script }
        for _, p in ipairs(paths) do
            table.insert(args, p)
        end
        os.execv(python.program, args)
    end)
end)

target("lsp-check", function()
    set_kind("phony")
    set_default(false)
    on_run(function()
        import("lib.detect.find_tool")
        local python = find_tool("python3") or find_tool("python")
        if not python then
            raise("python3 not found in PATH")
        end
        local input = os.getenv("F")
        local check_path = input and input ~= "" and path.absolute(input, prj_dir) or src_dir
        local script = path.join(multi_dir, "scripts", "emmylua_ls_check.py")
        if not os.isfile(script) then
            raise("lsp-check script not found: " .. script)
        end
        os.execv(python.program, { script, check_path })
    end)
end)

target("clean", function()
    set_kind("phony")
    set_default(false)
    on_run(function()
        os.tryrm(path.join(prj_dir, "build"))
    end)
end)

local function resolve_tc()
    local tc = os.getenv("TC")
    if not tc or tc == "" then
        return false
    end
    if tc:endswith(".lua") or tc:find("[/\\\\]") then
        local tc_path = path.absolute(tc, prj_dir)
        if not os.isfile(tc_path) then
            raise("testcase not found: " .. tc_path)
        end
        add_runenvs("TC_PATH", tc_path)
        add_runenvs("TC_NAME", path.basename(tc_path))
        return true
    end
    for _, file in ipairs(os.files(path.join(tc_dir, "*.lua"))) do
        local filename = path.filename(file)
        local basename = path.basename(file)
        if filename:startswith(tc) or basename:startswith(tc) or basename == tc then
            add_runenvs("TC_NAME", path.basename(file))
            return true
        end
    end
    raise("no testcase matches TC=" .. tc .. " under " .. tc_dir)
end

target("sim", function()
    set_default(true)
    add_rules("verilua")

    local sim = os.getenv("SIM") or "verilator"
    if sim == "verilator" then
        add_toolchains("@verilator")
    elseif sim == "iverilog" then
        add_toolchains("@iverilog")
    elseif sim == "vcs" then
        add_toolchains("@vcs")
    else
        raise("Unsupported SIM=" .. sim .. " (use vcs, verilator, or iverilog)")
    end

    add_files(
        path.join(rtl_dir, "*.sv"),
        path.join(rtl_dir, "verification", "*.sv"),
        path.join(rtl_dir, "verification", "assert", "*.sv"),
        path.join(rtl_dir, "verification", "assume", "*.sv"),
        path.join(rtl_dir, "verification", "cover", "*.sv"),
        path.join(prj_dir, "*.lua"),
        path.join(src_dir, "*.lua"),
        path.join(src_dir, "test_riscv_mini", "*.lua"),
        path.join(tc_dir, "*.lua")
    )

    add_runenvs("RISCV_ENV_ROOT", prj_dir)
    set_values("cfg.build_dir_name", "sim")
    set_values("cfg.user_cfg", path.join(src_dir, "cfg.lua"))
    set_values("cfg.top", "Tile")
    set_values("cfg.lua_main", path.join(prj_dir, "main.lua"))
    local include_flags = {}
    for _, dir in ipairs({ "verification", "verification/assert", "verification/assume", "verification/cover" }) do
        table.insert(include_flags, "+incdir+" .. path.join(rtl_dir, dir))
    end
    add_values("cfg.tb_gen_flags", table.unpack(include_flags))
    add_values("cfg.tb_gen_flags", "--single-unit")
    add_values("vcs.flags", table.unpack(include_flags))
    add_values("verilator.flags", table.unpack(include_flags))
    add_values("verilator.flags", "--trace", "--no-trace-top")
    set_values("vcs.run_flags", "+vcs+lic+wait")

    before_build(function()
        if #os.files(path.join(rtl_dir, "*.sv")) == 0 then
            raise("RTL empty under " .. rtl_dir .. "; run `xmake b rtl` first")
        end
    end)

    if not resolve_tc() then
        before_run(function()
            raise("TC is required, e.g. TC=001 xmake r")
        end)
    end
end)

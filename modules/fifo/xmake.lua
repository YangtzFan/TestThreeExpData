---@diagnostic disable: undefined-global, undefined-field

local prj_dir = os.scriptdir()
local multi_dir = path.join(prj_dir, "..", "..")
local tc_dir = path.join(prj_dir, "test_cases")
local src_dir = path.join(prj_dir, "src")
local rtl_dir = path.join(prj_dir, "rtl")
local common_lua = path.join(multi_dir, "common", "lua")
local docs_xmake = path.join(multi_dir, "TestZhuJiangDocs", "xmake.lua")

if os.isfile(docs_xmake) then
    includes(docs_xmake)
end

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
        local format_paths = {}
        if input and input ~= "" then
            table.insert(format_paths, path.absolute(input, prj_dir))
        else
            table.insert(format_paths, src_dir)
            table.insert(format_paths, path.join(prj_dir, "test_points"))
            table.insert(format_paths, path.join(prj_dir, "xmake.lua"))
            table.insert(format_paths, path.join(prj_dir, "main.lua"))
        end
        for _, format_path in ipairs(format_paths) do
            if not os.isfile(format_path) and not os.isdir(format_path) then
                raise("format path not found: " .. format_path)
            end
            if os.isfile(format_path) and path.extension(format_path) ~= ".lua" then
                raise("format file must be .lua: " .. format_path)
            end
        end

        local format_script = path.join(multi_dir, "scripts", "emmylua_format.py")
        if not os.isfile(format_script) then
            raise("format script not found: " .. format_script)
        end
        local args = { format_script }
        for _, format_path in ipairs(format_paths) do
            table.insert(args, format_path)
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
        local check_path = src_dir
        if input and input ~= "" then
            check_path = path.absolute(input, prj_dir)
        end
        if not os.isfile(check_path) and not os.isdir(check_path) then
            raise("lsp-check path not found: " .. check_path)
        end
        if os.isfile(check_path) and path.extension(check_path) ~= ".lua" then
            raise("lsp-check file must be .lua: " .. check_path)
        end

        local check_script = path.join(multi_dir, "scripts", "emmylua_ls_check.py")
        if not os.isfile(check_script) then
            raise("lsp-check script not found: " .. check_script)
        end
        os.execv(python.program, { check_script, check_path })
    end)
end)

target("jobs-gen", function()
    set_kind("phony")
    set_default(false)
    on_run(function()
        import("scripts.jobs_gen", { rootdir = multi_dir })
        jobs_gen {
            prj_dir = prj_dir,
            tc_dir = tc_dir,
            all_targets = { "fifo" },
            default_target = "fifo",
            all_testcases = { "001", "002", "003" },
        }
    end)
end)

local function resolve_tc()
    local TC = os.getenv("TC")
    if not TC or TC == "" then
        return false
    end
    if TC:endswith(".lua") or TC:find("[/\\]") then
        local tc_path = path.absolute(TC, prj_dir)
        if not os.isfile(tc_path) then
            raise("testcase not found: " .. tc_path)
        end
        add_runenvs("TC_PATH", tc_path)
        add_runenvs("TC_NAME", path.basename(tc_path))
        return true
    end
    local matched = nil
    for _, file in ipairs(os.files(path.join(tc_dir, "*.lua"))) do
        local filename = path.filename(file)
        local basename = path.basename(file)
        if filename:startswith(TC) or basename:startswith(TC) or basename == TC then
            matched = file
            break
        end
    end
    if not matched then
        raise("no testcase matches TC=" .. TC .. " under " .. tc_dir)
    end
    add_runenvs("TC_NAME", path.basename(matched))
    return true
end

target("fifo", function()
    set_default(true)
    add_rules("verilua")

    local sim = os.getenv("SIM") or "vcs"
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
        path.join(prj_dir, "*.lua"),
        path.join(src_dir, "*.lua"),
        path.join(src_dir, "test_fifo", "*.lua"),
        path.join(tc_dir, "*.lua"),
        path.join(common_lua, "*.lua")
    )

    set_values("verilua.build_dir_name", "fifo")
    set_values("verilua.user_cfg", path.join(src_dir, "cfg.lua"))
    set_values("verilua.top", "SimpleFifo")
    set_values("verilua.lua_main", path.join(prj_dir, "main.lua"))
    add_values("verilator.flags", "--trace", "--no-trace-top")
    set_values("vcs.run_flags", "+vcs+lic+wait")

    if not resolve_tc() then
        before_run(function()
            raise("TC is required, e.g. TC=001 xmake r")
        end)
    end
end)

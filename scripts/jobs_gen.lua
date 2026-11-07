---@diagnostic disable: undefined-global, undefined-field
SCRIPT_VERSION = "3.8.0"

--
-- jobs_gen.lua  (SCRIPT_VERSION)
--
-- Origin:
--   Canonical copy lives in the TestExample repo at scripts/jobs_gen.lua.
--   Repo: https://github.com/OpenXiangShan-Nanhu/TestExample.git
--
-- What it is:
--   An xmake module that builds a regression workspace directory from a project
--   config table. It runs from a phony `jobs-gen` target and does not run
--   simulations itself: it writes jobs.sh and the scripts that drive it.
--
-- Per-job env the module writes into each cfg file:
--   TC:   test case short id or .lua path (from all_testcases), e.g. "001".
--   SEED: random seed for this job.
--   MODE: "RegressionReproduce"; the command line overrides it with
--         "Regression" for the actual run.
--
--   Project env such as COVDIR or DB_PATH comes from `extra_env_gen` or from
--   `target_configs[target].env_overrides` in the config.
--
-- Mental model:
--
--   xmake r jobs-gen
--         |
--         v
--   .regression/
--   ├── jobs.sh          # one supervised shell line per sim (TC + SEED + xmake run)
--   ├── manifest.txt     # current-generation log basenames, trailing LF
--   ├── run.sh           # xargs runner: bash run.sh -j N
--   ├── cfg/             # per-job env snapshots (written when a job starts)
--   ├── log/             # per-job stdout/stderr
--   ├── summarize.sh     # current-generation status counts
--   ├── check_err.sh     # list failures + error context
--   ├── check_all.sh     # summarize + check_err
--   ├── collect_errors.sh # failed logs + cfg files into one directory, optional archive
--   ├── append_jobs.sh   # add N jobs to this workspace: ./append_jobs.sh N
--   ├── clean.sh         # remove log and config files
--   ├── regen.sh         # rebuild the workspace from its recorded batches
--   ├── clean-regen.sh   # clean, then regenerate
--   ├── keep_watch.sh    # watch the current status
--   ├── pack_regression.sh # pack the workspace into regression-YYYYMMDD.sh
--   ├── .internal/       # everything the scripts above call or source
--   │   ├── supervise_job.sh # shared foreground supervisor for parallel/xargs
--   │   ├── jobs_lib.sh      # shared manifest/classification helpers
--   │   ├── gen_env.sh       # generation-time environment snapshot
--   │   ├── start_time       # timestamp behind the elapsed clock
--   │   └── scan_cache.*     # log classification cache and its flock
--   └── ...
--
--   Root-level *.sh are the commands a user runs; jobs.sh, manifest.txt, cfg/, and
--   log/ are the data they act on.
--
-- Per-job flow (each line of jobs.sh):
--
--   0) skip the row when its log already ended in Success or Skipped
--   1) write cfg/<id>.cfg   MODE=RegressionReproduce  (for manual re-run)
--   2) source that cfg
--   3) MODE=Regression xmake run -P <prj> <target> > log/<id>.log
--      (command-line MODE wins over the cfg value)
--   4) append the raw xmake exit code and the elapsed time to that log, then end the job
--      with the log write status: propagating 255 would abort the xargs batch.
--
--   A row is location independent: `_ws=$PWD` at its start captures the directory the
--   row runs in (run.sh cds to the workspace root), and every workspace path resolves
--   against it. The project path is `"${PRJ_DIR:-<generation-time path>}"`, so a moved
--   workspace still runs and PRJ_DIR can point it at a project elsewhere. A workspace
--   therefore survives `mv`, and its packed copy is byte-exact.
--
-- How a testcase reports its result:
--
--   The testcase decides the outcome; jobs-gen only reads its log. main.lua prints
--   `=== test passed ===` when the testcase function returns, and
--   `=== test skipped ===` when it returns "skipped" (env.test_skipped), which is how
--   an optional case says it does not apply to this build. An error, a panic, an
--   assert failure, or a non-zero xmake return is a failure. A run that ends without
--   either verdict line has no result at all.
--
--   Marking a case skipped is therefore the testcase's job, not the generator's:
--
--       return "skipped"     -- optional case, not applicable on this configuration
--
--   e.g. test_cases/004_skip_unless_slow.lua skips unless RUN_SLOW=1, so TC=004 prints
--   `=== test skipped ===` by default and `=== test passed ===` under RUN_SLOW=1.
--
-- What each status means (`bash summarize.sh`), in the order to act on them:
--
--   Failed      The work list: the log carries an error, a panic, an assert failure,
--               or the xmake return code is non-zero. `bash check_err.sh` prints the
--               error lines of every failed job; FILTER="TIMEOUT,TASKBUF" narrows it
--               to the logs that match.
--
--   Incomplete  The run ended without either verdict line, so nothing says whether the
--               behavior is right. Two usual causes: the simulation stopped at its time
--               limit (raise the limit or shrink the workload), or it died before
--               printing the verdict (the log tail shows where).
--
--   Running     Still in progress: the log has no closing lines yet. Wait, or check
--               that the runner process is alive.
--
--   Success     The log carries `=== test passed ===` for a run that finished. Nothing
--               to do.
--
--   Skipped     The log carries `=== test skipped ===` for a run that finished: the
--               testcase itself said the current case does not apply. Not a failure,
--               and the pass rate ignores it.
--
--   Pending     The job has not started: its log file does not exist yet.
--
--   Stale       A log left behind by an earlier generation. Every count ignores it;
--               clean.sh removes it.
--
--   Finished is Success + Skipped + Failed + Incomplete. Pass rate is
--   Success / (Success + Failed), so a skip neither helps nor hurts it.
--
--   A status comes from the log file alone, and only the logs of the current
--   generation count: manifest.txt, written at generation time, decides which files
--   belong to this run. A verdict line alone is not enough: the run must also have
--   finished, so a log carrying `=== test passed ===` but no end-of-simulation line
--   stays Incomplete. The exact markers are documented at jobs_gen_scan_logs in
--   jobs_lib.sh.
--
-- Resuming:
--   Stopping a run and starting `bash run.sh` again continues where it stopped: a row
--   whose log already ended in Success or Skipped is skipped, while Failed, Incomplete,
--   Pending, and Running rows run again. The rule sits in supervise_job.sh, which takes
--   the log path as argv[1] from the row, so it covers every row of the workspace.
--   Delete a log to force one row to run again; clean.sh removes every log, forcing the
--   whole workspace to run again.
--
-- Generator CLI env (set when invoking `xmake r jobs-gen`):
--   JOBS           how many job lines to emit          (default 10000)
--   SEED_MAX       exclusive upper bound for seeds     (default 10000000, must be >= JOBS)
--   JOBS_GEN_REPLAY internal: set by regen.sh while it replays the batch list, so
--                  the replay never rewrites the script that is driving it.
--   TC             fix one testcase id for all jobs    (default: random from all_testcases)
--                  a path-shaped value must name an existing testcase file
--   TARGET         xmake target name                   (default: config.default_target)
--   OUTDIR         output directory                    (default: ./.regression)
--   FORCE_SUCCESS  "1" => exit 0 after the log write, even if the write fails
--                  Default: off; a job ends with the log write status.
--                  Xmake exit codes stay in the logs; use the reports for results.
--   APPEND         "1" => append new jobs to an existing OUTDIR (default off).
--                  An appended batch is recorded in regen.sh as its own batch, so
--                  regen.sh still replays the whole workspace in order.
--                  The generated `append_jobs.sh <count>` wraps this mode, so the
--                  frozen parameters do not have to be retyped. Rows written by
--                  jobs_gen < 3.6 carry no log path, so APPEND refuses such a workspace.
--
-- Seed rule:
--   Per-job seeds are drawn as `math.random(0, SEED_MAX)` from a generator RNG seeded
--   once per generation from the platform entropy source (never a wall-clock seed, so
--   independent and concurrent generators differ). Job identities are therefore not
--   reproducible: a regen.sh replay keeps the job count and the per-batch parameters
--   and draws every (testcase, seed) again.
--
--   Uniqueness holds within one workspace: the draw loop rejects a seed already in
--   use, an appended batch loads the used seeds from manifest.txt, and SEED_MAX covers
--   the whole workspace, since every job needs a free seed.
--
--   Every generation adds a record row to regen.sh, and regen.sh replays those rows in
--   order, so a workspace built by several appends regenerates with the same job count
--   and the same per-batch parameters. A workspace whose script records no batch makes
--   regen.sh refuse instead of rebuilding a different shape silently.
--
--   Any other environment variable present when jobs-gen runs (e.g. an ad-hoc
--   `XX=123 xmake r jobs-gen`) is snapshotted into OUTDIR/.internal/gen_env.sh.
--   regen.sh restores the variables missing from its own environment, so the
--   regenerated workspace keeps the same environment without retyping the prefix.
--
--   `STRICT=1 bash regen.sh` (or `STRICT=1 bash clean-regen.sh`) instead replays
--   `.internal/gen_env.sh` as the *complete* environment and discards everything
--   the calling shell exported, so a polluted terminal cannot leak into regeneration.
--
--   Credential-shaped names (`*_API_KEY`, `*_API_KEY_*`, `*_API_BASE`, `*_SECRET`) are
--   never snapshotted, so exported keys and endpoints stay out of the regression dir.
--
-- Packing a workspace into one file (`pack_regression.sh`):
--
--   bash .regression/pack_regression.sh     # OUTDIR defaults to the packer's directory
--
--   The packer copies the workspace scripts, jobs.sh, and manifest.txt from disk into
--   OUTDIR/regression-YYYYMMDD.sh, so it also packs a workspace built by an earlier
--   jobs_gen. Running the packed file restores the workspace byte for byte:
--
--       bash regression-20250102.sh            # restore beside the script into regression-20250102/
--       bash regression-20250102.sh -o DIR     # restore into DIR, created if missing
--       bash regression-20250102.sh -f -o DIR  # replace an existing workspace there
--
--   Without -o the packed file creates regression-YYYYMMDD/ next to itself.
--
--   The packed file writes only; it never starts a run. Not packed: log/ and cfg/
--   (per-run data), .internal/gen_env.sh (the generating shell's environment, which the
--   credential rule above cannot fully clean), and the regenerated-on-demand caches.
--
-- Wire-up (TestExample style; Utils projects use TestZhuJiangUtils.xmake.jobs_gen):
--
--   target("jobs-gen", function()
--       set_kind("phony")
--       set_default(false)
--       on_run(function()
--           -- rootdir is required when this target lives in an `includes()`-ed file,
--           -- so that import() can resolve the module.
--           import("scripts.jobs_gen", { rootdir = os.projectdir() })
--           jobs_gen {
--               tc_dir = path.join(os.projectdir(), "test_cases"),
--               all_targets = { "MyTarget" },
--               default_target = "MyTarget",
--               all_testcases = { "001", "002", "cases/extra.lua" },  -- short ids or .lua paths
--           }
--       end)
--   end)
--
-- Typical use:
--   JOBS=200 TARGET=MyTarget xmake r jobs-gen
--   cd .regression
--   bash run.sh               # 1 parallel job by default
--   bash run.sh -j 8          # 8 parallel jobs
--   bash keep_watch.sh         # status, in another terminal
--   ./append_jobs.sh 500       # add 500 jobs to this workspace
--   bash regen.sh              # rebuild it from the recorded batches
--   bash pack_regression.sh    # one-file copy of this workspace
--

--- Per-target configuration.
--- Each target can have its own env overrides, max job count, and a post-generation callback.
---
--- Example:
--- ```lua
--- target_configs = {
---     TestMyDUTVcsCov = {
---         -- Override env variables for this target (e.g. disable monitors)
---         env_overrides = { ENABLE_MONITOR = 0 },
---         -- Limit max jobs (e.g. Verdi can only handle 32K tests)
---         max_jobs = 32768,
---         -- post_gen: callback for project-specific post-generation logic
---         post_gen = function(ctx)
---             -- e.g. generate coverage merge scripts, extra reports, etc.
---         end,
---     },
--- }
--- ```
---@class JobsGenTargetConfig
---@field env_overrides table<string, number>? Environment variable overrides for this target
---@field max_jobs integer? Maximum number of jobs allowed for this target
---@field post_gen fun(ctx: JobsGenContext)? Callback invoked after all jobs and scripts are generated

--- Context table passed to `post_gen` callback, containing all resolved generation parameters.
---@class JobsGenContext
---@field prj_dir string Project root directory (absolute path)
---@field tc_dir string Test cases directory (absolute path)
---@field outdir string Output directory for generated scripts
---@field target string Selected target name
---@field tc string? Selected test case ID (nil if randomly selected)
---@field jobs integer Total number of jobs generated
---@field seed_max integer Maximum seed value
---@field all_testcases string[] List of all available test case short IDs or .lua paths
---@field all_targets string[] List of all available target names

--- Main configuration table for the jobs-gen module.
---
--- Example (full):
--- ```lua
--- jobs_gen {
---     -- prj_dir is optional, defaults to os.projectdir()
---     tc_dir = path.join(os.projectdir(), "test_cases", "v1"),
---     all_targets = { "TestDongJiang", "TestDongJiangCov", "TestDongJiangVcsCov" },
---     default_target = "TestDongJiang",
---     all_testcases = { "001", "002", "cases/extra.lua" },  -- short ids or .lua paths
---
---     -- target_configs: per-target overrides and hooks.
---     -- env_overrides: fixed env values exported for this target
---     -- max_jobs: cap the maximum number of jobs for this target
---     -- post_gen: callback for extra post-generation logic (e.g. coverage scripts)
---     target_configs = {
---         TestDongJiangVcsCov = {
---             env_overrides = { ENABLE_MONITOR = 0 },
---             max_jobs = 32768,  -- Verdi can only handle at most 32K tests
---             post_gen = function(ctx)
---                 -- e.g. generate VCS coverage merge/view scripts
---             end,
---         },
---     },
---
---     -- extra_env_gen: callback to append project-specific env exports.
---     -- Called once per job. Receives a JobInfo table with per-job context.
---     -- Returns one or two strings (shell export format with \\n separators):
---     --   1st return: written to .cfg file AND sourced on command line (for reproduction)
---     --   2nd return (optional): only prepended to the command line, NOT in .cfg file
---     --     Use this for env vars that are only needed during regression but not
---     --     for manual reproduction (e.g. coverage directories, temp paths).
---     extra_env_gen = function(job_info)
---         local cfg_str = ""
---         -- Env vars for both cfg file and command line
---         cfg_str = cfg_str .. string.format("export DB_PATH=%s\\n", path.join(job_info.outdir, "db"))
---         cfg_str = cfg_str .. string.format("export DB_FILE_NAME=%s.db\\n", job_info.test_name)
---         local cmd_str = ""
---         -- Env vars for command line only (not written to cfg file)
---         cmd_str = cmd_str .. string.format("export COVDIR=%s\\n", some_path)
---         return cfg_str, cmd_str  -- 2nd return is optional
---     end,
---
---     -- extra_clean: extra shell commands appended to clean.sh.
---     -- Use this for project-specific cleanup (e.g. removing coverage databases).
---     extra_clean = "rm -rf ./cov.vdb ./merged.vdb",
---
--- }
--- ```
---@class JobsGenConfig
---@field prj_dir string? Project root directory (defaults to os.projectdir())
---@field tc_dir string Test cases directory
---@field all_targets string[] Available target list
---@field default_target string Default target name (used when TARGET env var is not set)
---@field all_testcases string[] Available test case short IDs (e.g. {"001", "002"}) or .lua paths, which are resolved against prj_dir and must exist
---@field target_configs table<string, JobsGenTargetConfig>? Per-target configurations (key => target config)
---@field extra_env_gen fun(job_info: JobInfo): string, string?  Per-job env gen callback. 1st return: cfg file + cmd line; 2nd return (optional): cmd line only
---@field extra_clean string? Extra shell script content to append to clean.sh (e.g. "rm -rf ./cov.vdb")

--- Per-job context passed to `extra_env_gen` callback.
---@class JobInfo
---@field test_name string Unique test name for this job (e.g. "0_TC_001_SEED_12345")
---@field tc_id string Test case ID (e.g. "001")
---@field seed integer Random seed for this job
---@field outdir string Output directory for generated scripts

--- Entry: emit OUTDIR scripts from config + JOBS/SEED_MAX/TC/TARGET/OUTDIR/FORCE_SUCCESS/APPEND env.
---@param config JobsGenConfig
function main(config)
    local function shell_quote(str)
        return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
    end

    --- Quote for a `printf '%b'` argument. `%b` interprets backslash escapes, so CR and
    --- LF travel as `\r` and `\n` and cannot end the shell word.
    ---@param str string
    ---@return string
    local function shell_quote_printf_b(str)
        return shell_quote(tostring(str):gsub("\r", "\\r"):gsub("\n", "\\n"))
    end

    --- Every generated file is POSIX text, so it ends with LF. pack_regression.sh
    --- restores these files from a single-file heredoc copy, and a trailing LF keeps
    --- that restore byte-exact.
    ---@param content string
    ---@return string
    local function ensure_trailing_lf(content)
        if content == "" or content:sub(-1) == "\n" then
            return content
        end
        return content .. "\n"
    end

    --- Write one generated file as POSIX text.
    ---@param file_path string
    ---@param content string
    local function write_file(file_path, content)
        io.writefile(file_path, ensure_trailing_lf(content))
    end

    --- Replace a generated script through a temp file and a rename. regen.sh and
    --- append_jobs.sh rewrite themselves while they run, and truncating the file under
    --- a copy that is still reading it aborts that copy mid-parse.
    ---@param target_path string
    ---@param content string
    local function replace_script(target_path, content)
        local tmp_path = target_path .. ".tmp"
        write_file(tmp_path, content)
        os.execv("mv", { "-f", tmp_path, target_path })
    end

    --- A jobs.sh row is `<supervisor> <log-path> <workload>`, each part shell-quoted. Every
    --- log path starts with `log/`, so a row this generator wrote begins with the quoted
    --- supervisor name, a space, and the opening quote of that log path. The append check
    --- below uses that prefix to recognize such a row.
    local SUPERVISOR_SCRIPT = ".internal/supervise_job.sh"
    local JOBS_ROW_PREFIX = shell_quote(SUPERVISOR_SCRIPT) .. " 'log/"

    --- One jobs.sh row: the shared foreground supervisor, the workspace-relative log path
    --- as argv[1], and the workload. The supervisor hands the log path to the resume guard
    --- instead of parsing it back out of the command line.
    ---@param log_rel string
    ---@param workload_cmd string
    ---@return string
    local function supervised_row(log_rel, workload_cmd)
        return string.format("%s %s %s", shell_quote(SUPERVISOR_SCRIPT), shell_quote(log_rel),
            shell_quote(workload_cmd))
    end

    --- Join rows with a trailing LF so wc -l equals the row count.
    ---@param rows string[]
    ---@return string
    local function join_lines_with_trailing_lf(rows)
        if #rows == 0 then
            return ""
        end
        return table.concat(rows, "\n") .. "\n"
    end

    -- Validate required config fields
    assert(type(config) == "table",
        "[jobs-gen] config must be a table, got: " .. type(config) .. " => '" .. tostring(config) .. "'")
    assert(config.tc_dir, "[jobs-gen] config.tc_dir is required")
    assert(config.all_targets, "[jobs-gen] config.all_targets is required")
    assert(config.default_target, "[jobs-gen] config.default_target is required")
    assert(config.all_testcases, "[jobs-gen] config.all_testcases is required")

    -- prj_dir defaults to os.projectdir() if not specified
    local prj_dir = config.prj_dir
    if prj_dir == nil then
        prj_dir = os.projectdir()
    end
    prj_dir = assert(prj_dir) --[[@as string]]
    -- Every job row carries the project path inside "${PRJ_DIR:-<path>}", so the path
    -- must survive double-quote expansion unchanged.
    if prj_dir:find('[%c"$`\\]') then
        raise("[jobs-gen] prj_dir must not contain quotes, '$', backticks or backslashes: %s", prj_dir)
    end
    local all_targets = config.all_targets
    local all_testcases = config.all_testcases
    local target_configs = config.target_configs or {}
    local extra_env_gen = config.extra_env_gen

    -- Read parameters from environment variables (with defaults)
    local jobs = tonumber(os.getenv("JOBS") or "10000")
    local seed_max = tonumber(os.getenv("SEED_MAX") or "10000000") --[[@as integer]]
    assert(jobs, "[jobs-gen] invalid JOBS env var, must be a number")
    assert(seed_max, "[jobs-gen] invalid SEED_MAX env var, must be a number")
    local tc = os.getenv("TC")
    local outdir = os.getenv("OUTDIR") or "./.regression"
    -- Everything the generated scripts call or source lives here; the workspace root
    -- keeps only the user commands and the job data.
    local internal_dir = path.join(outdir, ".internal")
    local target = os.getenv("TARGET") or config.default_target
    local force_success = os.getenv("FORCE_SUCCESS") == "1"
    local append = os.getenv("APPEND") == "1"
    local replay = os.getenv("JOBS_GEN_REPLAY") == "1"

    --- Whether a testcase entry names a file path instead of a short id.
    ---@param entry string
    ---@return boolean
    local function is_testcase_path(entry)
        return entry:endswith(".lua") or entry:find("[/\\\\]") ~= nil
    end

    -- Validate the testcase list once, before anything is written. A short id is
    -- resolved inside the project by resolve_tc() (prefix match against tc_dir), so
    -- it stays unchecked here; a path entry must name an existing .lua file reachable
    -- from prj_dir, so a typo fails at generation instead of inside a job log.
    for index = 1, #all_testcases do
        local entry = all_testcases[index]
        assert(type(entry) == "string" and entry ~= "",
            "[jobs-gen] all_testcases[" .. index .. "] must be a non-empty string")
        if is_testcase_path(entry) then
            if not entry:endswith(".lua") then
                raise("[jobs-gen] all_testcases[%d] must name a .lua testcase: `%s`", index, entry)
            end
            local tc_path = path.absolute(entry, prj_dir)
            if not os.isfile(tc_path) then
                raise("[jobs-gen] all_testcases[%d] testcase not found: %s", index, tc_path)
            end
        end
    end

    local tc_count = #all_testcases

    --- Reads the batch records written by earlier generations. They are comment rows
    --- at the top of regen.sh, so no second file has to stay in sync with the script
    --- that replays them. A script without records, such as a hand-edited one,
    --- yields an empty list.
    ---@return string[]
    local function recorded_batches()
        local regen_path = path.join(outdir, "regen.sh")
        if not os.isfile(regen_path) then
            return {}
        end
        local regen_text = io.readfile(regen_path) --[[@as string?]] or ""
        local batches = {}
        for row in regen_text:gmatch("[^\r\n]+") do
            local params = row:match("^# batch %d+: (.+)$")
            if params ~= nil then
                table.insert(batches, params)
            end
        end
        return batches
    end

    -- Validate seed_max is large enough to generate unique seeds
    if seed_max < jobs then
        raise("[jobs-gen] seed_max (%d) must be >= jobs (%d) to generate unique seeds", seed_max, jobs)
    end

    -- Validate test case ID: a registered short id ("001") or a file path
    -- ("…/.lua" or containing "/" or "\\) is allowed directly; resolve_tc() in
    -- xmake.lua treats a path-shaped TC as a testcase path.
    --
    -- A path-shaped TC resolves against prj_dir at run time, so it must name an existing
    -- file: the all_testcases loop above applies the same rule to its path entries. A
    -- typo fails here instead of inside every job log.
    if tc then
        if is_testcase_path(tc) then
            local tc_path = path.absolute(tc, prj_dir)
            if not os.isfile(tc_path) then
                raise("[jobs-gen] TC= testcase not found: %s", tc_path)
            end
        elseif not table.contains(all_testcases, tc) then
            raise("[jobs-gen] Invalid test case: `%s`, not found in {%s}", tc, table.concat(all_testcases, ","))
        end
    end

    -- Validate target name
    if not table.contains(all_targets, target) then
        raise("[jobs-gen] Invalid target: `%s`, not found in {%s}", target, table.concat(all_targets, ","))
    end

    -- Check per-target max_jobs limit
    local target_config = target_configs[target]
    if target_config and target_config.max_jobs and jobs > target_config.max_jobs then
        raise(
            "[jobs-gen] Invalid jobs: `%d`, too large for target `%s`, please use less than %d",
            jobs, target, target_config.max_jobs)
    end

    -- Seeds already used by this workspace: loaded from manifest.txt on APPEND=1,
    -- then extended by the draw loop below.
    ---@type table<number, boolean>
    local used_seeds = {}
    ---@type number
    local append_start_index = 0
    local existing_jobs_text = ""
    local existing_manifest_text = ""
    local existing_job_count = 0
    if append then
        local jobs_path = path.join(outdir, "jobs.sh")
        local manifest_path = path.join(outdir, "manifest.txt")
        assert(os.isfile(jobs_path) and os.isfile(manifest_path),
            "[jobs-gen] APPEND=1 requires an existing jobs.sh and manifest.txt in " .. outdir)
        existing_jobs_text = io.readfile(jobs_path) --[[@as string?]] or ""
        existing_manifest_text = io.readfile(manifest_path) --[[@as string?]] or ""
        -- Every row must hand its log path to the supervisor as argv[1]. A row written by
        -- jobs_gen < 3.6 carries only the workload, which this supervisor rejects, so the
        -- append is refused rather than mixing two row shapes in one jobs.sh.
        local jobs_row_count = 0
        for row in existing_jobs_text:gmatch("[^\r\n]+") do
            jobs_row_count = jobs_row_count + 1
            if row:sub(1, #JOBS_ROW_PREFIX) ~= JOBS_ROW_PREFIX then
                raise("[jobs-gen] APPEND=1 needs rows that pass the log path to supervise_job.sh;" ..
                    " jobs.sh row %d was written by an older jobs_gen, so regenerate this" ..
                    " workspace from scratch", jobs_row_count)
            end
        end
        local _, manifest_row_count = existing_manifest_text:gsub("[^\r\n]+", "")
        -- jobs.sh and manifest.txt are two separate writes, so an interrupted append leaves
        -- them out of sync. Refuse that workspace instead of replaying a total job count the
        -- manifest no longer describes.
        assert(jobs_row_count == manifest_row_count,
            "[jobs-gen] APPEND=1 jobs.sh and manifest.txt row counts differ; refusing")
        existing_job_count = manifest_row_count
        -- Match one manifest row at a time: `.+` spans newlines in Lua
        -- patterns, so a whole-text gmatch would collapse every row into one
        -- match and lose both the next index and the used-seed set.
        -- Rows are the job names gen_cmd writes: "<index>_TC_<testcase>_SEED_<seed>.log".
        for row in existing_manifest_text:gmatch("[^\r\n]+") do
            local index_text, seed_text = row:match("^(%d+)_TC_.+_SEED_(%d+)%.log$")
            if index_text ~= nil then
                local index = tonumber(index_text) --[[@as integer]]
                local seed = tonumber(seed_text) --[[@as integer]]
                append_start_index = math.max(append_start_index, index + 1)
                used_seeds[seed] = true
            end
        end
    end
    local total_jobs = existing_job_count + jobs
    -- The pool has to cover the whole workspace, not just this batch: appending into
    -- a nearly full pool would otherwise spin in the draw loop below and report a
    -- failure that never mentions SEED_MAX. `SEED_MAX >= JOBS` was checked earlier.
    if append and seed_max < total_jobs then
        raise("[jobs-gen] seed_max (%d) must be >= total jobs (%d) to append more jobs", seed_max, total_jobs)
    end

    local target_env_overrides = (target_config and target_config.env_overrides) or nil

    --- @param job_info JobInfo Per-job context
    local function gen_env_cfg_str(job_info)
        local env_parts = {}
        if target_env_overrides then
            for env_key, env_val in pairs(target_env_overrides) do
                assert(type(env_val) == "number", "[jobs-gen] target env_overrides value must be a number: " .. env_key)
                table.insert(env_parts, string.format("export %s=%d\n", env_key, env_val))
            end
        end
        local env_cfg_str = table.concat(env_parts)

        -- Append project-specific extra environment variables.
        -- extra_env_gen returns: cfg_str (written to .cfg + sourced), cmd_str (command-line only).
        local extra_cmd_str = ""
        if extra_env_gen then
            local extra_cfg, extra_cmd = extra_env_gen(job_info)
            assert(type(extra_cfg) == "string",
                "[jobs-gen] extra_env_gen 1st return must be a string, got: " .. type(extra_cfg))
            if extra_cmd ~= nil then
                assert(type(extra_cmd) == "string",
                    "[jobs-gen] extra_env_gen 2nd return must be a string or nil, got: " .. type(extra_cmd))
                extra_cmd_str = extra_cmd
            end
            env_cfg_str = env_cfg_str .. extra_cfg
        end

        return env_cfg_str, extra_cmd_str
    end

    -- Generate a single simulation row for the given test case and seed: write a .cfg file
    -- with the env exports, source it, then run xmake through the supervisor.
    local jobs_rows = {}
    local manifest_rows = {}
    local next_job_index = append_start_index
    local function gen_cmd(tc_id, seed)
        -- The job name is the basename without the .lua suffix, keeping cfg/log filenames
        -- free of path separators and suffixes; the exported TC keeps the full value,
        -- which resolve_tc() consumes. The pattern splits POSIX "/" and Windows "\\".
        local tc_name = tc_id:match("([^/\\\\]+)$") or tc_id
        tc_name = tc_name:gsub("%.lua$", "")
        local test_name = string.format("%d_TC_%s_SEED_%d", next_job_index, tc_name, seed)
        if test_name:find("[\r\n]") then
            raise("[jobs-gen] job name must not contain a newline: `%s`", test_name)
        end
        local cfg_rel = string.format("cfg/%s.cfg", test_name)
        local log_rel = string.format("log/%s.log", test_name)
        local env_cfg_str, extra_cmd_str = gen_env_cfg_str({
            test_name = test_name,
            tc_id = tc_id,
            seed = seed,
            outdir = outdir,
        })
        -- Quote TC, because the cfg is sourced as shell and a path may contain spaces.
        local cfg_content = string.format(
            "export TC=%s\nexport SEED=%d\nexport MODE=RegressionReproduce\n%s",
            shell_quote(tc_id),
            seed,
            env_cfg_str
        )
        -- The relative path is quoted as its own shell word: a testcase basename may
        -- hold a quote, a '$' or a backtick, and "$_ws/<path>" would let it break the row.
        local gen_cfg = string.format(
            [[printf '%%b' %s > "$_ws"/%s]],
            shell_quote_printf_b(cfg_content),
            shell_quote(cfg_rel)
        )
        -- Each segment is one shell statement, and the row joins them with "; ", so the
        -- whole job stays a single command line for `bash -lc`.
        -- _ws=$PWD makes every workspace path resolve against the directory the row runs in
        -- (run.sh cds to the workspace root), so the workspace can be moved and the packed
        -- bundle (pack_regression.sh) is a byte-exact copy of jobs.sh.
        -- _prj honours ${PRJ_DIR} so a packed workspace can point at a project elsewhere.
        local cmd_segments = {
            "_ws=$PWD",
            string.format('_prj="${PRJ_DIR:-%s}"', prj_dir),
            gen_cfg,
            string.format('source "$_ws"/%s', shell_quote(cfg_rel)),
            'cd "$_prj"',
        }
        if extra_cmd_str ~= "" then
            -- Command-line-only env vars from extra_env_gen's 2nd return: eval the exports
            -- before xmake run, so they never reach the cfg file.
            table.insert(cmd_segments,
                string.format([[eval "$(printf '%%b' %s)"]], shell_quote_printf_b(extra_cmd_str)))
        end
        -- The elapsed clock starts once the environment is in place, so it covers xmake.
        table.insert(cmd_segments, "_start=$(date +%s)")
        -- MODE=Regression on the command line overrides MODE=RegressionReproduce from the cfg
        -- file, which stays as written for a manual reproduce. `xmake run -P <prj_dir>` binds
        -- xmake to the intended project instead of the CWD.
        table.insert(cmd_segments,
            string.format('MODE=Regression xmake run -P "$_prj" %s > "$_ws"/%s 2>&1', target,
                shell_quote(log_rel)))
        local cmd = table.concat(cmd_segments, "; ")
        -- Footer keeps the raw xmake status; ending on 255 would abort the xargs batch.
        cmd = cmd .. string.format(
            [[; _raw_exit=$?; _end=$(date +%%s); _elapsed=$((_end - _start)); printf "\n[jobs-gen] Xmake exit: %%d\n[jobs-gen] Elapsed: %%02d:%%02d:%%02d\n" "$_raw_exit" $((_elapsed/3600)) $(((_elapsed%%3600)/60)) $((_elapsed%%60)) >> "$_ws"/%s%s]],
            shell_quote(log_rel),
            force_success and "; exit 0" or ""
        )
        table.insert(jobs_rows, supervised_row(log_rel, cmd))
        table.insert(manifest_rows, test_name .. ".log")
        next_job_index = next_job_index + 1
    end

    -- Seed the generator RNG for this generation: xmake's hash.rand32 draws from the
    -- platform entropy source, so two concurrent generators do not share a seed, and
    -- folding in the pid guards against a repeated entropy draw.
    local entropy = hash.rand32() .. ":" .. tostring(os.getpid())
    local generation_seed = tonumber(hash.strhash32(entropy), 16) --[[@as integer]]
    assert(generation_seed ~= nil and generation_seed ~= 0, "[jobs-gen] failed to draw a fresh generation seed")
    math.randomseed(generation_seed)

    -- Draw one unique seed per job and pick a test case for each. Collisions are
    -- expected as the pool fills, so a long streak aborts instead of spinning forever.
    local jobs_emitted = 0
    local collision_streak = 0
    while jobs_emitted < jobs do
        local seed = math.random(0, seed_max)
        if used_seeds[seed] then
            collision_streak = collision_streak + 1
            if collision_streak >= 10000 then
                raise("[jobs-gen] Failed to generate unique seed after %d attempts", collision_streak)
            end
        else
            used_seeds[seed] = true

            if tc then
                gen_cmd(tc, seed)
            else
                gen_cmd(all_testcases[math.random(1, tc_count)], seed)
            end

            jobs_emitted = jobs_emitted + 1
            collision_streak = 0
        end
    end

    -- Create output directories
    os.mkdir(path.join(outdir, "cfg"))
    os.mkdir(path.join(outdir, "log"))
    os.mkdir(internal_dir)

    -- Write supervise_job.sh: shared foreground supervisor for parallel and xargs.
    write_file(path.join(internal_dir, "supervise_job.sh"), [[#!/usr/bin/env bash
# Foreground supervisor for one non-interactive regression job.
# The supervisor stays in the runner process group; the workload runs in a new session.
# Usage: supervise_job.sh <log-path> <workload-command>
set -u

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <log-path> <workload-command>" >&2
    exit 2
fi
_jobs_gen_log_path="$1"
workload="$2"

# jobs-gen resume guard: skip this row when its log already ended in Success or Skipped.
# Delete the log to force this row to run again.
_jobs_gen_lib="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/jobs_lib.sh"
if [ -f "${_jobs_gen_log_path}" ] && [ -f "${_jobs_gen_lib}" ]; then
    # shellcheck source=/dev/null
    source "${_jobs_gen_lib}"
    _jobs_gen_log_list=$(mktemp)
    printf '%s\n' "${_jobs_gen_log_path}" > "${_jobs_gen_log_list}"
    _jobs_gen_bucket=$(jobs_gen_scan_logs "${_jobs_gen_log_list}" | cut -f2)
    rm -f "${_jobs_gen_log_list}"
    if [ "${_jobs_gen_bucket}" = "pass" ] || [ "${_jobs_gen_bucket}" = "skip" ]; then
        echo "[jobs-gen] skip succeeded job: ${_jobs_gen_log_path}" >&2
        exit 0
    fi
fi

JOB_TERM_GRACE_SEC="${JOB_TERM_GRACE_SEC:-30}"
case "$JOB_TERM_GRACE_SEC" in
    ''|*[!0-9]*)
        echo "[jobs-gen] JOB_TERM_GRACE_SEC must be a positive integer, got: ${JOB_TERM_GRACE_SEC}" >&2
        exit 1
        ;;
esac
if [ "$JOB_TERM_GRACE_SEC" -le 0 ]; then
    echo "[jobs-gen] JOB_TERM_GRACE_SEC must be a positive integer, got: ${JOB_TERM_GRACE_SEC}" >&2
    exit 1
fi

_child_pgid=""
_waiter_pid=""
_exit_status=0
_pid_file=""
_child_group_validated=0

_reap_child_group() {
    if [ "${_child_group_validated}" -ne 1 ] || [ -z "${_child_pgid}" ]; then
        return 0
    fi
    if ! kill -0 -- "-${_child_pgid}" 2>/dev/null; then
        return 0
    fi

    kill -TERM -- "-${_child_pgid}" 2>/dev/null || true

    local waited=0
    while [ "${waited}" -lt "${JOB_TERM_GRACE_SEC}" ]; do
        if ! kill -0 -- "-${_child_pgid}" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 -- "-${_child_pgid}" 2>/dev/null; then
        kill -KILL -- "-${_child_pgid}" 2>/dev/null || true
    fi
}

# Records a pgid only after checking that it is > 1 and equal to the child PID, so the
# negative-PID kill in _reap_child_group addresses that child's own group.
_discover_child_group() {
    if [ -n "${_child_pgid}" ]; then
        return 0
    fi
    if [ -n "${_pid_file}" ] && [ -s "${_pid_file}" ]; then
        IFS= read -r _candidate < "${_pid_file}" || true
        case "${_candidate:-}" in
            ''|*[!0-9]*) ;;
            *)
                _observed=$(ps -o pgid= -p "${_candidate}" 2>/dev/null | tr -d ' ')
                if [ "${_observed}" = "${_candidate}" ] && [ "${_candidate}" -gt 1 ]; then
                    _child_pgid="${_candidate}"
                    _child_group_validated=1
                fi
                ;;
        esac
    fi
}

_cleanup() {
    local reason="$1"
    trap - EXIT
    trap '' TERM INT HUP
    # A signal can arrive before the session leader has written its pid file.
    # Wait briefly for the handshake instead of blocking forever in wait on a
    # workload group that is not addressable yet.
    local _cleanup_deadline=$(( $(date +%s) + 5 ))
    while [ "${_child_group_validated}" -ne 1 ] && [ "$(date +%s)" -lt "${_cleanup_deadline}" ]; do
        if ! kill -0 "${_waiter_pid}" 2>/dev/null; then
            break
        fi
        _discover_child_group
        if [ "${_child_group_validated}" -eq 1 ]; then
            break
        fi
        sleep 0.05
    done
    _reap_child_group
    if [ -n "${_waiter_pid}" ]; then
        if [ "${_child_group_validated}" -ne 1 ]; then
            # Handshake never completed: kill the waiter so wait cannot hang on
            # an orphaned workload; the workload never became addressable.
            kill -KILL "${_waiter_pid}" 2>/dev/null || true
        fi
        wait "${_waiter_pid}" 2>/dev/null || true
        _waiter_pid=""
    fi
    case "${reason}" in
        TERM) exit 143 ;;
        INT)  exit 130 ;;
        HUP)  exit 129 ;;
        EXIT) exit "${_exit_status}" ;;
    esac
}

trap '_cleanup TERM' TERM
trap '_cleanup INT' INT
trap '_cleanup HUP' HUP
trap '_cleanup EXIT' EXIT

_pid_dir=$(mktemp -d "${TMPDIR:-/tmp}/jobs-gen-pgid.XXXXXX")
_pid_file="${_pid_dir}/pgid"

setsid --wait bash -c 'printf "%s\n" "$$" > "$1"; exec bash -lc "$2"' bash "${_pid_file}" "${workload}" &
_waiter_pid=$!

_bootstrap_deadline=$(( $(date +%s) + 5 ))
while [ ! -s "${_pid_file}" ]; do
    if ! kill -0 "${_waiter_pid}" 2>/dev/null; then
        break
    fi
    if [ "$(date +%s)" -ge "${_bootstrap_deadline}" ]; then
        break
    fi
    sleep 0.05
done
_discover_child_group
if [ -z "${_child_pgid}" ]; then
    echo "[jobs-gen] failed to validate child session during bootstrap" >&2
fi
rm -rf "${_pid_dir}"

wait "${_waiter_pid}"
_exit_status=$?
_waiter_pid=""
exit "${_exit_status}"
]])

    -- Write jobs_lib.sh: shared manifest/classification helpers for check scripts.
    write_file(path.join(internal_dir, "jobs_lib.sh"), [=[
#!/usr/bin/env bash
# Shared helpers for generated regression check scripts.
# Filenames may contain spaces; newlines in names are unsupported.

jobs_gen_load_manifest() {
    HAS_MANIFEST=0
    MANIFEST_NAMES=()
    declare -gA MANIFEST_SET=()
    MANIFEST_SET=()
    if [ -f ./manifest.txt ]; then
        HAS_MANIFEST=1
        while IFS= read -r _name || [ -n "$_name" ]; do
            [ -z "$_name" ] && continue
            MANIFEST_NAMES+=("$_name")
            MANIFEST_SET["$_name"]=1
        done < ./manifest.txt
    fi
}

jobs_gen_count_stale() {
    local stale=0
    if [ "$HAS_MANIFEST" -eq 1 ]; then
        local f base
        while IFS= read -r -d '' f; do
            base="${f##*/}"
            if [ -z "${MANIFEST_SET[$base]+x}" ]; then
                stale=$((stale + 1))
            fi
        done < <(find ./log -maxdepth 1 -type f -print0 2>/dev/null)
    fi
    printf '%s\n' "$stale"
}

jobs_gen_list_current_logs() {
    local out="$1"
    : > "$out"
    if [ "$HAS_MANIFEST" -eq 1 ]; then
        local name
        for name in "${MANIFEST_NAMES[@]}"; do
            if [ -f "./log/$name" ]; then
                printf '%s\n' "./log/$name" >> "$out"
            fi
        done
    else
        find ./log -maxdepth 1 -type f 2>/dev/null >> "$out" || true
    fi
}

# Scan the current-generation logs (the manifest entries when there is a manifest,
# every log file otherwise) and write "path<TAB>bucket<TAB>elapsed" lines to <out>.
# Uses the cache whenever a manifest makes this a real regression workspace.
jobs_gen_scan_current_logs() {
    local out="$1"
    local list
    list=$(mktemp)
    jobs_gen_list_current_logs "$list"
    if [ "$HAS_MANIFEST" -eq 1 ]; then
        jobs_gen_scan_logs_cached "$list" > "$out"
    else
        jobs_gen_scan_logs "$list" > "$out"
    fi
    rm -f "$list"
}

# Single-pass log scanner: reads every listed log once, one open per file, and
# classifies it. One pass per file beats a streaming pattern search here: the
# markers sit at the file tail, so a search cannot stop early, and the assert
# banner echo appears in every log, so a searched pattern matches everywhere.
# Bucket priority: fail > time-limited inc > completed skip/pass > inc > run.
# Normalization and failure detection are shared with the error details below.
# No exemptions for command lines: a failure on a line carrying -cm/-assert still
# counts.
# What each bucket means for the reader, and when to act: see "What each status
# means" in the jobs_gen.lua header.
JOBS_GEN_AWK='
    function normalize(s) {
        gsub(/\033\[[0-?]*[ -\/]*[@-~]/, "", s)
        gsub(/\r/, "", s)
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
    }
    function failed(s, lower) {
        lower = tolower(s)
        return s ~ /^(Fatal:|Error-\[[^]]+\]|Error:)/ ||
            s ~ /^\[Scheduler\] Error while executing task/ ||
            s ~ /^(Lua )?PANIC:/ || lower ~ /(^|[[:space:]])panicked at([[:space:]]|$)/ ||
            lower ~ /(^|[^[:alnum:]_])assertion[[:space:]]+failed([:![:space:]]|$)/ ||
            (s ~ /^\[jobs-gen\] Xmake exit: [0-9]+$/ && s !~ /: 0$/)
    }
    # Scheduler errors, simulator Error-[...] banners and Rust panics print their
    # payload after the marker, so the detail output continues past it.
    function detail_follows(s, lower) {
        lower = tolower(s)
        return s ~ /^\[Scheduler\] Error while executing task/ ||
            s ~ /^Error-\[/ ||
            lower ~ /(^|[[:space:]])panicked at([[:space:]]|$)/
    }
'
# Prints "path<TAB>bucket<TAB>elapsed" lines (elapsed from the last footer).
jobs_gen_scan_logs() {
    local list="$1"
    if [ ! -s "$list" ]; then
        return 0
    fi
    xargs -d '\n' -a "$list" -r awk "$JOBS_GEN_AWK"'
        BEGIN { for (i = 1; i < ARGC; i++) files[ARGV[i]] = 1 }
        function bucket(f) {
            if (f in has_err) return "fail"
            if (f in has_time) return "inc"
            if (f in has_finish && (f in has_exit || last[f] ~ /^\[jobs-gen\] Elapsed: [0-9]+:[0-9][0-9]:[0-9][0-9]$/)) {
                if (f in has_skip) return "skip"
                if (f in has_pass) return "pass"
            }
            if (f in has_elapsed || f in has_exit || f in has_finish) return "inc"
            return "run"
        }
        { $0 = normalize($0); if ($0 != "") last[FILENAME] = $0 }
        tolower($0) == "=== test skipped ===" { has_skip[FILENAME] = 1 }
        tolower($0) == "=== test passed ===" { has_pass[FILENAME] = 1 }
        failed($0) { has_err[FILENAME] = 1 }
        /^Simulation Finished!($| Elapsed time: [0-9.]+ sec$)/ { has_finish[FILENAME] = 1 }
        /^Simulation time is enough/ { has_time[FILENAME] = 1 }
        /^\[jobs-gen\] Xmake exit: [0-9]+$/ { has_exit[FILENAME] = 1 }
        /^\[jobs-gen\] Elapsed: [0-9]+:[0-9][0-9]:[0-9][0-9]$/ {
            has_elapsed[FILENAME] = 1
            s = $0
            sub(/.*Elapsed: /, "", s)
            sub(/ .*/, "", s)
            if (s != "") elapsed[FILENAME] = s
        }
        END {
            for (f in files) {
                printf "%s\t%s\t%s\n", f, bucket(f), elapsed[f]
            }
        }
    ' 2>/dev/null
}

# Scan with a rule-fingerprint + size/mtime/ctime cache (./.internal/scan_cache.tsv). Terminal
# buckets (skip/pass/fail/inc) whose stat matches the cache are emitted from
# the cache without reopening the log; everything else (new, changed, or
# non-terminal run files) is scanned and the cache is rewritten. Plain TSV in
# the regression dir; flock serializes readers/writers and atomic replacement.
# The generated library SHA-256 rejects entries an older classifier wrote. Stat keys
# retain full subsecond mtime and ctime to detect same-second same-size rewrites;
# detection remains limited by the filesystem's timestamp resolution.
# Output format is identical to jobs_gen_scan_logs.
jobs_gen_scan_logs_cached() (
    local list="$1"
    local cache=./.internal/scan_cache.tsv
    mkdir -p ./.internal
    exec 9>./.internal/scan_cache.lock
    flock -x 9
    touch "$cache"
    local rules
    rules=$(sha256sum "${BASH_SOURCE[0]}")
    local stats cached todo fresh
    stats=$(mktemp)
    cached=$(mktemp)
    todo=$(mktemp)
    fresh=$(mktemp)
    # "path<TAB>size|mtime|ctime" per listed log (one stat pass). $'...' makes
    # the shell expand \t to a real tab — stat(1) may leave it literal, which
    # would corrupt paths for the -F'\t' consumers below. Tab keeps filenames
    # with spaces in one field.
    LC_ALL=C xargs -d '\n' -a "$list" -r stat -c $'%n\t%s|%y|%z' >"$stats" 2>/dev/null || true
    # Partition listed files: cache hit (stat match + terminal bucket) vs scan
    awk -F'\t' -v rules="$rules" -v cache="$cache" -v cached="$cached" -v todo="$todo" '
        BEGIN {
            while ((getline line < cache) > 0) {
                n = split(line, a, "\t")
                if (n == 5 && a[5] == rules) { cb[a[1]] = a[2]; cel[a[1]] = a[3]; cms[a[1]] = a[4] }
            }
            close(cache)
        }
        {
            path = $1; ms = $2
            if (path in cb && cms[path] == ms &&
                (cb[path] == "skip" || cb[path] == "pass" || cb[path] == "fail" || cb[path] == "inc"))
                print path "\t" cb[path] "\t" cel[path] >> cached
            else
                print path >> todo
        }
    ' "$stats"
    # Scan only the misses; merge and rewrite the cache with fresh stats
    jobs_gen_scan_logs "$todo" >"$fresh"
    cat "$cached" "$fresh"
    awk -F'\t' -v rules="$rules" -v stats="$stats" '
        BEGIN {
            while ((getline line < stats) > 0) { split(line, b, "\t"); ms[b[1]] = b[2] }
            close(stats)
        }
        { print $0 "\t" (($1 in ms) ? ms[$1] : "") "\t" rules }
   ' "$cached" "$fresh" >"$cache.new"
    mv -f "$cache.new" "$cache"
    rm -f "$stats" "$cached" "$todo" "$fresh"
)

# Aggregate scan output ("path<TAB>bucket<TAB>elapsed") into counts.
# Usage: jobs_gen_scan_logs_cached <list> | jobs_gen_count_buckets
jobs_gen_count_buckets() {
    awk -F'\t' '
        $2 == "skip" { skip++ }
        $2 == "pass" { pass++ }
        $2 == "fail" { fail++ }
        $2 == "inc" { inc++ }
        $2 == "run" { run++ }
        END { printf "%d %d %d %d %d\n", pass, skip, fail, inc, run }
    '
}

# List failed log paths from scan output (bucket == fail).
jobs_gen_failed_from_scan() {
    awk -F'\t' '$2 == "fail" { print $1 }'
}

# Build FILTER_PATTERN, an extended-regex alternation, from the comma-separated
# FILTER env var; `*` in a pattern matches any run of characters. Leaves
# FILTER_PATTERN empty when FILTER is unset, meaning no job is filtered out.
jobs_gen_build_filter_pattern() {
    FILTER="${FILTER:-}"
    FILTER_PATTERN=""
    if [ -n "$FILTER" ]; then
        IFS=',' read -ra _parts <<< "$FILTER"
        for _p in "${_parts[@]}"; do
            _e=$(printf '%s' "$_p" | sed 's/[.[\](){}+?^$|\\]/\\&/g; s/\*/.\*/g')
            FILTER_PATTERN="${FILTER_PATTERN:+${FILTER_PATTERN}|}${_e}"
        done
    fi
}

# Classify every failed log against FILTER_PATTERN in one pass over the file list.
# Prints "1<TAB>path<TAB>match" for a log that matches and "0<TAB>path<TAB>"
# otherwise, so check_err.sh and collect_errors.sh share one matcher instead of
# carrying a copy each. An empty FILTER_PATTERN marks every path unmatched, which
# is the no-filter case.
# Usage: jobs_gen_filter_classify <failed-list> [pattern]
jobs_gen_filter_classify() {
    local _list="$1"
    local _pattern="${2:-}"
    if [ ! -s "$_list" ]; then
        return 0
    fi
    if [ -z "$_pattern" ]; then
        while IFS= read -r _path; do
            [ -z "$_path" ] && continue
            printf '0\t%s\t\n' "$_path"
        done < "$_list"
        return 0
    fi
    xargs -d '\n' -a "$_list" -r awk -v fpat="$_pattern" '
        FNR == 1 { file = FILENAME; fmatch[file] = "" }
        fmatch[file] == "" {
            if (match(tolower($0), tolower(fpat))) {
                fmatch[file] = substr($0, RSTART, RLENGTH)
            }
        }
        END {
            for (f in fmatch) {
                if (fmatch[f] != "") printf "1\t%s\t%s\n", f, fmatch[f]
                else printf "0\t%s\t\n", f
            }
        }
    ' 2>/dev/null
}
]=])

    -- Write jobs.sh: one supervised simulation command per line, trailing LF.
    -- Append mode keeps the existing bytes and adds the new rows after them.
    local jobs_text = join_lines_with_trailing_lf(jobs_rows)
    local manifest_text = join_lines_with_trailing_lf(manifest_rows)
    if append then
        jobs_text = existing_jobs_text .. jobs_text
        manifest_text = existing_manifest_text .. manifest_text
    end
    write_file(path.join(outdir, "jobs.sh"), jobs_text)
    write_file(path.join(outdir, "manifest.txt"), manifest_text)

    -- Write run.sh: runs jobs.sh with configurable parallelism
    write_file(path.join(outdir, "run.sh"), [[#!/usr/bin/env bash
# Run generated regression jobs with xargs.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

parallel_jobs=1

usage() {
    echo "Usage: $0 [-j parallel-jobs]"
}

while getopts ":j:h" opt; do
    case "$opt" in
        j)
            parallel_jobs="$OPTARG"
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            echo "Unknown option: -$OPTARG" >&2
            usage >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 0 ]; then
    echo "Unexpected arguments: $*" >&2
    usage >&2
    exit 1
fi

xargs -d '\n' -P "$parallel_jobs" -I{} bash -lc '{}' < "$SCRIPT_DIR/jobs.sh"]])

    -- Snapshot the generation-time environment into OUTDIR/.internal/gen_env.sh so
    -- that regen.sh reproduces an invocation that carried ad-hoc variables
    -- (`XX=123 xmake r jobs-gen`) instead of silently dropping them. Default regen
    -- restores only the variables that are unset in its own environment (a value
    -- exported by the caller's shell wins); STRICT=1 replays the snapshot as the
    -- whole environment instead.
    local gen_env_path = path.join(internal_dir, "gen_env.sh")

    --- Write gen_env_path: the generation-time environment, minus the names that must
    --- not be restored. Returns how many variables it restores and how many
    --- credential-shaped names it skipped.
    ---@return integer gen_env_count
    ---@return integer gen_env_skipped
    local function write_gen_env_snapshot()
        -- Never restored, grouped by reason:
        --   - process-local shell state: stale or meaningless in another process
        --   - live bash variables: the value is not a setting (re-reads change it)
        --   - read-only bash variables: exporting them fails
        --   - bash invocation state: only valid while that invocation runs
        --   - generator CLI variables: regen.sh passes them on its command line anyway
        --   - regen.sh control switches: must come from the caller, not from the snapshot
        local deny = {}
        for _, name in ipairs({
            -- process-local shell state
            "_",
            "PWD",
            "OLDPWD",
            "SHLVL",
            "PPID",
            -- live bash variables
            "LINENO",
            "RANDOM",
            "SECONDS",
            "HISTCMD",
            "EPOCHREALTIME",
            "EPOCHSECONDS",
            -- read-only bash variables
            "BASHOPTS",
            "SHELLOPTS",
            -- bash invocation state
            "BASH_EXECUTION_STRING",
            "BASH_ARGC",
            "BASH_ARGV",
            "FUNCNAME",
            "GROUPS",
            "DIRSTACK",
            -- generator CLI variables
            "JOBS",
            "SEED_MAX",
            "TC",
            "TARGET",
            "OUTDIR",
            "FORCE_SUCCESS",
            -- APPEND is a generator CLI variable too: regen.sh replays the total
            -- job count on its command line, so replaying APPEND=1 from the
            -- snapshot would append the whole workspace a second time.
            "APPEND",
            -- regen.sh control switches
            "JOBS_GEN_REPLAY",
            "STRICT",
            "JOBS_GEN_ENV_FORCE",
        }) do
            deny[name] = true
        end

        -- Credential-shaped names are dropped as well: they are the developer's keys and
        -- endpoints, not regression configuration, and a regression directory gets copied
        -- around. Written as shell globs so the rule reads like the variable name.
        local deny_globs = {
            "*_API_KEY",
            "*_API_KEY_*",
            "*_API_BASE",
            "*_SECRET",
        }
        local deny_patterns = {}
        for _, glob in ipairs(deny_globs) do
            -- Escape Lua magic characters, then let `*` match any run of characters.
            local pattern = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*")
            table.insert(deny_patterns, "^" .. pattern .. "$")
        end

        local function matches_deny_globs(name)
            for _, pattern in ipairs(deny_patterns) do
                if name:match(pattern) then
                    return true
                end
            end
            return false
        end

        local envs = os.getenvs()
        local names = {}
        local skipped_count = 0
        for name, value in pairs(envs) do
            if not deny[name] and name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
                if matches_deny_globs(name) then
                    skipped_count = skipped_count + 1
                else
                    table.insert(names, name)
                end
            end
        end
        table.sort(names)

        local rows = {
            "#!/usr/bin/env bash",
            "# Environment snapshot captured when jobs-gen ran.",
            "# regen.sh sources this file so ad-hoc variables (e.g. `XX=123 xmake r jobs-gen`)",
            "# survive regeneration. Only variables unset in the caller's environment are",
            "# restored; everything else keeps its current value.",
            "# regen.sh run with STRICT=1 replays this file as the complete environment.",
            "# Credential-shaped names (*_API_KEY, *_API_KEY_*, *_API_BASE, *_SECRET) are",
            "# excluded, but the rest still mirrors the generating shell, so other secrets",
            "# can be present: keep this file readable by its owner only.",
            "jobs_gen_env_restore() {",
            "    # Force mode overwrites existing values; used by the STRICT=1 replay.",
            "    if [ -n \"${JOBS_GEN_ENV_FORCE:-}\" ] || [ -z \"${!1+x}\" ]; then",
            "        export \"$1=$2\"",
            "    fi",
            "}",
        }
        for _, name in ipairs(names) do
            table.insert(rows, string.format("jobs_gen_env_restore %s %s", name, shell_quote(envs[name])))
        end
        table.insert(rows, "unset -f jobs_gen_env_restore")
        write_file(gen_env_path, table.concat(rows, "\n") .. "\n")
        os.execv("chmod", { "600", gen_env_path })
        return #names, skipped_count
    end

    local gen_env_count, gen_env_skipped = write_gen_env_snapshot()

    -- Append keeps the timestamp so the summarize/keep_watch elapsed clock stays comparable.
    if not append then
        write_file(path.join(internal_dir, "start_time"), tostring(os.time()))
    end

    -- Write clean.sh: removes logs and configs, kills processes holding residual files
    local clean_content = [[#!/usr/bin/env bash
# Clean up regression outputs: remove log and config files, then recreate empty directories.
# Retry residual regular files after killing their holders.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

HAS_FUSER=0
command -v fuser >/dev/null 2>&1 && HAS_FUSER=1

# force_clean_dir <dir> — rm -rf then verify empty; if residual files remain,
# use fuser on residual regular files and retry (up to 3 times).
force_clean_dir() {
    local dir="$1"
    local max_retries=3
    local i=0

    while [ $i -lt $max_retries ]; do
        rm -rf "$dir" 2>/dev/null
        # Check for residual files, such as NFS silly-renames.
        if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
            return 0
        fi
        echo "[clean] $dir still has residual files (attempt $((i+1))/$max_retries)"
        # Only target residual regular files, including those in nested directories.
        # Directory operands can kill shells using them as cwd, including the parent
        # directory matched by .* on older Bash versions.
        if [ $HAS_FUSER -eq 1 ]; then
            find "$dir" -type f -exec fuser -k -9 {} + 2>/dev/null || true
            sleep 2
        else
            sleep 2
        fi
        rm -rf "$dir" 2>/dev/null
        i=$((i+1))
    done

    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        echo "[clean] WARNING: $dir still has residual files after $max_retries retries, continuing anyway"
        ls -la "$dir"
    fi
}

force_clean_dir ./log
force_clean_dir ./cfg
mkdir -p ./log && mkdir -p ./cfg]]
    if config.extra_clean then
        assert(type(config.extra_clean) == "string", "[jobs-gen] config.extra_clean must be a string")
        clean_content = clean_content .. "\n" .. config.extra_clean
    end
    write_file(path.join(outdir, "clean.sh"), clean_content)

    -- The parameter block that regen.sh and clean-regen.sh print before a replay. Values go
    -- through `printf %b`, so a path holding a quote or a backslash survives intact.
    ---@param name string Parameter name, e.g. "JOBS"
    ---@param value string Value to print; may hold newlines
    ---@return string
    local function replay_env_row(name, value)
        return string.format([[printf '    %s=\033[32m%%b\033[0m\n' %s]], name, shell_quote_printf_b(value))
    end
    local replay_env_summary = table.concat({
        [[printf '\033[1m[jobs-gen]\033[0m Environment variables:\n']],
        replay_env_row("JOBS", tostring(total_jobs)),
        replay_env_row("SEED_MAX", tostring(seed_max)),
        replay_env_row("TC", tc or "(random)"),
        replay_env_row("OUTDIR", outdir),
        replay_env_row("TARGET", target),
        replay_env_row("FORCE_SUCCESS", force_success and "1" or "0"),
        string.format([[printf '    Env snapshot=\033[32m%%b\033[0m (%d vars, missing only)\n' %s]], gen_env_count,
            shell_quote_printf_b(gen_env_path)),
        [[echo ""]],
    }, "\n")

    -- `append_jobs.sh` freezes these parameters, so an append keeps this workspace's
    -- policy instead of whatever the appending shell exports.
    local frozen_env = {}
    if tc then
        table.insert(frozen_env, "TC=" .. shell_quote(tc))
    end
    if force_success then
        table.insert(frozen_env, "FORCE_SUCCESS=1")
    end
    local frozen_env_prefix = table.concat(frozen_env, " ")
    if frozen_env_prefix ~= "" then
        frozen_env_prefix = " " .. frozen_env_prefix
    end
    -- The batch records live in regen.sh itself: one comment row per generation,
    -- holding that batch's own parameters, so a workspace built by several appends
    -- replays into the same job count with the same per-batch parameters.
    local batch_params = string.format("JOBS=%d SEED_MAX=%d TARGET=%s%s%s", jobs, seed_max, shell_quote(target),
        frozen_env_prefix, append and " APPEND=1" or "")
    local previous_batches = append and recorded_batches() or {}
    local record_rows = {}
    -- A first recorded batch that is itself an append batch means the workspace has an
    -- unrecorded prefix: replaying it would append onto whatever is on disk instead of
    -- rebuilding, so the marker stays and regen.sh keeps refusing.
    local first_batch_is_append = previous_batches[1] ~= nil and previous_batches[1]:match(" APPEND=1$") ~= nil
    if append and (#previous_batches == 0 or first_batch_is_append) then
        table.insert(record_rows, "# unknown prefix: the first jobs of this workspace have no record")
    end
    for index, params in ipairs(previous_batches) do
        table.insert(record_rows, string.format("# batch %d: %s", index, params))
    end
    table.insert(record_rows, string.format("# batch %d: %s", #previous_batches + 1, batch_params))
    local record_block = table.concat(record_rows, "\n")

    -- Write regen.sh: carries the batch records and replays them in order
    local regen_script = string.format(
        [[#!/usr/bin/env bash
# Regenerate jobs: replays the batch records below, in order.
# Environment: .internal/gen_env.sh is the snapshot of the original invocation.
#   default  -> the snapshot fills the variables this shell lacks; values set here win.
#   STRICT=1 -> the snapshot IS the environment, so leftovers exported in this shell
#               (e.g. a stale VCS_XPROP) cannot leak into regeneration.
# The recorded batches override anything the snapshot provides.
#
# Every generation adds one record row here. To steer a batch, edit its
# parameters and run this script.
%s

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "${STRICT:-}" in
    ""|0) ;;
    *)
        if [ -f "$SCRIPT_DIR/.internal/gen_env.sh" ]; then
            echo -e "\033[1m[regen]\033[0m STRICT=${STRICT}: replaying the .internal/gen_env.sh environment only"
            exec env -i JOBS_GEN_ENV_FORCE=1 "$BASH" "$SCRIPT_DIR/regen.sh"
        fi
        echo "[regen] STRICT=${STRICT} ignored: $SCRIPT_DIR/.internal/gen_env.sh is missing" >&2
        ;;
esac
if [ -f "$SCRIPT_DIR/.internal/gen_env.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.internal/gen_env.sh"
fi

this_script="$SCRIPT_DIR/regen.sh"
unknown_prefix=$(grep -m1 '^# unknown prefix:' "$this_script")
if [ -n "$unknown_prefix" ]; then
    echo "[regen] cannot replay this workspace: $unknown_prefix" >&2
    echo "[regen] regenerate it from scratch instead; the earlier batches have no recorded parameters" >&2
    exit 1
fi

# Read every record before replaying: the first batch rewrites the workspace,
# including this script.
mapfile -t batch_list < <(sed -n 's/^# batch [0-9][0-9]*: //p' "$this_script")
if [ "${#batch_list[@]}" -eq 0 ]; then
    echo "[regen] $this_script records no batch; nothing to replay" >&2
    exit 1
fi
%s
batch_index=0
for batch in "${batch_list[@]}"; do
    batch_index=$((batch_index + 1))
    echo -e "\033[1m[regen]\033[0m batch ${batch_index}/${#batch_list[@]}: ${batch}"
    (cd %s && JOBS_GEN_REPLAY=1 eval "OUTDIR=\"\$SCRIPT_DIR\" ${batch} xmake run -P %s jobs-gen") || exit $?
done]],
        record_block,
        replay_env_summary,
        shell_quote(prj_dir),
        shell_quote(prj_dir)
    )

    -- While regen.sh replays its own records it sets JOBS_GEN_REPLAY=1, and this file
    -- stays untouched: that script drives the replay and holds the batch rows, so a
    -- rewrite during the loop would leave the executed copy and the file out of step.
    if not replay then
        replace_script(path.join(outdir, "regen.sh"), regen_script)
    end

    -- Write append_jobs.sh: add N jobs through APPEND=1, reusing the frozen
    -- parameters above so an appended batch keeps this workspace's parameters.
    -- OUTDIR resolves from the script location, so the regression directory can
    -- be moved or copied as a whole without breaking the script.
    replace_script(
        path.join(outdir, "append_jobs.sh"),
        string.format(
            [[#!/usr/bin/env bash
# Append jobs: add <count> more jobs to this regression workspace.
# Usage: ./append_jobs.sh <count>
# Environment: .internal/gen_env.sh is the snapshot of the generation that created
# this workspace and fills the variables the calling shell lacks. The frozen
# parameters below are passed on the command line and override anything else.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <count>" >&2
    echo "  count  number of additional jobs to append (positive integer)" >&2
    exit 2
fi
count=$1
case "$count" in
    "" | *[!0-9]*)
        echo "[append] invalid count, must be a positive integer: $count" >&2
        exit 2
        ;;
esac
if [ "$count" -eq 0 ]; then
    echo "[append] nothing to append: count is 0" >&2
    exit 2
fi

if [ -f "$SCRIPT_DIR/.internal/gen_env.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.internal/gen_env.sh"
fi

echo -e "\033[1m[append]\033[0m Appending ${count} jobs to ${SCRIPT_DIR}"
cd %s && JOBS="$count" APPEND=1 SEED_MAX=%d TARGET=%s OUTDIR="$SCRIPT_DIR"%s xmake run -P %s jobs-gen]],
            shell_quote(prj_dir),
            seed_max,
            shell_quote(target),
            frozen_env_prefix,
            shell_quote(prj_dir)
        )
    )

    -- Write clean-regen.sh: clean then regenerate
    write_file(
        path.join(outdir, "clean-regen.sh"),
        string.format(
            [[#!/usr/bin/env bash
# Clean all outputs and regenerate jobs from scratch.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

%s
bash "$SCRIPT_DIR/clean.sh" && bash "$SCRIPT_DIR/regen.sh" && clear && echo -e "\033[1m[clean-regen]\033[0m Regeneration finished."]],
            replay_env_summary
        )
    )

    -- Write keep_watch.sh: continuously monitor regression status (with color support)
    write_file(path.join(outdir, "keep_watch.sh"), [[#!/usr/bin/env bash
# Continuously monitor regression progress using watch.
# Refreshes every 0.5s with color support.
# Quote an absolute check_all.sh path into the watch command so concurrent
# watchers cannot pick up another directory via $SCRIPT_DIR or cwd.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK_ALL="$SCRIPT_DIR/check_all.sh"
printf -v WATCH_CMD 'FORCE_COLOR=1 bash %q' "$CHECK_ALL"
cd "$SCRIPT_DIR" || exit 1

watch --color -n 0.5 "$WATCH_CMD"]])

    -- Write summarize.sh: count current-generation job states from log files
    write_file(path.join(outdir, "summarize.sh"), [[#!/usr/bin/env bash
# Summarize regression results: count current-generation job states from log files.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.internal/jobs_lib.sh"

# Enable colors when running in terminal or when FORCE_COLOR is set
if [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN='' RED='' CYAN='' BOLD='' NC=''
fi

jobs_gen_load_manifest

total_success_job=0
total_skipped_job=0
total_failed_job=0
total_incomplete_job=0
total_running_job=0
total_pending_job=0
stale_jobs=0

if [ "$HAS_MANIFEST" -eq 1 ]; then
    total_jobs=${#MANIFEST_NAMES[@]}
    for _name in "${MANIFEST_NAMES[@]}"; do
        if [ ! -f "./log/$_name" ]; then
            total_pending_job=$((total_pending_job + 1))
        fi
    done
    stale_jobs=$(jobs_gen_count_stale)
else
    total_jobs=$(find ./log -maxdepth 1 -type f 2>/dev/null | wc -l)
fi

_scan_tmp=$(mktemp)
jobs_gen_scan_current_logs "$_scan_tmp"
read total_success_job total_skipped_job total_failed_job total_incomplete_job total_running_job < <(
    jobs_gen_count_buckets < "$_scan_tmp"
)
rm -f "$_scan_tmp"

total_finished=$((total_success_job + total_skipped_job + total_failed_job + total_incomplete_job))

total_ran=$((total_failed_job + total_success_job))
if [ "$total_ran" -gt 0 ]; then
    pass_rate=$(awk "BEGIN {printf \"%.1f\", $total_success_job / $total_ran * 100}")
else
    pass_rate="-"
fi

echo -e "${BOLD}==============================${NC}"
echo -e "${BOLD}  Regression Summary${NC}"
echo -e "${BOLD}==============================${NC}"
echo -e "  Total jobs:     ${CYAN}${total_jobs}${NC}"
if [ "$HAS_MANIFEST" -eq 1 ]; then
    echo -e "  Pending:        ${CYAN}${total_pending_job}${NC}"
fi
echo -e "  Running:        ${CYAN}${total_running_job}${NC}"
echo -e "  Finished:       ${CYAN}${total_finished}${NC}"
echo -e "  Success:        ${GREEN}${total_success_job}${NC}"
echo -e "  Skipped:        ${CYAN}${total_skipped_job}${NC}"
echo -e "  Failed:         ${RED}${total_failed_job}${NC}"
if [ "$HAS_MANIFEST" -eq 1 ]; then
    echo -e "  Incomplete:     ${CYAN}${total_incomplete_job}${NC}"
    echo -e "  Stale:          ${CYAN}${stale_jobs}${NC}"
fi
echo -e "  Pass rate:      ${GREEN}${pass_rate}%${NC}"

# Elapsed time since jobs were generated
if [ -f .internal/start_time ]; then
    start_ts=$(cat .internal/start_time)
    now_ts=$(date +%s)
    elapsed=$((now_ts - start_ts))
    hours=$((elapsed / 3600))
    minutes=$(( (elapsed % 3600) / 60 ))
    seconds=$((elapsed % 60))
    elapsed_str=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
    echo -e "  Elapsed:        ${CYAN}${elapsed_str}${NC}"
fi

echo -e "${BOLD}==============================${NC}"
]])
    -- Write check_err.sh: show error context from log files
    -- Supports FILTER env var: comma-separated patterns (with wildcard *) to filter out matching error logs.
    -- Uses single-pass awk for metadata extraction to minimize NFS I/O.
    write_file(path.join(outdir, "check_err.sh"), [[#!/usr/bin/env bash
# Check for errors: list failed jobs and show error context.
#
# Environment variables:
#   FILTER: Comma-separated patterns (supports wildcard *) to filter out error logs.
#           Example: FILTER="TIMEOUT,TASKBUF" bash check_err.sh
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.internal/jobs_lib.sh"

# Enable colors when running in terminal or when FORCE_COLOR is set
if [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
    RED='\033[0;31m' YELLOW='\033[0;33m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' YELLOW='' BOLD='' NC=''
fi

# Build filter pattern from FILTER env var
jobs_gen_build_filter_pattern

jobs_gen_load_manifest
# One scan classifies every log and yields the failed list plus the elapsed map
# directly; only the FILTER match check (if any) still touches the failed files
# themselves. A caller that already scanned the corpus (collect_errors.sh) passes
# the result in through JOBS_GEN_SCAN_FILE, so the logs are read once, not twice.
_scan_owned=0
_scan_tmp="${JOBS_GEN_SCAN_FILE:-}"
if [ -z "$_scan_tmp" ] || [ ! -s "$_scan_tmp" ]; then
    _scan_tmp=$(mktemp)
    _scan_owned=1
    jobs_gen_scan_current_logs "$_scan_tmp"
fi
_failed_tmp=$(mktemp)
jobs_gen_failed_from_scan < "$_scan_tmp" > "$_failed_tmp"
if [ ! -s "$_failed_tmp" ]; then
    rm -f "$_failed_tmp"
    if [ "$_scan_owned" -eq 1 ]; then
        rm -f "$_scan_tmp"
    fi
    echo -e "${BOLD}No errors found.${NC}"
    exit 0
fi

# Elapsed map from scan output (path<TAB>bucket<TAB>elapsed)
declare -A _elapsed_map
while IFS=$'\t' read -r _f _b _el; do
    [ -n "$_f" ] && _elapsed_map["$_f"]="$_el"
done < "$_scan_tmp"
if [ "$_scan_owned" -eq 1 ]; then
    rm -f "$_scan_tmp"
fi

# FILTER classification over failed files only (usually few): the shared helper
# yields the match text and the unfiltered/filtered partition in one pass.
declare -A _match_map
unfiltered="" filtered=""
_meta_tmp=$(mktemp)
jobs_gen_filter_classify "$_failed_tmp" "$FILTER_PATTERN" > "$_meta_tmp"
while IFS=$'\t' read -r _matched file fmatch; do
    [ -z "$file" ] && continue
    if [ "$_matched" = "1" ]; then
        _match_map["$file"]="$fmatch"
        filtered="${filtered:+${filtered}
}${file}"
    else
        unfiltered="${unfiltered:+${unfiltered}
}${file}"
    fi
done < "$_meta_tmp"
rm -f "$_meta_tmp" "$_failed_tmp"

# Print file list sorted by elapsed time using pre-built associative arrays
# Args: color file_list [show_match]
print_sorted_files() {
    local color="$1" list="$2" show_match="${3:-}"
    echo "$list" | while read -r f; do
        [ -z "$f" ] && continue
        local label="${f##*/}"
        local elapsed="${_elapsed_map[$f]:-}"
        [ -n "$elapsed" ] && label="$label  ($elapsed)"
        if [ -n "$show_match" ]; then
            local match="${_match_map[$f]:-}"
            [ -n "$match" ] && label="$label  [matched: $match]"
        fi
        printf '%s\t%s\n' "${elapsed:-00:00:00}" "$label"
    done | sort -t$'\t' -k1 | cut -f2 | while read -r line; do
        echo -e "  ${color}${line}${NC}"
    done
}

# Show unfiltered failed jobs
if [ -n "$unfiltered" ]; then
    echo -e "${BOLD}${RED}Failed jobs (sorted by elapsed time):${NC}"
    print_sorted_files "$RED" "$unfiltered"
elif [ -n "$filtered" ]; then
    echo -e "${BOLD}No unfiltered errors found.${NC}"
else
    echo -e "${BOLD}No errors found.${NC}"
fi

# Show filtered jobs
if [ -n "$filtered" ]; then
    filtered_count=$(echo "$filtered" | grep -c -v '^$')
    echo ""
    echo -e "${BOLD}${YELLOW}Filtered jobs (${filtered_count} filtered by: ${FILTER}):${NC}"
    print_sorted_files "$YELLOW" "$filtered" "1"
elif [ -n "$FILTER_PATTERN" ]; then
    echo ""
    echo -e "${BOLD}${YELLOW}Filter active (${FILTER}) but no jobs matched.${NC}"
fi

# Show error details — single bulk grep for unfiltered files only
if [ -n "$unfiltered" ]; then
    echo ""
    echo -e "${BOLD}Error details:${NC}"
    while IFS= read -r _failed_file; do
        [ -z "$_failed_file" ] && continue
        awk "$JOBS_GEN_AWK"'
            BEGIN { max_follow_lines = 12 }
            { lines[NR] = normalize($0) }
            failed(lines[NR]) {
                start = NR - 5; if (start < 1) start = 1
                for (i = start; i <= NR; i++)
                    if (i > printed) printf "%s:%d:%s\n", FILENAME, i, lines[i]
                printed = NR
                # A payload line can itself be a failure ("Error: ..."), so only a
                # payload marker re-arms the window. It then runs until a blank line
                # or the cap, so one marker cannot print the rest of the log.
                if (detail_follows(lines[NR])) follow_end = NR + max_follow_lines
            }
            follow_end && NR > printed && NR <= follow_end {
                if (lines[NR] == "") follow_end = 0
                else {
                    printf "%s:%d:%s\n", FILENAME, NR, lines[NR]
                    printed = NR
                }
            }
            { delete lines[NR - 5] }
        ' "$_failed_file"
    done <<< "$unfiltered"
fi]])
    -- Write collect_errors.sh: collect failed logs/configs and optionally archive them
    write_file(path.join(outdir, "collect_errors.sh"), [[#!/usr/bin/env bash
# Collect failed regression logs/configs into one directory and archive them.
#
# Usage: bash collect_errors.sh [-o output-dir] [-z tar.gz|zip|none]
#
# Environment variables:
#   FILTER: Comma-separated patterns (supports wildcard *) to filter out error logs.
#           Example: FILTER="TIMEOUT,TASKBUF" bash collect_errors.sh
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.internal/jobs_lib.sh"

error_dir="./errors"
archive_type="tar.gz"

usage() {
    echo "Usage: $0 [-o output-dir] [-z tar.gz|zip|none]"
}

while getopts ":o:z:h" opt; do
    case "$opt" in
        o)
            error_dir="$OPTARG"
            ;;
        z)
            archive_type="$OPTARG"
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            echo "Unknown option: -$OPTARG" >&2
            usage >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 0 ]; then
    echo "Unexpected arguments: $*" >&2
    usage >&2
    exit 1
fi

case "$archive_type" in
    tar.gz|zip|none) ;;
    *)
        echo "Invalid archive type: $archive_type" >&2
        usage >&2
        exit 1
        ;;
esac

if [ "$archive_type" = "zip" ] && ! command -v zip >/dev/null 2>&1; then
    echo "zip command not found; install zip or use -z tar.gz/-z none" >&2
    exit 1
fi

rm -rf "$error_dir"
mkdir -p "$error_dir/log" "$error_dir/cfg"

# Scan once and share the result: this script needs the failed list, check_err.sh
# needs the same scan for its report, and the logs usually live on a shared FS.
jobs_gen_load_manifest
_scan_tmp=$(mktemp)
jobs_gen_scan_current_logs "$_scan_tmp"

check_err_log="$error_dir/check_err.log"
if ! JOBS_GEN_SCAN_FILE="$_scan_tmp" bash "$SCRIPT_DIR/check_err.sh" > "$check_err_log" 2>&1; then
    echo "ERROR: failed to generate $check_err_log" >&2
    exit 1
fi

all_failed_files=$(mktemp)
jobs_gen_failed_from_scan < "$_scan_tmp" > "$all_failed_files"
rm -f "$_scan_tmp"
if [ ! -s "$all_failed_files" ]; then
    rm -f "$all_failed_files"
    echo "No errors found."
    exit 0
fi

jobs_gen_build_filter_pattern

# Failed logs from the scanner are already skip/pass-filtered; keep the ones the
# FILTER patterns did not match, using the same matcher as check_err.sh.
_meta_tmp=$(mktemp)
jobs_gen_filter_classify "$all_failed_files" "$FILTER_PATTERN" |
    awk -F'\t' '$1 == "0" { print $2 }' > "$_meta_tmp"
rm -f "$all_failed_files"

if [ ! -s "$_meta_tmp" ]; then
    rm -f "$_meta_tmp"
    echo "No unfiltered errors found."
    exit 0
fi

count=0
missing_cfg=0
while read -r log_file; do
    [ -z "$log_file" ] && continue
    log_base="${log_file##*/}"
    test_name="${log_base%.log}"
    cfg_file="./cfg/${test_name}.cfg"
    cp "$log_file" "$error_dir/log/"
    if [ -f "$cfg_file" ]; then
        cp "$cfg_file" "$error_dir/cfg/"
    else
        echo "WARNING: missing cfg for $log_file: $cfg_file" >&2
        missing_cfg=$((missing_cfg + 1))
    fi
    count=$((count + 1))
done < "$_meta_tmp"
rm -f "$_meta_tmp"

archive_base="${error_dir%/}"
case "$archive_type" in
    tar.gz)
        archive_path="${archive_base}.tar.gz"
        rm -f "$archive_path"
        tar -czf "$archive_path" "$error_dir"
        echo "Collected $count error logs into $error_dir and archived $archive_path."
        ;;
    zip)
        archive_path="${archive_base}.zip"
        rm -f "$archive_path"
        zip -qr "$archive_path" "$error_dir"
        echo "Collected $count error logs into $error_dir and archived $archive_path."
        ;;
    none)
        echo "Collected $count error logs into $error_dir."
        ;;
esac

if [ "$missing_cfg" -ne 0 ]; then
    echo "WARNING: $missing_cfg cfg files were missing." >&2
fi]])
    -- Write check_all.sh: summarize + check errors
    write_file(path.join(outdir, "check_all.sh"), [[#!/usr/bin/env bash
# Run full regression check: summarize results and show any errors.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

bash "$SCRIPT_DIR/summarize.sh"
echo ""
bash "$SCRIPT_DIR/check_err.sh"]])

    -- Write pack_regression.sh: packs this workspace into one self-extracting file.
    -- It is generated with the workspace, so a project needs only this module and runs
    -- `bash pack_regression.sh` next to jobs.sh.
    local packer_script = ([==[#!/usr/bin/env bash
# Pack this regression workspace into one self-extracting script.
#
# Usage:
#   bash pack_regression.sh [OUTDIR]
#   bash pack_regression.sh --version
#
# OUTDIR is a workspace built by `xmake r jobs-gen`; it defaults to the directory
# holding this script. Packing writes OUTDIR/regression-YYYYMMDD.sh, one file that
# restores the workspace byte for byte:
#
#   bash regression-20250102.sh            # restore beside the script into regression-20250102/
#   bash regression-20250102.sh -o DIR     # restore into DIR, created if missing
#   bash regression-20250102.sh -f -o DIR  # replace an existing workspace there
#
# Without -o the bundle creates regression-YYYYMMDD/ next to itself.
#
# Packed: jobs.sh, manifest.txt, the root-level *.sh, this packer, and the two
# .internal helpers. Not packed: log/ and cfg/ (per-run data), .internal/gen_env.sh
# (the generating shell's environment), and .internal/scan_cache.* (rebuilt on demand).
#
# The packer copies what is on disk, so it needs no xmake and never runs a simulation.
#
# Exit: 0 packed, 1 workspace missing or unreadable, 2 usage error.

set -u

# The jobs_gen that wrote this copy. A workspace keeps the packer it was generated
# with, so this line tells a stale copy from a current one.
GENERATOR_VERSION="__JOBS_GEN_VERSION__"

# Fixed whitelist: the user commands plus the data they act on. A missing entry means
# a broken workspace, so packing fails rather than shipping one whose scripts call
# files it lacks.
PACKED_FILES=(
    jobs.sh
    manifest.txt
    run.sh
    summarize.sh
    check_err.sh
    check_all.sh
    collect_errors.sh
    append_jobs.sh
    clean.sh
    regen.sh
    clean-regen.sh
    keep_watch.sh
    .internal/supervise_job.sh
    .internal/jobs_lib.sh
)

usage() {
    cat <<'USAGE'
Usage: pack_regression.sh [OUTDIR]

  OUTDIR  regression workspace to pack (default: the directory holding this script)
          Packing writes OUTDIR/regression-YYYYMMDD.sh.

Options:
  -h, --help     show this help
  --version      show the jobs_gen version behind this packer
USAGE
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --version)
        echo "pack_regression.sh (jobs_gen ${GENERATOR_VERSION})"
        exit 0
        ;;
esac

if [ "$#" -gt 1 ]; then
    echo "[pack] unexpected arguments: $*" >&2
    usage >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    workspace="$1"
else
    workspace="$(dirname -- "${BASH_SOURCE[0]}")"
fi

if [ ! -d "$workspace" ]; then
    echo "[pack] not a directory: $workspace" >&2
    exit 1
fi
workspace="$(CDPATH= cd -- "$workspace" && pwd)" || exit 1

packed_files=("${PACKED_FILES[@]}")
# A workspace generated by an earlier jobs_gen has no packer of its own.
if [ -f "$workspace/pack_regression.sh" ]; then
    packed_files+=(pack_regression.sh)
fi

missing=()
for name in "${PACKED_FILES[@]}"; do
    if [ ! -f "$workspace/$name" ]; then
        missing+=("$name")
    fi
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "[pack] $workspace is not a complete regression workspace; missing:" >&2
    printf '[pack]   %s\n' "${missing[@]}" >&2
    exit 1
fi

# Emit one file as a quoted heredoc. The delimiter must not occur as a line in the
# content it wraps. A file without a final newline, which older workspaces have, would
# swallow the closing delimiter line and truncate the bundle.
files_without_final_lf=()
emit_file() {
    local name="$1" file="$workspace/$name" delimiter
    delimiter="JOBS_GEN_PACK_${RANDOM}${RANDOM}"
    while grep -qxF -- "$delimiter" "$file"; do
        delimiter="JOBS_GEN_PACK_${RANDOM}${RANDOM}"
    done
    printf 'cat > "$outdir/%s" <<'\''%s'\''\n' "$name" "$delimiter"
    cat "$file"
    if [ -s "$file" ] &&
        [ "$(tail -c1 "$file" | od -An -tu1 | tr -d ' \n')" != "10" ]; then
        printf '\n'
        files_without_final_lf+=("$name")
    fi
    printf '%s\n' "$delimiter"
}

bundle_name="regression-$(date +%Y%m%d).sh"
restore_dir="${bundle_name%.sh}"
bundle_path="$workspace/$bundle_name"
tmp_bundle="$workspace/.$bundle_name.tmp"
job_count=$(wc -l < "$workspace/manifest.txt")
packed_at="$(date '+%Y-%m-%d %H:%M:%S')"

{
    cat <<BUNDLE_HEADER
#!/usr/bin/env bash
# $bundle_name -- self-extracting copy of a jobs-gen regression workspace.
#
# Packed at:   $packed_at
# Packer:      pack_regression.sh (jobs_gen $GENERATOR_VERSION)
# Jobs:        $job_count
#
# Files restored: ${packed_files[*]}
#
# Usage:
#   bash $bundle_name [-f] [-o DIR]
#     -o DIR  restore into DIR (default: $restore_dir/ next to this script)
#     -f      replace an existing workspace there; removes log/, cfg/, .internal/
#
# This script only writes files, into a directory of its own unless -o says otherwise.
# Start the run afterwards:
#   cd $restore_dir
#   bash run.sh -j 8
#
# Not restored: log/ and cfg/ (per-run data), .internal/gen_env.sh (the packing
# shell's environment), .internal/scan_cache.* (rebuilt on demand).
set -u

force=0
outdir=""

usage() {
    cat <<'USAGE'
Usage: $bundle_name [-f] [-o DIR]

  -o DIR  restore into DIR (default: $restore_dir/ next to this script)
  -f      replace an existing workspace there; removes log/, cfg/, .internal/
USAGE
}

while getopts ":o:fh" opt; do
    case "\$opt" in
        o) outdir="\$OPTARG" ;;
        f) force=1 ;;
        h) usage; exit 0 ;;
        \?) echo "Unknown option: -\$OPTARG" >&2; usage >&2; exit 2 ;;
        :) echo "Option -\$OPTARG requires an argument." >&2; usage >&2; exit 2 ;;
    esac
done
shift \$((OPTIND - 1))

if [ "\$#" -ne 0 ]; then
    echo "Unexpected arguments: \$*" >&2
    usage >&2
    exit 2
fi

if [ -z "\$outdir" ]; then
    bundle_dir="\$(CDPATH= cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
    outdir="\$bundle_dir/$restore_dir"
fi
mkdir -p "\$outdir" || exit 1
outdir="\$(CDPATH= cd -- "\$outdir" && pwd)" || exit 1

if [ -e "\$outdir/jobs.sh" ] && [ "\$force" -ne 1 ]; then
    echo "[pack] refusing to overwrite \$outdir/jobs.sh (use -f)" >&2
    exit 1
fi
if [ "\$force" -eq 1 ]; then
    echo "[pack] -f: removing \$outdir/{log,cfg,.internal}"
    rm -rf "\$outdir/log" "\$outdir/cfg" "\$outdir/.internal"
fi
mkdir -p "\$outdir/cfg" "\$outdir/log" "\$outdir/.internal" || exit 1
echo "[pack] restoring $job_count jobs into \$outdir"
BUNDLE_HEADER

    # One quoted heredoc per file; emit_file keeps the delimiters from colliding with
    # the content.
    for name in "${packed_files[@]}"; do
        emit_file "$name"
    done

    printf 'date +%%s > "$outdir/.internal/start_time"\n'
    printf 'chmod +x'
    for name in "${packed_files[@]}"; do
        # manifest.txt is data, not a command.
        [ "$name" = "manifest.txt" ] && continue
        printf ' "$outdir/%s"' "$name"
    done
    printf '\n'

    cat <<BUNDLE_FOOTER

echo "[pack] restored $job_count jobs into \$outdir"
echo "[pack] next: cd \$outdir && bash run.sh -j 8"
BUNDLE_FOOTER
} > "$tmp_bundle" || {
    echo "[pack] failed to write $tmp_bundle" >&2
    rm -f "$tmp_bundle"
    exit 1
}

# Any output here, warning or error, means the bundle is not a faithful copy: bash
# reports an unterminated heredoc as a warning and still exits 0.
syntax_report=$(bash -n "$tmp_bundle" 2>&1)
if [ -n "$syntax_report" ]; then
    echo "[pack] generated bundle is malformed, refusing to ship it:" >&2
    printf '%s\n' "$syntax_report" >&2
    rm -f "$tmp_bundle"
    exit 1
fi
mv -f "$tmp_bundle" "$bundle_path"
chmod +x "$bundle_path"

if [ "${#files_without_final_lf[@]}" -ne 0 ]; then
    echo "[pack] note: these files had no final newline and the restored copies gain one:" >&2
    printf '[pack]   %s\n' "${files_without_final_lf[@]}" >&2
fi

# A workspace from an older jobs_gen still carries absolute paths in jobs.sh, so its
# restore only runs in that one location.
# The quoted prefix is what rows and sources use; an unquoted occurrence such as
# COVDIR=/ws/cov.vdb inside a cfg payload does not restrict the location.
if grep -qF "'$workspace/" "$workspace/jobs.sh"; then
    echo "[pack] warning: jobs.sh still embeds absolute paths, so the restored workspace" >&2
    echo "[pack]          only runs at $workspace (regenerate it with jobs_gen >= 3.6.0)" >&2
fi

echo "[pack] packed $job_count jobs from $workspace"
echo "[pack] packer: pack_regression.sh (jobs_gen $GENERATOR_VERSION)"
echo "[pack] bundle: $bundle_path ($(wc -c < "$bundle_path") bytes)"
echo "[pack] restore: bash $bundle_name -o <dir>"
]==]):gsub("__JOBS_GEN_VERSION__", SCRIPT_VERSION)
    write_file(path.join(outdir, "pack_regression.sh"), packer_script)

    -- Print generation summary
    local default_marker = "${dim}(default)${clear}"
    local append_script_display = path.join(outdir, "append_jobs.sh")
    local append_script_note = "  (add N jobs: append_jobs.sh N)"

    --- One row of the generation summary. The name is padded to a fixed width here, so the
    --- values and their (default) markers line up whatever their length.
    ---@param name string
    ---@param value string
    ---@param is_default boolean
    ---@return string
    local function console_env_row(name, value, is_default)
        return string.format("        %-16s%s%s", name .. "=", value, is_default and ("  " .. default_marker) or "")
    end
    local console_env_rows = table.concat({
        console_env_row("JOBS", tostring(jobs), os.getenv("JOBS") == nil),
        console_env_row("SEED_MAX", tostring(seed_max), os.getenv("SEED_MAX") == nil),
        console_env_row("TC", tc or "(random)", os.getenv("TC") == nil),
        console_env_row("OUTDIR", outdir, os.getenv("OUTDIR") == nil),
        console_env_row("TARGET", target, os.getenv("TARGET") == nil),
        console_env_row("FORCE_SUCCESS", force_success and "1" or "0", os.getenv("FORCE_SUCCESS") == nil),
        console_env_row("APPEND", append and "yes" or "no", os.getenv("APPEND") == nil),
    }, "\n")

    cprint([[
[jobs-gen] Generate finished.
    Jobs file:
        ${green}%s${clear}
    Run script:
        ${green}%s${clear}
    Append jobs script:
        ${green}%s${clear}%s
    Collect errors script:
        ${green}%s${clear}
    Pack script:
        ${green}%s${clear}  (one-file copy: bash pack_regression.sh)
    Env snapshot:
        ${green}%s${clear}  (%d vars%s)
    Regression directory:
        ${green}%s${clear}
    Total jobs:
        ${green}%d${clear}
    TC:
        ${green}%s${clear}
    Target:
        ${green}%s${clear}
    Seed max:
        ${green}%d${clear}
    Force success:
        ${green}%s${clear}

    Environment variables:
%s
]], path.join(outdir, "jobs.sh"), path.join(outdir, "run.sh"), append_script_display, append_script_note,
        path.join(outdir, "collect_errors.sh"), path.join(outdir, "pack_regression.sh"), gen_env_path,
        gen_env_count, gen_env_skipped > 0 and string.format(", %d credential names skipped", gen_env_skipped) or "",
        outdir, total_jobs,
        tc or "randomly selected from {" .. table.concat(all_testcases, ",") .. "}", target,
        seed_max, force_success and "yes" or "no",
        console_env_rows
    )

    --- @type JobsGenContext
    local ctx = {
        prj_dir = prj_dir,
        tc_dir = config.tc_dir,
        outdir = outdir,
        target = target,
        tc = tc,
        jobs = jobs_emitted,
        seed_max = seed_max,
        all_testcases = all_testcases,
        all_targets = all_targets,
    }

    -- Invoke per-target post_gen callback with full context. Append keeps the
    -- existing coverage identity/collection artifacts instead of rewriting them.
    if target_config and target_config.post_gen and not append then
        target_config.post_gen(ctx)
    end

    local generated_scripts = os.files(path.join(outdir, "*.sh"))
    -- .internal/ sits one level below the root glob, so add its scripts explicitly.
    -- gen_env.sh stays out: it is sourced and keeps the owner-only mode written above.
    for _, name in ipairs({ "supervise_job.sh", "jobs_lib.sh" }) do
        table.insert(generated_scripts, path.join(internal_dir, name))
    end
    if #generated_scripts > 0 then
        os.execv("chmod", table.join({ "+x" }, generated_scripts))
    end
end

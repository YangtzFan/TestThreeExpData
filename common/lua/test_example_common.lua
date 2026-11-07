-- Shared helpers for Multi modules.

local M = {}

function M.test_success()
    -- Marker required by scripts/jobs_gen.lua summarize/check_err.
    print("=== test passed ===")
    io.flush()
end

---@param reason string | nil
function M.test_skipped(reason)
    if reason and reason ~= "" then
        print("[skip] " .. reason)
    end
    -- Marker required by scripts/jobs_gen.lua summarize/check_err.
    print("=== test skipped ===")
    io.flush()
end

return M

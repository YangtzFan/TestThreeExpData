-- ============================================================================
-- 模拟器 (Emulator) —— RV32I、RV32M 乘法、MAMUL 与 CSR 参考模型
-- ============================================================================
-- 支持 RV32I 37 条基础指令、4 条 RV32M 乘法指令、自定义 MAMUL 及 CSR。
-- 每次 commit_step 调用仅执行一条指令，
-- 返回该指令的提交记录，供 difftest 框架进行比对。
--
-- 本模块将以下功能整合为单一 class（由 pl.class 创建）：
--   状态管理   —— PC、通用寄存器（x0-x31）、指令/数据内存、步进指令计数
--   取指与译码 —— 从指令内存取出 32 位指令，解析字段和立即数
--   指令执行   —— 执行基础指令、乘法、矩阵乘法及 CSR 并生成提交记录
--   内存访问   —— Load/Store 操作（字节/半字/字，小端序）
-- ============================================================================

local class = require "pl.class"

local bit = require "bit"
local band, bor, bxor, lshift, rshift, arshift, tobit
    = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.arshift, bit.tobit
local assert = assert
local f = string.format

-- ============================================================================
-- 操作码与 CSR 常量定义
-- ============================================================================
local OP_LUI    = 0x37    -- U-type: 高位立即数加载（Load Upper Immediate）
local OP_AUIPC  = 0x17    -- U-type: PC 加高位立即数（Add Upper Immediate to PC）
local OP_JAL    = 0x6F    -- J-type: 跳转并链接（Jump And Link）
local OP_JALR   = 0x67    -- I-type: 寄存器间接跳转并链接
local OP_B      = 0x63    -- B-type: 条件分支（BEQ/BNE/BLT/BGE/BLTU/BGEU）
local OP_L      = 0x03    -- I-type: 从内存加载（LB/LH/LW/LBU/LHU）
local OP_S      = 0x23    -- S-type: 存储到内存（SB/SH/SW）
local OP_I      = 0x13    -- I-type: 立即数运算（ADDI/SLTI/ANDI/ORI/XORI/SLLI/SRLI/SRAI）
local OP_R      = 0x33    -- R-type: 寄存器间运算及 RV32M 乘法
local OP_FENCE  = 0x0F    -- FENCE/FENCEI：顺序单发射模型中无架构状态变化
local OP_SYSTEM = 0x73    -- SYSTEM: CSR 访问、ECALL、EBREAK、ERET、WFI
local OP_MAMUL  = 0x7F    -- MAMUL: x1-x6 与 x7-x21 矩阵相乘，结果写入 x22-x31
local NOP       = 0x00000013 -- ADDI x0, x0, 0
local DMEM_MASK = 0x3FFFF -- 地址空间使用 addr[17:0] 18 位（256KB），与硬件 DRAM 容量一致。

-- 与 mini.CSR 的 csrFile 保持相同的地址与别名。
local CSR_CYCLE, CSR_TIME, CSR_INSTRET = 0xC00, 0xC01, 0xC02
local CSR_CYCLEH, CSR_TIMEH, CSR_INSTRETH = 0xC80, 0xC81, 0xC82
local CSR_MSTATUS, CSR_MEPC, CSR_MCAUSE = 0x300, 0x341, 0x342
local CSR_FIXED = {
    [0xF00] = 0x00100100, -- mcpuid: RV32I + U
    [0xF01] = 0,          -- mimpid
    [0xF10] = 0,          -- mhartid
    [0x301] = 0x100,      -- mtvec
    [0x302] = 0,          -- mtdeleg
}
local CSR_ALIASES = {
    [0x900] = CSR_CYCLE, [0x901] = CSR_TIME, [0x902] = CSR_INSTRET,
    [0x980] = CSR_CYCLEH, [0x981] = CSR_TIMEH, [0x982] = CSR_INSTRETH,
    [0x701] = CSR_TIME, [0x741] = CSR_TIMEH, -- mtime/mtimeh 读同 time/timeh
}
local CSR_STATE_ADDRS = {
    CSR_CYCLE, CSR_TIME, CSR_INSTRET, CSR_CYCLEH, CSR_TIMEH, CSR_INSTRETH,
    CSR_MSTATUS, 0x304, 0x321, 0x340, CSR_MEPC, CSR_MCAUSE,
    0x343, 0x344, 0x780, 0x781,
}

--- 将有符号 32 位整数转换为无符号表示
---@param x integer 有符号 32 位整数
---@return integer 无符号 32 位值（0 ~ 4294967295）
local function to_u32(x)
    if x < 0 then return x + 0x100000000 end -- 2^32
    return x
end

-- 用 16 位分块计算无符号 32x32 乘积，避免 Lua number 的 53 位精度丢失低位。
---@param a integer
---@param b integer
---@return integer low 乘积的低 32 位
---@return integer high 乘积的高 32 位（有符号 32 位表示）
local function mul_u32(a, b)
    local ua, ub = to_u32(a), to_u32(b)
    local a_lo, a_hi = ua % 0x10000, math.floor(ua / 0x10000)
    local b_lo, b_hi = ub % 0x10000, math.floor(ub / 0x10000)
    local low_product = a_lo * b_lo
    local middle = a_hi * b_lo + a_lo * b_hi + math.floor(low_product / 0x10000)
    local low = low_product % 0x10000 + (middle % 0x10000) * 0x10000
    local high = (a_hi * b_hi + math.floor(middle / 0x10000)) % 0x100000000
    return tobit(low), tobit(high)
end

---@class (exact) test_riscv_mini.decode_entry
---@field inst   integer 保存原始指令，用于日志输出
---@field opcode integer
---@field rd     integer inst[11:7]
---@field funct3 integer inst[14:12]
---@field rs1    integer inst[19:15]
---@field rs2    integer inst[24:20]
---@field funct7 integer inst[31:25]
---@field imm    integer
---@field illegal boolean 是否为未定义的指令编码

---@class (exact) test_riscv_mini.commit_entry
---@field commit_index integer 从 1 开始的提交指令序号
---@field pc           integer 当前指令的 PC（无符号）
---@field reg_wen      boolean 是否写寄存器
---@field reg_waddr    integer 目的寄存器编号
---@field reg_wdata    integer 寄存器写入数据
---@field ram_wen      boolean 是否写数据内存
---@field ram_waddr    integer 内存写入地址
---@field ram_wdata    integer 内存写入数据
---@field ram_wmask    integer 内存写入掩码（0=字节, 1=半字, 2=字）
---@field matrix_wen   boolean MAMUL 是否写入矩阵结果寄存器
---@field matrix_wdata integer[] 结果按 x22-x31 顺序排列，共 10 个有符号 32 位值
---@field trap         boolean 是否触发异常
---@field trap_cause   integer 异常原因编码
---@field ecall        boolean 是否是 ECALL 指令

---@class test_riscv_mini.emu
---@field pc integer 程序计数器
---@field regs table<integer, integer> 32 个通用寄存器
---@field imem string 指令内存（二进制字节串）
---@field imem_size integer 指令内存大小（字节数）
---@field dmem table 数据内存（稀疏表）
---@field commit integer 已步进指令数
---@field csrs table<integer, integer> CSR 状态，使用规范地址保存别名寄存器
local emu = class() --[[@as test_riscv_mini.emu]]

-- ============================================================================
-- 初始化
-- ============================================================================
-- 加载指令二进制文件并初始化核心状态（PC、通用寄存器、CSR、内存）
---@param tc_name string 测试用例名称（旧 .bin）或 .hex/.bin 镜像路径
---@param options table? 其他需要传入的参数，可指定 pc
function emu:_init(tc_name, options)
    local src_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
    local prj_dir = src_dir:match("^(.*/)[^/]+/$") or "./"
    local module_dir = prj_dir:match("^(.*/)[^/]+/$") or "./"
    local image_path
    if tc_name:match("%.hex$") or tc_name:match("%.bin$") then
        if tc_name:sub(1, 1) == "/" then
            image_path = tc_name
        else
            local direct = io.open(tc_name, "rb")
            if direct then
                direct:close()
                image_path = tc_name
            else
                image_path = (os.getenv("RISCV_ENV_ROOT") or module_dir) .. "/" .. tc_name
            end
        end
    else
        for _, sub in ipairs({ "test_cases_basic/", "test_cases_regressive/" }) do
            local candidate = prj_dir .. sub .. tc_name .. ".bin"
            local fh = io.open(candidate, "rb")
            if fh then
                fh:close()
                image_path = candidate
                break
            end
        end
    end
    assert(image_path, "无法打开指令文件: " .. tc_name)
    local file = assert(io.open(image_path, "rb"), "无法打开指令文件: " .. image_path)
    if image_path:match("%.hex$") then
        local bytes = {}
        for line in file:lines() do
            line = line:gsub("%s+", "")
            assert(#line % 2 == 0 and line:match("^%x*$"), "无效的十六进制镜像行: " .. line)
            for i = #line, 2, -2 do
                bytes[#bytes + 1] = string.char(tonumber(line:sub(i - 1, i), 16))
            end
        end
        self.imem = table.concat(bytes)
    else
        self.imem = file:read("*a")
    end
    file:close()
    self.imem_size = #self.imem
    self.start_pc = options and options.pc or 0
    self:reset()
    print(f("[EMU] 模拟器初始化完成，加载测试用例: %s (%d 字节)", tc_name, self.imem_size))
end

-- ============================================================================
-- 寄存器读写访问
-- ============================================================================
---@param idx integer 寄存器编号 (0-31)
---@return integer 寄存器值（有符号 32 位）
function emu:read_reg(idx)
    if idx == 0 then return 0 end -- x0 始终返回 0（RISC-V 规范）
    return self.regs[idx]
end

---@param idx integer 寄存器编号 (0-31)
---@param value integer 写入值
function emu:write_reg(idx, value)
    if idx == 0 then return end -- 对 x0 的写入被静默忽略（RISC-V 规范）
    self.regs[idx] = tobit(value) -- 截断为有符号 32 位整数
end

-- ============================================================================
-- CSR 状态与读写
-- ============================================================================
function emu:reset_csrs()
    self.csrs = {}
    for _, addr in ipairs(CSR_STATE_ADDRS) do
        self.csrs[addr] = 0
    end
    self.csrs[CSR_MSTATUS] = 0x36 -- PRV=M、PRV1=M、IE/IE1=0
end

---@param addr integer CSR 地址
---@return boolean
function emu:has_csr(addr)
    if not self.csrs then self:reset_csrs() end
    return CSR_FIXED[addr] ~= nil or self.csrs[CSR_ALIASES[addr] or addr] ~= nil
end

---@param addr integer CSR 地址
---@return integer 旧 CSR 值（有符号 32 位）
function emu:read_csr(addr)
    assert(self:has_csr(addr), f("[EMU] 未知 CSR 地址 0x%03X", addr))
    return CSR_FIXED[addr] or self.csrs[CSR_ALIASES[addr] or addr]
end

-- 仅由合法 CSR 指令调用；权限与只读检查在 execute 中完成。
---@param addr integer CSR 地址
---@param value integer 待写入的 32 位值
function emu:write_csr(addr, value)
    assert(self:has_csr(addr), f("[EMU] 未知 CSR 地址 0x%03X", addr))
    if addr == 0x701 or addr == 0x741 then return end -- RTL 没有 mtime/mtimeh 写入分支

    local target = CSR_ALIASES[addr] or addr
    if target == CSR_MSTATUS then
        value = band(value, 0x3F) -- IE、PRV、IE1、PRV1
    elseif target == 0x304 or target == 0x344 then
        value = band(value, 0x88) -- mie/mip 只实现 MTI 与 MSI 位
    elseif target == CSR_MEPC then
        value = band(value, 0xFFFFFFFC)
    elseif target == CSR_MCAUSE then
        value = band(value, 0x8000000F)
    end
    self.csrs[target] = tobit(value)
end

---@param low_addr integer
---@param high_addr integer
---@param old_low integer
---@param written_addr integer? 当前指令写入的 CSR 地址
---@param low_alias integer 可写低位别名
---@param high_alias integer 可写高位别名
function emu:advance_counter(low_addr, high_addr, old_low, written_addr, low_alias, high_alias)
    if written_addr ~= low_alias then
        self.csrs[low_addr] = tobit(self.csrs[low_addr] + 1)
    end
    if old_low == -1 and written_addr ~= high_alias then
        self.csrs[high_addr] = tobit(self.csrs[high_addr] + 1)
    end
end

-- 补入两次提交之间额外经过的时钟周期；每次 execute 已自动推进一个周期。
---@param cycles integer 额外时钟周期数
function emu:advance_cycles(cycles)
    assert(cycles >= 0 and cycles == math.floor(cycles) and cycles < 0x100000000,
        "[EMU] cycles 必须是小于 2^32 的非负整数")
    if not self.csrs then self:reset_csrs() end
    for _, pair in ipairs({ { CSR_CYCLE, CSR_CYCLEH }, { CSR_TIME, CSR_TIMEH } }) do
        local low_addr, high_addr = pair[1], pair[2]
        local total = to_u32(self.csrs[low_addr]) + cycles
        self.csrs[low_addr] = tobit(total)
        self.csrs[high_addr] = tobit(self.csrs[high_addr] + math.floor(total / 0x100000000))
    end
end

---@param cause integer
---@param pc integer
---@return integer 异常入口 PC
function emu:raise_trap(cause, pc)
    local status = self.csrs[CSR_MSTATUS]
    local priv = band(rshift(status, 1), 3)
    local ie = band(status, 1)
    self.csrs[CSR_MEPC] = band(pc, 0xFFFFFFFC)
    self.csrs[CSR_MCAUSE] = cause
    self.csrs[CSR_MSTATUS] = bor(lshift(priv, 4), lshift(ie, 3), lshift(3, 1))
    return 0x100 + lshift(priv, 6) -- mtvec + (PRV << 6)
end

-- ============================================================================
-- 数据内存访问
-- ============================================================================
-- 数据内存采用稀疏 Lua 表存储，未写入的地址隐含值为 0。

-- 从数据内存读取单个字节（基础函数）使用稀疏表，未写入地址返回 0
---@param addr integer 字节地址
---@return integer 字节值（0-255）
function emu:raw_read(addr)
    return self.dmem[band(addr, DMEM_MASK)] or 0
end

-- 向数据内存写入单个字节（基础函数）存储值截断为 8 位
---@param addr integer 字节地址
---@param val integer 待写入值（仅使用低 8 位）
function emu:raw_write(addr, val)
    self.dmem[band(addr, DMEM_MASK)] = band(val, 0xFF)
end

-- ====== Load 操作（读取） ======

-- LB：读取字节，符号扩展至 32 位
---@param addr integer 字节地址
---@return integer 符号扩展后的 32 位值
function emu:read_byte_signed(addr)
    local b = self:raw_read(addr)
    if b >= 128 then return b - 256 end -- 如果 bit 7 为 1（值 >= 128），进行符号扩展
    return b
end

-- LBU：读取字节，零扩展至 32 位
---@param addr integer 字节地址
---@return integer 零扩展后的 32 位值（0-255）
function emu:read_byte_unsigned(addr)
    return self:raw_read(addr) -- 高位程序自动补 0
end

--- LH：读取半字（16 位小端序），符号扩展至 32 位
---@param addr integer 半字起始地址
---@return integer 符号扩展后的 32 位值
function emu:read_half_signed(addr)
    local lo = self:raw_read(addr)      -- 低字节
    local hi = self:raw_read(addr + 1)  -- 高字节
    local h = bor(lo, lshift(hi, 8))     -- 拼装为 16 位无符号值
    -- 如果 bit 15 为 1（值 >= 32768），进行符号扩展
    if h >= 32768 then return h - 65536 end
    return h
end

--- LHU：读取半字（16 位小端序），零扩展至 32 位
---@param addr integer 半字起始地址
---@return integer 零扩展后的 32 位值（0-65535）
function emu:read_half_unsigned(addr)
    local lo = self:raw_read(addr)
    local hi = self:raw_read(addr + 1)
    return bor(lo, lshift(hi, 8)) -- 高位程序自动补 0
end

--- LW：读取字（32 位小端序）
---@param addr integer 字起始地址
---@return integer 32 位有符号整数
function emu:read_word(addr)
    local b0 = self:raw_read(addr) -- 最低字节
    local b1 = self:raw_read(addr + 1)
    local b2 = self:raw_read(addr + 2)
    local b3 = self:raw_read(addr + 3) -- 最高字节
    return tobit(bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24)))
end

-- ====== Store 操作（写入） ======

-- SB：写入字节
---@param addr integer 字节地址
---@param val integer 待写入值（仅使用低 8 位）
function emu:write_byte(addr, val)
    self:raw_write(addr, val) -- 直接将 val 的最低 8 位写入 addr 处
end

-- SH：写入半字（16 位小端序）
-- 将 val 的低 16 位按小端序写入 addr 和 addr+1
---@param addr integer 半字起始地址
---@param val integer 待写入值（仅使用低 16 位）
function emu:write_half(addr, val)
    self:raw_write(addr, band(val, 0xFF)) -- 写入 val 的低 8 位作为低字节
    self:raw_write(addr + 1, band(rshift(val, 8), 0xFF)) -- 写入 val 的 9-16 位作为高字节
end

-- SW：写入字（32 位小端序）
---@param addr integer 字起始地址
---@param val integer 待写入的 32 位值
function emu:write_word(addr, val)
    self:raw_write(addr, band(val, 0xFF)) -- byte 0（最低字节）
    self:raw_write(addr + 1, band(rshift(val, 8), 0xFF)) -- byte 1
    self:raw_write(addr + 2, band(rshift(val, 16), 0xFF)) -- byte 2
    self:raw_write(addr + 3, band(rshift(val, 24), 0xFF)) -- byte 3（最高字节）
end

-- 重新开始同一镜像，不重新读取文件；由差分监视器跟随 DUT 复位调用。
function emu:reset()
    self.pc = self.start_pc
    self.regs = {} -- 32 个通用寄存器，初始化为 0
    for i = 0, 31 do
        self.regs[i] = 0
    end
    -- 数据内存：稀疏表，未写入的地址默认返回 0
    -- v18 修复（TD-INDIR-A）：把 .bin 字节同步铺到 dmem，使 .rodata / .data 段的数据 load 命中
    -- 背景：原实现 imem 与 dmem 物理分离，imem 装 .bin 而 dmem 启动空表，
    --       导致 -O0 编译产物中位于 .rodata 的函数指针表等只读数据被 lw 读出 0，
    --       indirect call 跳到 PC=0 进入架构性活循环（kernels_indirect_call_debug 超时根因）。
    -- 语义：与 RV32I 平坦内存模型一致，指令与数据共享同一段物理映像；
    --       超出 .bin 长度的地址仍回落到 raw_read 的 "or 0" 路径，行为不变。
    self.dmem = {}
    for i = 1, self.imem_size do
        self.dmem[i - 1] = self.imem:byte(i)
    end
    self.commit = 0 -- 已步进指令数
    self:reset_csrs()

end

-- ============================================================================
-- 取指
-- ============================================================================
-- 根据当前 PC [17:0] 读取 4 个字节，拼装为 32 位指令字（小端序）。
-- 超出镜像范围返回 0，随后由译码器按未识别指令断言报错。
---@return integer 32 位指令（有符号 32 位表示）
function emu:fetch()
    local pc = self.pc

    local effective_pc = band(pc, 0x3FFFC) -- 保留 PC[17:0]，低 2 位清空（4 字节对齐）
    -- 若超出二进制文件范围，返回全零（不是 NOP）。
    if effective_pc + 3 >= self.imem_size then
        return 0
    end

    -- 从小端序字节流中读取 32 位指令
    -- 注意：Lua 字符串索引从 1 开始，故 effective_pc 需要 +1
    local imem = self.imem
    local b0 = imem:byte(effective_pc + 1) -- 最低字节 inst[7:0]
    local b1 = imem:byte(effective_pc + 2) -- inst[15:8]
    local b2 = imem:byte(effective_pc + 3) -- inst[23:16]
    local b3 = imem:byte(effective_pc + 4) -- 最高字节 inst[31:24]

    return tobit(bor(b0, lshift(b1, 8), lshift(b2, 16), lshift(b3, 24)))
end

-- ============================================================================
-- 译码
-- ============================================================================
-- 识别 Instructions.scala 中定义的编码模式，避免非法 funct 字段误走合法分支。
---@param inst integer
---@param opcode integer
---@param funct3 integer
---@param funct7 integer
---@return boolean
local function is_recognized_instruction(inst, opcode, funct3, funct7)
    if opcode == OP_LUI or opcode == OP_AUIPC or opcode == OP_JAL or opcode == OP_MAMUL then
        return true
    elseif opcode == OP_JALR then
        return funct3 == 0
    elseif opcode == OP_B then
        return funct3 == 0 or funct3 == 1 or funct3 == 4 or funct3 == 5 or funct3 == 6 or funct3 == 7
    elseif opcode == OP_L then
        return funct3 == 0 or funct3 == 1 or funct3 == 2 or funct3 == 4 or funct3 == 5
    elseif opcode == OP_S then
        return funct3 == 0 or funct3 == 1 or funct3 == 2
    elseif opcode == OP_I then
        if funct3 == 1 then return funct7 == 0 end
        if funct3 == 5 then return funct7 == 0 or funct7 == 0x20 end
        return funct3 == 0 or funct3 == 2 or funct3 == 3 or funct3 == 4 or funct3 == 6 or funct3 == 7
    elseif opcode == OP_R then
        if funct7 == 0 then return true end
        if funct7 == 0x20 then return funct3 == 0 or funct3 == 5 end
        if funct7 == 0x01 then return funct3 <= 3 end
        return false
    elseif opcode == OP_FENCE then
        return band(inst, 0xF00FFFFF) == 0x0000000F or inst == 0x0000100F
    elseif opcode == OP_SYSTEM then
        if funct3 == 1 or funct3 == 2 or funct3 == 3 or
            funct3 == 5 or funct3 == 6 or funct3 == 7 then
            return true
        end
        return inst == 0x00000073 or inst == 0x00100073 or
            inst == 0x10000073 or inst == 0x10200073
    end
    return false
end

-- 对 32 位指令进行完整译码
-- 提取所有字段并生成五类立即数（I/S/B/U/J），覆盖基础指令及乘法扩展
---@param inst integer 32 位指令
---@return test_riscv_mini.decode_entry 译码结果表（包含 opcode、rd、rs1、rs2、funct3、funct7、各类立即数）
function emu:decode(inst)
    local opcode = band(inst, 0x7F) -- inst[6:0]
    local d = {
        inst = inst, -- 保存原始指令，用于日志输出
        -- 基础字段提取
        opcode = opcode,
        rd     = band(rshift(inst, 7), 0x1F), -- inst[11:7]
        funct3 = band(rshift(inst, 12), 0x07), -- inst[14:12]
        rs1    = band(rshift(inst, 15), 0x1F), -- inst[19:15]
        rs2    = band(rshift(inst, 20), 0x1F), -- inst[24:20]
        funct7 = band(rshift(inst, 25), 0x7F), -- inst[31:25]
        imm    = 0,
    } --[[@as test_riscv_mini.decode_entry]]

    d.illegal = not is_recognized_instruction(inst, opcode, d.funct3, d.funct7)

    -- 生成立即数
    if opcode == OP_LUI or opcode == OP_AUIPC then
        -- U 型立即数（用于 LUI/AUIPC）
        -- inst[31:12] 置于高 20 位，低 12 位为 0
        d.imm = tobit(band(inst, 0xFFFFF000))
    elseif opcode == OP_JALR or opcode == OP_L or opcode == OP_I then
        -- I 型立即数（用于 S-type/L-type/JALR）
        d.imm = arshift(inst, 20) -- inst[31:20] 符号扩展至 32 位
    elseif opcode == OP_S then
        -- S 型立即数（用于 SB/SH/SW）
        d.imm = bor(d.rd, lshift(d.funct7, 5))-- 由 inst[31:25] 和 inst[11:7] 拼装
        if band(d.imm, 0x800) ~= 0 then
            d.imm = tobit(bor(d.imm, 0xFFFFF000)) -- 从 bit 11（即 inst[31]）符号扩展至 32 位
        end
    elseif opcode == OP_B then
        -- B 型立即数（用于 BEQ/BNE/BLT/BGE/BLTU/BGEU）
        -- inst[31]、inst[30:25]、inst[11:8]、inst[7]拼装，imm[0] 始终为 0（半字对齐）
        local b_11   = band(rshift(inst, 7), 1)      -- inst[7]     → imm[11]
        local b_4_1  = band(rshift(inst, 8), 0xF)    -- inst[11:8]  → imm[4:1]
        local b_10_5 = band(rshift(inst, 25), 0x3F)  -- inst[30:25] → imm[10:5]
        local b_12   = rshift(inst, 31) -- inst[31]    → imm[12]（逻辑右移取最高位）
        d.imm = bor(
            lshift(b_4_1, 1),    -- imm[4:1]  置于 bit 1-4
            lshift(b_10_5, 5),   -- imm[10:5] 置于 bit 5-10
            lshift(b_11, 11),    -- imm[11]   置于 bit 11
            lshift(b_12, 12)     -- imm[12]   置于 bit 12
        )
        if b_12 == 1 then -- 从 bit 12 符号扩展至 32 位
            d.imm = tobit(bor(d.imm, 0xFFFFE000))
        end
    elseif opcode == OP_JAL then
        -- J 型立即数（用于 JAL）
        -- inst[31]、inst[30:21]、inst[20]、inst[19:12] 拼装，imm[0] 始终为 0（半字对齐）
        local j_19_12 = band(rshift(inst, 12), 0xFF)    -- inst[19:12] → imm[19:12]
        local j_11    = band(rshift(inst, 20), 1)        -- inst[20]    → imm[11]
        local j_10_1  = band(rshift(inst, 21), 0x3FF)   -- inst[30:21] → imm[10:1]
        local j_20    = rshift(inst, 31)                 -- inst[31]    → imm[20]
        d.imm = bor(
            lshift(j_10_1, 1),    -- imm[10:1]  置于 bit 1-10
            lshift(j_11, 11),     -- imm[11]    置于 bit 11
            lshift(j_19_12, 12),  -- imm[19:12] 置于 bit 12-19
            lshift(j_20, 20)      -- imm[20]    置于 bit 20
        )
        -- 从 bit 20 符号扩展至 32 位
        if j_20 == 1 then
            d.imm = tobit(bor(d.imm, 0xFFE00000))
        end
    elseif opcode == OP_R or opcode == OP_SYSTEM or opcode == OP_FENCE or opcode == OP_MAMUL then
        d.imm = 0
    end

    return d
end

-- ============================================================================
-- 指令执行
-- ============================================================================
-- 执行一条指令并生成提交记录，根据译码结果更新模拟机架构状态，返回提交信息供 difftest 比对使用
---@param d test_riscv_mini.decode_entry 译码结果（由 decode 方法生成）
---@return test_riscv_mini.commit_entry commit 提交记录
function emu:execute(d)
    if not self.csrs then self:reset_csrs() end
    local pc     = self.pc
    local opcode = d.opcode
    local rd     = d.rd
    local rs1    = d.rs1
    local rs2    = d.rs2
    local funct3 = d.funct3
    local funct7 = d.funct7

    -- 读取源寄存器值
    local rs1_val = self:read_reg(rs1)
    local rs2_val = self:read_reg(rs2)
    local old_cycle = self.csrs[CSR_CYCLE]
    local old_time = self.csrs[CSR_TIME]
    local old_instret = self.csrs[CSR_INSTRET]

    -- 提交记录：默认值
    local commit = {
        commit_index = self.commit, -- 当前提交指令序数
        pc           = pc,          -- 当前指令的 PC（无符号）
        reg_wen      = false,       -- 是否写寄存器
        reg_waddr    = 0,           -- 目的寄存器编号
        reg_wdata    = 0,           -- 寄存器写入数据
        ram_wen      = false,       -- 是否写数据内存
        ram_waddr    = 0,           -- 内存写入地址
        ram_wdata    = 0,           -- 内存写入数据
        ram_wmask    = 0,           -- 内存写入掩码（0=字节, 1=半字, 2=字）
        matrix_wen   = false,       -- 是否写入 x22-x31
        matrix_wdata = {},          -- 矩阵结果，索引 1-10 对应 x22-x31
        trap         = false,       -- 是否触发异常
        trap_cause   = 0,           -- 异常原因
        ecall        = false        -- 是否是 ECALL 指令
    } --[[@as test_riscv_mini.commit_entry]]

    local next_pc = to_u32(tobit(pc + 4)) -- 下一条 PC 默认 +4（分支指令则自行更新）
    local rd_val   = 0 -- 目的寄存器写入值（默认为 0，等待后续程序更新）
    local write_rd = false -- 指令类型是否需要写寄存器（默认不写入，等待后续程序更新）
    local written_csr -- 当前指令实际写入的 CSR，用于计数器写入优先级
    local trap_cause  -- 非 nil 时在指令末尾更新陷入状态
    local trap_badaddr

    -- ================================================================
    -- 指令分发与执行
    -- ================================================================
    if d.illegal then
        trap_cause = 2 -- 非法指令交由架构异常处理，而不是终止模拟器。
    elseif d.inst == NOP then
        -- NOP：只推进 PC，不产生寄存器或内存写入。
    elseif opcode == OP_LUI then
        -- LUI：将 U 型立即数加载到目的寄存器高 20 位
        rd_val   = d.imm
        write_rd = true
    elseif opcode == OP_AUIPC then
        -- AUIPC：将 U 型立即数加上当前 PC，结果写入目的寄存器
        rd_val   = tobit(pc + d.imm)
        write_rd = true
    elseif opcode == OP_JAL then
        -- JAL：跳转到 PC + J 型立即数偏移，链接地址（PC+4）写入 rd
        rd_val   = tobit(pc + 4)   -- 链接地址（返回地址）
        write_rd = true
        next_pc  = to_u32(tobit(pc + d.imm))
        if band(next_pc, 2) ~= 0 then
            trap_cause, trap_badaddr = 0, next_pc
        end
    elseif opcode == OP_JALR then
        -- JALR：跳转到 (rs1 + I 型立即数) & ~1，链接地址写入 rd
        rd_val   = tobit(pc + 4)
        write_rd = true
        local target = tobit(rs1_val + d.imm)
        next_pc = to_u32(band(target, 0xFFFFFFFE))
        if band(target, 2) ~= 0 then
            trap_cause, trap_badaddr = 0, target
        end
    elseif opcode == OP_B then
        -- 条件分支：根据比较结果决定是否跳转到 PC + B 型偏移
        local taken = false
        if funct3 == 0 then         -- BEQ: 相等时跳转
            taken = (rs1_val == rs2_val)
        elseif funct3 == 1 then     -- BNE: 不等时跳转
            taken = (rs1_val ~= rs2_val)
        elseif funct3 == 4 then     -- BLT: 有符号小于时跳转
            taken = (rs1_val < rs2_val)
        elseif funct3 == 5 then     -- BGE: 有符号大于等于时跳转
            taken = (rs1_val >= rs2_val)
        elseif funct3 == 6 then     -- BLTU: 无符号小于时跳转
            taken = (to_u32(rs1_val) < to_u32(rs2_val))
        elseif funct3 == 7 then     -- BGEU: 无符号大于等于时跳转
            taken = (to_u32(rs1_val) >= to_u32(rs2_val))
        else
            assert(false, f("[EMU] 未知分支指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        if taken then
            next_pc = to_u32(tobit(pc + d.imm))
        end
        -- 分支指令不写寄存器（write_rd 保持 false）
    elseif opcode == OP_L then
        -- 从数据内存加载数据到目的寄存器
        local addr   = tobit(rs1_val + d.imm) -- 有效地址 = rs1 + I 型偏移
        if ((funct3 == 1 or funct3 == 5) and band(addr, 1) ~= 0) or
            (funct3 == 2 and band(addr, 3) ~= 0) then
            trap_cause, trap_badaddr = 4, addr
        end
        local loaded = 0
        if funct3 == 0 then         -- LB: 读取 1 字节，符号扩展
            loaded = self:read_byte_signed(addr)
        elseif funct3 == 1 then     -- LH: 读取 2 字节，符号扩展
            loaded = self:read_half_signed(addr)
        elseif funct3 == 2 then     -- LW: 读取 4 字节
            loaded = self:read_word(addr)
        elseif funct3 == 4 then     -- LBU: 读取 1 字节，零扩展
            loaded = self:read_byte_unsigned(addr)
        elseif funct3 == 5 then     -- LHU: 读取 2 字节，零扩展
            loaded = self:read_half_unsigned(addr)
        else
            assert(false, f("[EMU] 未知加载指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        rd_val   = loaded
        write_rd = true

    elseif opcode == OP_S then
        -- 将寄存器数据存储到数据内存
        local addr = tobit(rs1_val + d.imm) -- 有效地址 = rs1 + S 型偏移
        if (funct3 == 1 and band(addr, 1) ~= 0) or
            (funct3 == 2 and band(addr, 3) ~= 0) then
            trap_cause, trap_badaddr = 6, addr
        elseif funct3 == 0 then         -- SB: 写入 1 字节（rs2 的最低 8 位）
            self:write_byte(addr, rs2_val)
        elseif funct3 == 1 then     -- SH: 写入 2 字节（rs2 的最低 16 位）
            self:write_half(addr, rs2_val)
        elseif funct3 == 2 then     -- SW: 写入 4 字节（rs2 完整 32 位）
            self:write_word(addr, rs2_val)
        else
            assert(false, f("[EMU] 未知存储指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        -- 记录 RAM 写入信息，供提交记录使用
        if not trap_cause then
            commit.ram_wen   = true
            commit.ram_waddr = addr       -- 写入地址
            commit.ram_wdata = rs2_val    -- 写入数据（完整 rs2 值）
            commit.ram_wmask = funct3     -- 掩码编码与 funct3 一致（0=B, 1=H, 2=W）
        end
        -- 存储指令不写寄存器（write_rd 保持 false）

    elseif opcode == OP_I then
        -- 立即数运算指令
        local imm = d.imm
        if funct3 == 0 then         -- ADDI: rd = rs1 + imm
            rd_val = tobit(rs1_val + imm)
        elseif funct3 == 2 then     -- SLTI: rd = (rs1 < imm) ? 1 : 0 （有符号比较）
            rd_val = (rs1_val < imm) and 1 or 0
        elseif funct3 == 3 then     -- SLTIU: rd = (rs1 < imm) ? 1 : 0 （无符号比较）
            rd_val = (to_u32(rs1_val) < to_u32(imm)) and 1 or 0
        elseif funct3 == 4 then     -- XORI: rd = rs1 ^ imm
            rd_val = bxor(rs1_val, imm)
        elseif funct3 == 6 then     -- ORI: rd = rs1 | imm
            rd_val = bor(rs1_val, imm)
        elseif funct3 == 7 then     -- ANDI: rd = rs1 & imm
            rd_val = band(rs1_val, imm)
        elseif funct3 == 1 then     -- SLLI: rd = rs1 << shamt（逻辑左移）
            local shamt = band(imm, 0x1F) -- 移位量取低 5 位
            rd_val = lshift(rs1_val, shamt)
        elseif funct3 == 5 then     -- SRLI/SRAI: 根据 funct7 区分逻辑/算术右移
            local shamt = band(imm, 0x1F)
            if funct7 == 0x20 then  -- SRAI: 算术右移（保留符号位）
                rd_val = arshift(rs1_val, shamt)
            else                    -- SRLI: 逻辑右移（高位补 0）
                rd_val = rshift(rs1_val, shamt)
            end
        else
            assert(false, f("[EMU] 未知立即数运算指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        write_rd = true

    elseif opcode == OP_R then
        -- 寄存器间运算指令
        if funct7 == 0x01 then      -- RV32M: MUL/MULH/MULHSU/MULHU
            local low, high = mul_u32(rs1_val, rs2_val)
            -- 有符号乘法高位由无符号高位减去对应负操作数的另一操作数得到。
            if funct3 == 0 then
                rd_val = low
            elseif funct3 == 1 then
                rd_val = tobit(high
                    - (rs1_val < 0 and to_u32(rs2_val) or 0)
                    - (rs2_val < 0 and to_u32(rs1_val) or 0))
            elseif funct3 == 2 then
                rd_val = tobit(high - (rs1_val < 0 and to_u32(rs2_val) or 0))
            elseif funct3 == 3 then
                rd_val = high
            else
                assert(false, f("[EMU] 不支持的 RV32M 指令 funct3=%d, PC=0x%08X", funct3, pc))
            end
        elseif funct3 == 0 then
            if funct7 == 0x20 then  -- SUB: rd = rs1 - rs2
                rd_val = tobit(rs1_val - rs2_val)
            else                    -- ADD: rd = rs1 + rs2
                rd_val = tobit(rs1_val + rs2_val)
            end
        elseif funct3 == 1 then     -- SLL: rd = rs1 << rs2[4:0]（逻辑左移）
            rd_val = lshift(rs1_val, band(rs2_val, 0x1F))
        elseif funct3 == 2 then     -- SLT: rd = (rs1 < rs2) ? 1 : 0 （有符号比较）
            rd_val = (rs1_val < rs2_val) and 1 or 0
        elseif funct3 == 3 then     -- SLTU: rd = (rs1 < rs2) ? 1 : 0 （无符号比较）
            rd_val = (to_u32(rs1_val) < to_u32(rs2_val)) and 1 or 0
        elseif funct3 == 4 then     -- XOR: rd = rs1 ^ rs2
            rd_val = bxor(rs1_val, rs2_val)
        elseif funct3 == 5 then
            if funct7 == 0x20 then  -- SRA: rd = rs1 >> rs2[4:0]（算术右移）
                rd_val = arshift(rs1_val, band(rs2_val, 0x1F))
            else                    -- SRL: rd = rs1 >> rs2[4:0]（逻辑右移）
                rd_val = rshift(rs1_val, band(rs2_val, 0x1F))
            end
        elseif funct3 == 6 then     -- OR: rd = rs1 | rs2
            rd_val = bor(rs1_val, rs2_val)
        elseif funct3 == 7 then     -- AND: rd = rs1 & rs2
            rd_val = band(rs1_val, rs2_val)
        else
            assert(false, f("[EMU] 未知寄存器运算指令 funct3=%d, PC=0x%08X", funct3, pc))
        end
        write_rd = true

    elseif opcode == OP_MAMUL then
        -- 固定布局：A 为 x1-x6 (2x3)，B 为 x7-x21 (3x5)，C 为 x22-x31 (2x5)。
        -- 先计算全部结果，再一次性更新目的寄存器，匹配 RTL 的矩阵写回。
        local results = {}
        for i = 0, 1 do
            for j = 0, 4 do
                local sum = 0
                for k = 0, 2 do
                    local product = mul_u32(self:read_reg(1 + i * 3 + k),
                        self:read_reg(7 + k * 5 + j))
                    sum = tobit(sum + product)
                end
                results[i * 5 + j + 1] = sum
            end
        end
        for index = 1, 10 do
            self:write_reg(21 + index, results[index])
        end
        commit.matrix_wen = true
        commit.matrix_wdata = results

    elseif opcode == OP_FENCE then
        -- FENCE/FENCEI 在当前顺序执行参考模型中仅推进 PC。
    elseif opcode == OP_SYSTEM then
        if funct3 == 1 or funct3 == 2 or funct3 == 3 or
            funct3 == 5 or funct3 == 6 or funct3 == 7 then
            local addr = band(rshift(d.inst, 20), 0xFFF)
            local priv = band(rshift(self.csrs[CSR_MSTATUS], 1), 3)
            local required_priv = band(rshift(addr, 8), 3)
            local wen = funct3 == 1 or funct3 == 5 or rs1 ~= 0
            local read_only = band(rshift(addr, 10), 3) == 3 or addr == 0x301 or addr == 0x302

            if not self:has_csr(addr) or required_priv > priv or (wen and read_only) then
                trap_cause = 2 -- 非法指令
            else
                local old = self:read_csr(addr)
                local source = funct3 >= 5 and rs1 or rs1_val -- 立即数指令使用零扩展 zimm
                rd_val = old
                write_rd = true
                if wen then
                    local value = source
                    if funct3 == 2 or funct3 == 6 then
                        value = bor(old, source)
                    elseif funct3 == 3 or funct3 == 7 then
                        value = band(old, bit.bnot(source))
                    end
                    self:write_csr(addr, value)
                    written_csr = addr
                end
            end
        elseif d.inst == 0x00000073 then -- ECALL
            commit.ecall = true
            trap_cause = 8 + band(rshift(self.csrs[CSR_MSTATUS], 1), 3)
        elseif d.inst == 0x00100073 then -- EBREAK
            trap_cause = 3
        elseif d.inst == 0x10000073 then -- ERET
            local status = self.csrs[CSR_MSTATUS]
            local priv = band(rshift(status, 1), 3)
            if priv < 1 then
                trap_cause = 2
            else
                local prev_priv = band(rshift(status, 4), 3)
                local prev_ie = band(rshift(status, 3), 1)
                self.csrs[CSR_MSTATUS] = bor(lshift(prev_priv, 1), prev_ie, 0x08)
                next_pc = to_u32(self.csrs[CSR_MEPC])
            end
        elseif d.inst ~= 0x10200073 then -- WFI 在当前 RTL 中无副作用
            assert(false, f("[EMU] 未识别 SYSTEM 指令 0x%08X, PC=0x%08X", to_u32(d.inst), pc))
        end

    else
        assert(false, f("[EMU] 未识别指令 0x%08X, PC=0x%08X", to_u32(d.inst), pc))
    end

    if trap_cause then
        next_pc = self:raise_trap(trap_cause, pc)
        if trap_badaddr then self.csrs[0x343] = tobit(trap_badaddr) end
        commit.trap = true
        commit.trap_cause = trap_cause
        write_rd = false
    end

    if write_rd then
        self:write_reg(rd, rd_val) -- 写回寄存器， x0 写入自动忽略
        commit.reg_wen   = true
        commit.reg_waddr = rd
        commit.reg_wdata = tobit(rd_val)
    end

    -- RTL 的 cycle/time 每个时钟周期递增；指令级模拟器每步递增一次。
    -- 对 cyclew/timew/instretw 等显式写入，沿用 RTL 中 CSR 写入覆盖递增的优先级。
    self:advance_counter(CSR_CYCLE, CSR_CYCLEH, old_cycle, written_csr, 0x900, 0x980)
    self:advance_counter(CSR_TIME, CSR_TIMEH, old_time, written_csr, 0x901, 0x981)
    if d.inst ~= NOP and (not commit.trap or commit.ecall or d.inst == 0x00100073) then
        self:advance_counter(CSR_INSTRET, CSR_INSTRETH, old_instret, written_csr, 0x902, 0x982)
    end

    self.pc = next_pc -- 更新 PC
    return commit
end

-- ============================================================================
-- 主步进接口
-- ============================================================================
-- 每次调用仅执行一条指令，更新内部架构状态并返回该指令的提交记录。
---@nodiscard
---@return test_riscv_mini.commit_entry 该指令的提交记录
function emu:commit_step()
    self.commit = self.commit + 1       -- 递增步进指令计数
    local inst = self:fetch()           -- 第一步：取指
    local decoded = self:decode(inst)   -- 第二步：译码
    return self:execute(decoded)        -- 第三步：执行并返回提交记录
end

return emu

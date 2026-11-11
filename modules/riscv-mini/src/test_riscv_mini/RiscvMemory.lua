local RiscvMemory = {}
RiscvMemory.__index = RiscvMemory

local function signal(name)
    return dut[name]:chdl()
end

local function u32(value)
    return value % 0x100000000
end

local function read_word(memory, address)
    local value = 0
    for i = 0, 3 do
        value = value + (memory.bytes[(address + i) % memory.memory_size] or 0) * (2 ^ (8 * i))
    end
    return u32(value)
end

local function write_word(memory, address, value, strobe)
    for i = 0, 3 do
        if bit.band(strobe, bit.lshift(1, i)) ~= 0 then
            memory.bytes[(address + i) % memory.memory_size] = bit.band(bit.rshift(value, 8 * i), 0xff)
        end
    end
end

local function read_beat(memory, address)
    return { read_word(memory, address), read_word(memory, address + 4) }
end

---@param hex_path string
---@param memory_size integer
---@return test_riscv_mini.RiscvMemory
function RiscvMemory.new(hex_path, memory_size)
    local self = setmetatable({}, RiscvMemory)
    self.bytes = {}
    self.memory_size = memory_size
    self.clock = signal("clock")
    self.reset = signal("reset")

    self.ar_valid = signal("io_nasti_ar_valid")
    self.ar_ready = signal("io_nasti_ar_ready")
    self.ar_addr = signal("io_nasti_ar_bits_addr")
    self.ar_id = signal("io_nasti_ar_bits_id")
    self.ar_len = signal("io_nasti_ar_bits_len")
    self.ar_size = signal("io_nasti_ar_bits_size")

    self.r_valid = signal("io_nasti_r_valid")
    self.r_ready = signal("io_nasti_r_ready")
    self.r_id = signal("io_nasti_r_bits_id")
    self.r_data = signal("io_nasti_r_bits_data")
    self.r_last = signal("io_nasti_r_bits_last")
    self.r_resp = signal("io_nasti_r_bits_resp")

    self.aw_valid = signal("io_nasti_aw_valid")
    self.aw_ready = signal("io_nasti_aw_ready")
    self.aw_addr = signal("io_nasti_aw_bits_addr")
    self.aw_id = signal("io_nasti_aw_bits_id")
    self.aw_len = signal("io_nasti_aw_bits_len")
    self.aw_size = signal("io_nasti_aw_bits_size")

    self.w_valid = signal("io_nasti_w_valid")
    self.w_ready = signal("io_nasti_w_ready")
    self.w_data = signal("io_nasti_w_bits_data")
    self.w_strb = signal("io_nasti_w_bits_strb")
    self.w_last = signal("io_nasti_w_bits_last")

    self.b_valid = signal("io_nasti_b_valid")
    self.b_ready = signal("io_nasti_b_ready")
    self.b_id = signal("io_nasti_b_bits_id")
    self.b_resp = signal("io_nasti_b_bits_resp")

    local file = assert(io.open(hex_path, "r"), "cannot open hex image: " .. hex_path)
    local address = 0
    for line in file:lines() do
        line = line:gsub("%s+", "")
        for i = #line, 2, -2 do
            self.bytes[address] = tonumber(line:sub(i - 1, i), 16)
            address = address + 1
        end
    end
    file:close()

    self.read_queue = {}
    self.write_addr = 0
    self.write_size = 8
    self.write_beats = 0
    self.write_id = 0
    self.write_active = false

    self.r_valid:set_imm(0)
    self.r_id:set_imm(0)
    self.r_data:set_imm({ 0, 0 })
    self.r_last:set_imm(0)
    self.r_resp:set_imm(0)
    self.b_valid:set_imm(0)
    self.b_id:set_imm(0)
    self.b_resp:set_imm(0)
    self.ar_ready:set_imm(1)
    self.aw_ready:set_imm(1)
    self.w_ready:set_imm(1)
    return self
end

function RiscvMemory:reset_state()
    self.read_queue = {}
    self.write_active = false
    self.b_pending = nil
end

-- Sample handshakes at the rising edge; drive responses at the falling edge
-- so data and valid remain stable through the following sampling edge.
function RiscvMemory:run()
    while true do
        self.clock:posedge()
        if self.reset:get() ~= 0 then
            self:reset_state()
        else
            if self.r_valid:get() ~= 0 and self.r_ready:get() ~= 0 then
                table.remove(self.read_queue, 1)
            end
            if self.b_valid:get() ~= 0 and self.b_ready:get() ~= 0 then
                self.b_pending = nil
            end
            if self.ar_valid:get() ~= 0 and self.ar_ready:get() ~= 0 then
                local addr = self.ar_addr:get()
                local beats = self.ar_len:get() + 1
                for i = 0, beats - 1 do
                    table.insert(self.read_queue, {
                        id = self.ar_id:get(),
                        data = read_beat(self, addr + i * (2 ^ self.ar_size:get())),
                        last = i == beats - 1,
                    })
                end
            end

            if self.aw_valid:get() ~= 0 and self.aw_ready:get() ~= 0 then
                self.write_addr = self.aw_addr:get()
                self.write_id = self.aw_id:get()
                self.write_beats = self.aw_len:get() + 1
                self.write_size = 2 ^ self.aw_size:get()
                self.write_active = true
            end
            if self.w_valid:get() ~= 0 and self.w_ready:get() ~= 0 and self.write_active then
                local data = self.w_data:get(true)
                local strobe = self.w_strb:get()
                write_word(self, self.write_addr, data[1], strobe)
                write_word(self, self.write_addr + 4, data[2], bit.rshift(strobe, 4))
                self.write_addr = self.write_addr + self.write_size
                self.write_beats = self.write_beats - 1
                if self.write_beats == 0 then
                    self.write_active = false
                    self.b_pending = self.write_id
                end
            end
        end

        self.clock:negedge()
        local active = self.reset:get() == 0
        self.ar_ready:set_imm(active and #self.read_queue == 0 and 1 or 0)
        self.aw_ready:set_imm(active and not self.write_active and self.b_pending == nil and 1 or 0)
        self.w_ready:set_imm(active and self.write_active and 1 or 0)
        local item = active and self.read_queue[1] or nil
        self.r_valid:set_imm(item and 1 or 0)
        if item then
            self.r_id:set_imm(item.id)
            self.r_data:set_imm(item.data)
            self.r_last:set_imm(item.last and 1 or 0)
            self.r_resp:set_imm(0)
        end
        self.b_valid:set_imm(active and self.b_pending ~= nil and 1 or 0)
        if self.b_pending ~= nil then
            self.b_id:set_imm(self.b_pending)
            self.b_resp:set_imm(0)
        end
    end
end

return RiscvMemory

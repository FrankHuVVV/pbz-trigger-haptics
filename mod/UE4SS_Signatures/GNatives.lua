-- PBZ: build-agnostic GNatives resolver (2026-11-04)
-- The AOB pattern from build 26266538 still matches the updated exe, so instead of
-- pinning FunctionRVA / TableRVA / ImageSize / timestamp, derive the module base and
-- the dispatch table at runtime and validate them structurally.
--
-- EX_Max is 0xFF: 255 eight-byte entries.

local Pattern = "48 89 5C 24 20 56 57 41 56 48 83 EC 70 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 44 24 60 48 8B 42 20 4C 8D 35 ?? ?? ?? ?? 48 8B 72 10 49 8B F8 48 8B DA 80 38 04 74 40 48 8B D0 0F 1F 80 00 00 00 00 80 BB A1 00 00 00 00 48 8B C2 75 5C 0F B6 0A 48 8D 42 01 48 89 43 20 4C 8D 44 24 20 48 8B D3 4D 8B 0C CE 48 8B 4B 18 41 FF D1 48 8B 43 20 48 8B D0 80 38 04 75 CA 80 BB A1 00 00 00 00 75 29 48 FF C0 48 89 43 20 0F B6 08 48 FF C0 48 89 43 20 80 F9 0B 74 7F 4D 8B 0C CE 4C 8B C7 48 8B 4B 18 48 8B D3 41 FF D1 EB 6C"

local EntryCount = 0xFF

local function u32(address)
    local value = DerefToInt32(address)
    if value == nil then return nil end
    return value & 0xFFFFFFFF
end

local function rip(address, displacement_offset, next_offset)
    local displacement = DerefToInt32(address + displacement_offset)
    if displacement == nil then return nil end
    return address + next_offset + displacement
end

local function contains(ranges, address, span)
    for _, range in ipairs(ranges) do
        if address >= range[1] and address + span <= range[2] then return true end
    end
    return false
end

-- Walk down in 64 KB steps looking for a valid PE header.
local function find_module_base(address)
    local candidate = address & 0xFFFFFFFFFFFF0000
    for _ = 0, 16384 do
        local mz = u32(candidate)
        if mz ~= nil and (mz & 0xFFFF) == 0x5A4D then
            local nt_offset = u32(candidate + 0x3C)
            if nt_offset ~= nil and nt_offset >= 0x40 and nt_offset <= 0x1000 then
                local nt = candidate + nt_offset
                if u32(nt) == 0x4550 and (u32(nt + 4) & 0xFFFF) == 0x8664 then
                    return candidate
                end
            end
        end
        candidate = candidate - 0x10000
    end
    return nil
end

function Register()
    return Pattern
end

function OnMatchFound(address)
    local module_base = find_module_base(address)
    if module_base == nil then return nil end

    local nt_offset = u32(module_base + 0x3C)
    local nt = module_base + nt_offset
    local machine_sections = u32(nt + 4)
    local optional_size = u32(nt + 20)
    local count = machine_sections >> 16
    if count < 1 or count > 64 then return nil end

    local executable, writable = {}, {}
    local first_section = nt + 24 + (optional_size & 0xFFFF)
    for index = 0, count - 1 do
        local header = first_section + index * 40
        local size, start, flags = u32(header + 8), u32(header + 12), u32(header + 36)
        if size == nil or start == nil or flags == nil then return nil end
        local range = { module_base + start, module_base + start + size }
        if (flags & 0x20000000) ~= 0 and (flags & 0x40000000) ~= 0 then
            executable[#executable + 1] = range
        elseif (flags & 0xC0000000) == 0xC0000000 then
            writable[#writable + 1] = range
        end
    end
    if not contains(executable, address, 0xA8) then return nil end

    local native_table = rip(address, 0x23, 0x27)
    if native_table == nil or native_table % 8 ~= 0 then return nil end
    if not contains(writable, native_table, EntryCount * 8) then return nil end

    for index = 0, EntryCount - 1 do
        local slot = native_table + index * 8
        local low, high = u32(slot), u32(slot + 4)
        if low == nil or high == nil then return nil end
        local handler = (high << 32) | low
        if not contains(executable, handler, 1) then return nil end
    end

    print(string.format("[PBZ auto] GNatives resolved: 0x%X (base 0x%X, rva 0x%X, 255 entries)",
        native_table, module_base, native_table - module_base))
    return native_table
end

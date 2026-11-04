-- PBZ: build-agnostic GUObjectArray resolver (2026-11-04)
-- The AOB pattern from build 26266538 still matches the updated exe, so the module base,
-- the global and its RVAs are derived at runtime instead of being pinned to one build.

local Pattern = "48 89 5C 24 08 57 48 83 EC 20 48 C7 41 10 00 00 00 00 48 8D 05 ?? ?? ?? ?? 48 89 01 B8 FF FF FF FF 89 41 08 4C 8B D2 48 8B D9 45 84 C0 74 0F 8B 05 ?? ?? ?? ?? 89 41 08 8B 05 ?? ?? ?? ?? 44 8D 40 01 44 89 41 08 44 3B 05 ?? ?? ?? ?? 7D 3D 90 41 0F B7 C0 41 8B C8 48 C1 E9 10 48 8D 14 40 48 8B 05 ?? ?? ?? ?? 48 8B 0C C8 48 83 7C D1 08 00 48 8D 04 D1 75 12 41 FF C0 44 89 43 08 44 3B 05 ?? ?? ?? ?? 7C CA EB 04 48 89 43 10 4C 89 53 18 44 89 4B 20"

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

local function mapped_section(module_base, first_section, count, address, span, executable)
    local rva = address - module_base
    for index = 0, count - 1 do
        local header = first_section + index * 40
        local size, start, flags = u32(header + 8), u32(header + 12), u32(header + 36)
        if size ~= nil and start ~= nil and flags ~= nil and rva >= start and rva + span <= start + size then
            if executable then return (flags & 0x20000000) ~= 0 end
            return (flags & 0x80000000) ~= 0 and (flags & 0x20000000) == 0
        end
    end
    return false
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
    local first_section = nt + 24 + (optional_size & 0xFFFF)
    if not mapped_section(module_base, first_section, count, address, 148, true) then return nil end

    local global = rip(address, 21, 25)
    if global == nil or global % 8 ~= 0 then return nil end
    if not mapped_section(module_base, first_section, count, global, 0xE8, false) then return nil end

    print(string.format("[PBZ auto] GUObjectArray resolved: 0x%X (base 0x%X, rva 0x%X)",
        global, module_base, global - module_base))
    return global
end

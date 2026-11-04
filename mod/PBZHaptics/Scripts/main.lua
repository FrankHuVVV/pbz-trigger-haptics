-- PBZHaptics v9 - full haptics, no external process
--
-- Everything needed at runtime is loaded by the game itself:
--   * AkMotion.dll proxy   -> grip mirroring, gain, pump (loaded by Wwise)
--   * this Lua script      -> event pulses + combat flag, writes trigger.bin (loaded by UE4SS)
--
-- trigger.bin layout (16 bytes, little endian floats):
--   [0..3] lt   [4..7] rt   [8..11] combat   [12..15] out-of-combat gain
--
-- Tag -> channel: Deflect.* = left trigger, PerfectDodge = right trigger, others = both.

local LOG   = "D:\\PBZ_Xbox\\events.log"
local TRIG  = "D:\\PBZ_Xbox\\router\\trigger.bin"
local OUT_GAIN = 0.25     -- trigger strength outside combat (1.0 = as strong as the grips)
local TICK  = 10          -- ms per scheduler tick

local function log(tag, msg)
    local f = io.open(LOG, "a")
    if not f then return end
    f:write(string.format("%.3f", os.clock()) .. "\t" .. tag .. "\t" .. tostring(msg) .. "\n")
    f:close()
end

log("BOOT", "haptics v9 loaded")

-- ---------------------------------------------------------------- state
local combat = 0.0
local pulses = {}

local PROFILES = {
    { key = "Execution",       p = 1.00, h = 200, x = 200, side = "both" },
    { key = "PerfectDodge",    p = 0.90, h = 120, x = 120, side = "rt"   },
    { key = "PerfectDeflect",  p = 1.00, h = 150, x = 150, side = "lt"   },
    { key = "Deflect",         p = 1.00, h = 250, x = 150, side = "lt"   },
    { key = "Hit",             p = 0.80, h = 120, x = 100, side = "both" },
}

local function classify(tag)
    if tag:find("Execution.Finish", 1, true) then return "Execution" end
    if tag:find("PerfectDodge", 1, true) then return "PerfectDodge" end
    if tag:find("SpecialDeflect", 1, true) then return "PerfectDeflect" end
    if tag:find("ReceivedPerfectDeflect", 1, true) then return "PerfectDeflect" end
    if tag:find("Deflect", 1, true) and tag:find("Perfect", 1, true) then return "PerfectDeflect" end
    if tag:find("Deflect", 1, true) then return "Deflect" end
    if tag:find("Actor.Hit.Target", 1, true) then return "Hit" end
    return nil
end

local function pushPulse(kind)
    for _, p in ipairs(PROFILES) do
        if p.key == kind then
            if #pulses >= 8 then table.remove(pulses, 1) end
            pulses[#pulses + 1] = { age = 0, p = p.p, h = p.h, x = p.x, side = p.side }
            return
        end
    end
end

-- ------------------------------------------------------------ file channel
local tf = io.open(TRIG, "r+b")
if not tf then
    local c = io.open(TRIG, "wb")
    if c then c:write(string.rep("\0", 16)); c:close() end
    tf = io.open(TRIG, "r+b")
end
if tf then log("TRIG", "trigger.bin open") else log("TRIG", "trigger.bin FAILED") end

local function publish(lt, rt)
    if not tf then return end
    local ok = pcall(function()
        tf:seek("set", 0)
        tf:write(string.pack("<f f f f", lt, rt, combat, OUT_GAIN))
        tf:flush()
    end)
    if not ok then log("TRIG", "write failed") end
end

local function tick()
    local lt, rt = 0.0, 0.0
    for i = #pulses, 1, -1 do
        local q = pulses[i]
        q.age = q.age + TICK
        local v = 0.0
        if q.age < q.h then
            v = q.p
        elseif q.age < q.h + q.x then
            v = q.p * (1.0 - (q.age - q.h) / q.x)
        end
        if v > 0.0 then
            if q.side == "lt" then
                if v > lt then lt = v end
            elseif q.side == "rt" then
                if v > rt then rt = v end
            else
                if v > lt then lt = v end
                if v > rt then rt = v end
            end
        else
            table.remove(pulses, i)
        end
    end
    publish(lt, rt)
    return false
end

pcall(function() LoopAsync(TICK, tick) end)

-- ---------------------------------------------------------------- tag hook
local STRATS = {
    { "TagName",     function(p) return p.TagName:ToString() end },
    { "get.TagName", function(p) return p:get().TagName:ToString() end },
    { "get.ToString",function(p) return p:get():ToString() end },
}

local function extract(p)
    for _, s in ipairs(STRATS) do
        local ok, v = pcall(s[2], p)
        if ok and v ~= nil then
            local str = tostring(v)
            if #str > 0 then return str end
        end
    end
    return nil
end

local function looksLikeTag(v)
    local ok, res = pcall(function()
        local s = tostring(v)
        if s:find("/") or s:find(" ") then return false end
        if s:find("^ScriptStruct") or s:find("^BlueprintGeneratedClass") then return false end
        local _, dots = s:gsub("%.", "")
        return dots >= 1
    end)
    return ok and res or false
end

local calls, errs = 0, 0
local seen = {}

local function onEvent(...)
    calls = calls + 1
    if calls % 600 == 0 then log("ALIVE", "calls=" .. calls) end

    local n = select("#", ...)
    local args = { ... }

    local ok, err = pcall(function()
        for i = 1, n do
            local val = extract(args[i])
            if val and looksLikeTag(val) then
                if not seen[val] then
                    seen[val] = true
                    log("TAG", "arg" .. i .. " | " .. val)
                end
                if val:find("OffCombat", 1, true) then
                    combat = 0.0
                elseif val:find("InCombat", 1, true) then
                    combat = 1.0
                else
                    local kind = classify(val)
                    if kind then pushPulse(kind) end
                end
            end
        end
    end)
    if not ok and errs < 5 then
        errs = errs + 1
        log("ERR", "callback: " .. tostring(err))
    end
end

pcall(function()
    RegisterHook("/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:SendGameplayEventToActor", onEvent)
    log("REGISTER", "ok haptics v9")
end)

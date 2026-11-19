-- AlliedDefense / core.lua - Configuration, logging, helpers, player / monster lists, modes and phases, statistics.
-- Loaded by main.lua into the mod's shared environment: a top-level name set in any file
-- is visible to the files loaded after it (no "local" at file level: Lua caps a chunk at
-- 200 locals, which the single main.lua had reached).

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
okCfg, cfg = pcall(require, "config")
if not okCfg or type(cfg) ~= "table" then cfg = {} end
function default(k, v) if cfg[k] == nil then cfg[k] = v end end
default("enabled", true)
default("turretClassPath", "/Game/Blueprints/Monsters/SentryGun/BP_SentryGun.BP_SentryGun_C")
default("turretClass", "BP_SentryGun_C")
default("monsterBaseClass", "BP_ParentMonster_C")
default("playerBaseClass", "BP_ParentCharacter_C")
default("range", 3000)
default("monsterInitAgro", 30.0)
default("monsterAgroPerCall", 1.0)
default("wakeOnMonster", true)
default("wakeRetrySeconds", 5)
default("ignorePlayers", true)
default("targetMonsters", true)
default("forceDeploy", false)
default("ignoredMonsters", {})
default("targetOnlyWhen", { BP_Monster_Ghost_C = "IsFrozen" })
default("ghostFrozenOnGround", true)
default("friendSubstituteClasses", { "BP_BigRobot_C" })
default("blockPlayerWake", true)
default("playerWakeThreshold", 1000000.0)
default("playerAgroToNone", false)
default("hidePlayersFromSensor", true)
default("retargetToMonster", false)
default("targetUnlessTrue", { BP_Monster_Eye_C = "HaveShield" })
default("purgePotentialTargets", true)
default("allyFireColor", { R = 0.0, G = 1.0, B = 0.2, A = 1.0 })
-- v1.3.0: an old config.lua (<= 1.2.0) still holds the former blue default -> new green
do
    local c = cfg.allyFireColor
    if type(c) == "table" and c.R == 0.1 and c.G == 0.4 and c.B == 1.0 then
        cfg.allyFireColor = { R = 0.0, G = 1.0, B = 0.2, A = 1.0 }
    end
end
default("dumpMonsterClasses", false)
default("listRefreshSeconds", 0.5)
default("backgroundIntervalMs", 1000)
default("modifier", "CONTROL")
default("toggleKey", "F10")
default("verboseKey", "F11")
default("canisterKey", "F7")
default("shootCanisters", true)
default("canisterClass", "BP_HoldItem_ExplosiveCanister_Fire_C")
default("canisterTriggerRadius", 400)
default("canisterSafeRadius", 800)
default("canisterShotDamage", 2.0)
default("hostileShootCanisters", true)
default("verbose", false)
default("debugLogs", false)
default("mode", "phases")
default("modeKey", "F9")
default("defaultModeKey", "F8")
default("boardSettings", true)
default("modColours", true)
default("boardSectionTitle", true)
default("boardLanguage", "auto")
default("boardUpgrades", true)
default("resetUpgrades", false)
default("unstickTurrets", true)
default("stuckSeconds", 6)
default("modeCycle", { "phases", "ally", "chaos", "neutral", "vanilla" })
default("phasePerTurret", false)
default("phaseMinSeconds", 120)
default("phaseMaxSeconds", 300)
default("phaseStart", "random")
default("revealPhase", false)
default("chaosFireColor", { R = 0.6, G = 0.0, B = 1.0, A = 1.0 })
default("searchColor", { R = 1.0, G = 0.55, B = 0.0, A = 1.0 })
default("neutralColor", { R = 0.8, G = 0.8, B = 0.8, A = 1.0 })
default("inspectKey", "F6")
default("inspectCount", 4)
default("injectPotentialTargets", true)
default("injectMethod", "auto")
default("injectRadiusScale", 1.0)
default("injectRemoveScale", 1.25)
default("purgePlayersInBackground", false)
default("protectPlayersFromAllyFire", false)
default("dumpDamageFunctions", false)
-- v0.9.6: ONE damage hook only (ReceiveAnyDamage: simple parameters, gives the causer).
-- The 14 hooks of v0.9.1-0.9.5 (struct/class parameters, chain functions that proved
-- useless) are gone: fewer hooks = less risk inside UE4SS.
default("damageHookClasses", { "BP_ParentCharacter_C" })
default("damageHookFunctions", { "ReceiveAnyDamage" })
default("damageChainFunctions", {})
default("allyFireWindowSeconds", 0.3)
default("restoreHealthFromAllyFire", true)
default("trgDataClassPath", "/Game/Blueprints/Monsters/SentryGun/OBJ_SentryTrgData.OBJ_SentryTrgData_C")

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------
function modDir()
    local ok, info = pcall(debug.getinfo, modDir, "S")
    if ok and info and type(info.source) == "string" then
        local src = info.source:gsub("^@", "")
        local scripts = src:match("^(.*)[/\\][^/\\]+$")
        if scripts then return scripts:match("^(.*)[/\\][^/\\]+$") or scripts end
    end
    return "."
end

LOG_PATH = modDir() .. "\\AlliedDefense.log"
logFile = io.open(LOG_PATH, "w")

function log(fmt, ...)
    local msg
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        msg = ok and s or (tostring(fmt) .. " <format err>")
    else
        msg = tostring(fmt)
    end
    pcall(print, "[" .. MOD .. "] " .. msg .. "\n")
    if logFile then
        pcall(function()
            logFile:write(tostring(os.date("%H:%M:%S")) .. " " .. msg .. "\n")
            logFile:flush()
        end)
    end
end

errCount = 0
function logErr(where, err)
    errCount = errCount + 1
    if errCount <= 30 then log("ERROR %s: %s", where, tostring(err)) end
    if errCount == 30 then log("(further errors hidden)") end
end

-- v0.9.2 diagnostic: how long does each part of the mod take? (player reported a short
-- freeze every ~5 s). Summary every 30 s ("PERF") + immediate "SLOW" line for long ticks.
perf = { parts = {}, lastLog = os.clock() }
function timed(name, fn, ...)
    local t0 = os.clock()
    local ok, err = pcall(fn, ...)
    local dt = (os.clock() - t0) * 1000
    local p = perf.parts[name]
    if not p then p = { n = 0, total = 0, max = 0 } perf.parts[name] = p end
    p.n, p.total = p.n + 1, p.total + dt
    if dt > p.max then p.max = dt end
    if not ok then logErr(name, err) end
    return dt
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

function valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    return safe(function() return o:IsValid() end) == true
end

function shortName(o) return safe(function() return o:GetFName():ToString() end) or "?" end
function className(o) return shortName(safe(function() return o:GetClass() end)) end
function isDefaultObject(o) return string.find(shortName(o), "Default__", 1, true) ~= nil end
function readProp(o, name) return safe(function() return o[name] end) end
function addr(o) return safe(function() return o:GetAddress() end) end

function findAll(cname)
    local out = {}
    for _, a in ipairs(safe(function() return FindAllOf(cname) end) or {}) do
        if valid(a) and not isDefaultObject(a) then out[#out + 1] = a end
    end
    return out
end

function location(a)
    local v = safe(function() return a:K2_GetActorLocation() end)
    if v == nil then return nil end
    local x, y, z = safe(function() return v.X end), safe(function() return v.Y end), safe(function() return v.Z end)
    if type(x) ~= "number" then return nil end
    return x, y or 0, z or 0
end

function dist2(a, b)
    local ax, ay, az = location(a)
    local bx, by, bz = location(b)
    if not ax or not bx then return math.huge end
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

function inList(name, list)
    for _, n in ipairs(list or {}) do if n == name then return true end end
    return false
end

---------------------------------------------------------------------------
-- Player / monster lists (short cache)
---------------------------------------------------------------------------
cache = { t = -1, players = {}, monsters = {}, allMonsters = {}, friendSubs = {} }

-- Is this monster a valid target right now? (alive + optional condition)
-- v1.4.3: the ghost has two frozen stages. While the frost weapon hits it, it stays up in the
-- air with IsFrozen = true and its FrostValue climbs to 1. Then it falls to the ground frozen
-- solid: IsFrozen goes back to false and FrostValue slowly melts down to 0 (~25 s, longer if
-- frozen again) before it teleports away. The turrets now keep shooting it on the ground:
-- "down" from FrostValue >= 0.9 until it is back under 0.02.
ghostDown = {}
function ghostFrozenSolid(m)
    local f = readProp(m, "FrostValue")
    if type(f) ~= "number" then return false end
    local key = shortName(m)
    if f >= 0.9 then ghostDown[key] = true elseif f < 0.02 then ghostDown[key] = nil end
    return ghostDown[key] == true
end

function isTargetable(m)
    if not valid(m) then return false end
    if readProp(m, "IsDead") == true then return false end
    local cn = className(m)
    if cn == "BP_Monster_Ghost_C" and cfg.ghostFrozenOnGround and ghostFrozenSolid(m) then return true end
    local cond = cfg.targetOnlyWhen and cfg.targetOnlyWhen[cn]
    if cond and readProp(m, cond) ~= true then return false end
    local block = cfg.targetUnlessTrue and cfg.targetUnlessTrue[cn]
    if block and readProp(m, block) == true then return false end
    return true
end

-- IMPORTANT (crashes in v0.2/v0.4): never reuse a UObject across frames, the GC
-- may have freed it (crash inside K2_GetActorLocation on a freed BigRobot/drone).
-- We store path + address and re-validate through StaticFindObject before each use.
function entry(o)
    local fn = safe(function() return o:GetFullName() end)
    if not fn then return nil end
    return { path = (fn:gsub("^%S+%s+", "")), addr = addr(o), cls = className(o) }
end

function live(e)
    if not e then return nil end
    local o = safe(function() return StaticFindObject(e.path) end)
    if not valid(o) then return nil end
    if e.addr ~= nil then
        if addr(o) == e.addr then return o end
        return nil
    end
    return o   -- GetAddress unavailable: trust StaticFindObject
end

function liveList(entries)
    local out = {}
    for _, e in ipairs(entries or {}) do
        local o = live(e)
        if o then out[#out + 1] = o end
    end
    return out
end

function refreshLists(force)
    local now = os.clock()
    if not force and (now - cache.t) < cfg.listRefreshSeconds then return end
    cache.t = now
    local players = {}
    for _, p in ipairs(findAll(cfg.playerBaseClass)) do players[#players + 1] = entry(p) end
    local monsters, all, subs = {}, {}, {}
    for _, m in ipairs(findAll(cfg.monsterBaseClass)) do
        local e = entry(m)
        if e then
            all[#all + 1] = e
            if inList(e.cls, cfg.friendSubstituteClasses) then subs[#subs + 1] = e end
            if not inList(e.cls, cfg.ignoredMonsters) and isTargetable(m) then monsters[#monsters + 1] = e end
        end
    end
    cache.players = players          -- {path, addr} entries: re-validate with liveList()
    cache.monsters = monsters        -- monsters to target
    cache.allMonsters = all          -- every monster (ignored ones included)
    cache.friendSubs = subs          -- vanilla "friend" monsters, used as substitutes
end

function turretRange2(t)
    local r = readProp(t, "Max Distance")
    if type(r) ~= "number" or r <= 0 then r = cfg.range end
    return r * r
end

function hasAuthority(t)
    return safe(function() return t:HasAuthority() end) ~= false
end

---------------------------------------------------------------------------
-- Player / monster classification (cached per class)
---------------------------------------------------------------------------
kindCache = {}

function kindOf(o)
    if not valid(o) then return nil end
    local cn = className(o)
    local k = kindCache[cn]
    if k ~= nil then return k or nil end
    if inList(cn, cfg.ignoredMonsters) then kindCache[cn] = "ignored" return "ignored" end
    k = false
    local c = safe(function() return o:GetClass() end)
    local guard = 0
    while valid(c) and guard < 40 do
        local n = shortName(c)
        if n == cfg.playerBaseClass then k = "player" break end
        if n == cfg.monsterBaseClass then k = "monster" break end
        local cur = c
        c = safe(function() return cur:GetSuperStruct() end)
        guard = guard + 1
    end
    kindCache[cn] = k
    return k or nil
end

function tag(o)
    if not valid(o) then return "None" end
    return shortName(o) .. " <" .. className(o) .. ">"
end

-- v0.9.4: targetable monsters + their position, computed ONCE per background tick and
-- shared by every turret (before: each of the ~90 turrets re-validated every monster =>
-- 30-40 ms per second with many monsters, e.g. BP_Moray_C). Never kept across ticks
-- (UObjects must not be reused across frames).
tickSnap = nil
function monstersNow()
    if tickSnap then return tickSnap end
    local out = {}
    for _, m in ipairs(liveList(cache.monsters)) do
        if isTargetable(m) then
            local x, y, z = location(m)
            if x then out[#out + 1] = { o = m, x = x, y = y, z = z } end
        end
    end
    return out
end

function d2xyz(x, y, z, s)
    local dx, dy, dz = x - s.x, y - s.y, z - s.z
    return dx * dx + dy * dy + dz * dz
end

function nearestMonster(t)
    refreshLists(false)
    local tx, ty, tz = location(t)
    if not tx then return nil end
    local best, bestD = nil, turretRange2(t)
    for _, s in ipairs(monstersNow()) do
        local d = d2xyz(tx, ty, tz, s)
        if d <= bestD then best, bestD = s.o, d end
    end
    return best
end

---------------------------------------------------------------------------
-- Modes and phases
---------------------------------------------------------------------------
math.randomseed(os.time())

VALID_MODES = { ally = true, vanilla = true, neutral = true, chaos = true, phases = true }
if not VALID_MODES[cfg.mode] then cfg.mode = "phases" end
-- v1.4.0: the mode chosen on the lobby's Personal Board is saved in settings.txt (this mod's
-- file, never the game's save) and wins over config.lua's "mode" at the next launch.
SETTINGS_PATH = modDir() .. "\\settings.txt"
function readSettings()
    local f = io.open(SETTINGS_PATH, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)%s*$")
        if k then out[k] = v end
    end
    f:close()
    return out
end
-- v1.4.0: every Board setting (key = config.lua name, booleans as on/off)
PHASE_LENGTHS = { short = { 60, 120 }, normal = { 120, 300 }, long = { 300, 600 } }
function phaseLengthName()
    for n, l in pairs(PHASE_LENGTHS) do
        if cfg.phaseMinSeconds == l[1] and cfg.phaseMaxSeconds == l[2] then return n end
    end
    return "custom"
end
function onoff(b) return b and "on" or "off" end
function saveSettings()
    local f = io.open(SETTINGS_PATH, "w")
    if not f then return false end
    f:write("-- Allied Defense settings, written by the Personal Board (lobby). Delete to reset.\n")
    f:write("mode=", cfg.mode, "\n")
    f:write("revealPhase=", onoff(cfg.revealPhase), "\n")
    f:write("phaseLength=", phaseLengthName(), "\n")
    f:write("phasePerTurret=", onoff(cfg.phasePerTurret), "\n")
    f:write("shootCanisters=", onoff(cfg.shootCanisters), "\n")
    f:write("hostileShootCanisters=", onoff(cfg.hostileShootCanisters), "\n")
    f:write("modColours=", onoff(cfg.modColours), "\n")
    f:close()
    return true
end
do
    local saved = readSettings()
    if saved.mode and VALID_MODES[saved.mode] then cfg.mode = saved.mode end
    for _, k in ipairs({ "revealPhase", "phasePerTurret", "shootCanisters", "hostileShootCanisters", "modColours" }) do
        if saved[k] == "on" then cfg[k] = true elseif saved[k] == "off" then cfg[k] = false end
    end
    local l = PHASE_LENGTHS[saved.phaseLength or ""]
    if l then cfg.phaseMinSeconds, cfg.phaseMaxSeconds = l[1], l[2] end
end
STARTUP_MODE = cfg.mode   -- v1.3.2: Ctrl+F8 comes back to it (v1.4.0: the Board's choice)

phase = { global = nil, globalUntil = 0, turrets = {} }

function phaseDuration()
    local lo, hi = math.floor(cfg.phaseMinSeconds), math.floor(cfg.phaseMaxSeconds)
    if hi < lo then hi = lo end
    return math.random(lo, hi)
end

function startPhase()
    if cfg.phaseStart == "ally" or cfg.phaseStart == "hostile" then return cfg.phaseStart end
    return (math.random() < 0.5) and "ally" or "hostile"
end

-- Current phase ("ally" / "hostile") of a turret in "phases" mode.
function phaseOf(t)
    if not cfg.phasePerTurret then
        if phase.global == nil then
            local d = phaseDuration()
            phase.global, phase.globalUntil = startPhase(), os.time() + d
            log("PHASE (all turrets) start -> %s for %d s", phase.global, d)
        end
        return phase.global
    end
    local name = shortName(t)
    local st = phase.turrets[name]
    if st == nil then
        st = { ph = startPhase(), untilT = os.time() + phaseDuration() }
        phase.turrets[name] = st
    end
    return st.ph
end

-- Effective behaviour of a turret: "ally", "neutral", "chaos" or nil (= vanilla).
function behaviourOf(t)
    if not cfg.enabled then return nil end
    local m = cfg.mode
    if m == "vanilla" then return nil end
    if m == "phases" then
        return (phaseOf(t) == "ally") and "ally" or nil
    end
    return m
end

-- Behaviour of a hooked turret (nil when the mod must not interfere).
function behave(t)
    if not valid(t) or not hasAuthority(t) then return nil end
    return behaviourOf(t)
end

---------------------------------------------------------------------------
-- Statistics (periodic summary instead of log spam)
---------------------------------------------------------------------------
stats = {}
function count(k) stats[k] = (stats[k] or 0) + 1 end
lastStats = os.clock()

function flushStats(force)
    if not cfg.verbose then stats = {} return end
    if not force and (os.clock() - lastStats) < 10 then return end
    lastStats = os.clock()
    local keys = {}
    for k in pairs(stats) do keys[#keys + 1] = k end
    if #keys == 0 then return end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. stats[k] end
    log("STATS 10s: %s", table.concat(parts, "  "))
    stats = {}
end

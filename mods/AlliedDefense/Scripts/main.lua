-- AlliedDefense v1.0.0 - Species: Unknown (UE4SS Lua)
-- Author: Remilulz_91
--
-- Ceiling turrets (BP_SentryGun_C) no longer target players and shoot monsters instead.
--
-- How it works:
--   The turret classifies every pawn through IsFriend(Actor).
--   Vanilla: most monsters are "friends" (except Poulpi...), players are not.
--   "Pre" hooks on BP_SentryGun_C (we only alter inputs, the rest stays vanilla):
--     IsFriend                 : living monsters -> enemies; players, dead monsters,
--                                unfrozen ghost -> friends (core of the mod)
--     SetPlayerWakeUpThreshold : players can never wake a turret up
--     AddToAgroTable           : a player's aggro is redirected to the nearest monster
--                                (or made very negative when no monster is around)
--     TryToWakeUp              : player -> nearest monster, otherwise None (no wake-up)
--     SelectTrg                : removes players from the aggro table, adds nearby monsters
--     Handle_Shoot / CurrentTrg_Handle : a player target is swapped for the nearest
--                                monster (or dropped) right before aiming/shooting
--     PawnDetectionSphere overlap : players never enter the turret's sensor
--   Background loop: ally colour (option), player wake threshold,
--   TryToWakeUp(monster) on sleeping turrets, optional monster class dump,
--   and (v0.8.3) injection of monsters into the turret's potential_trgs map:
--   SelectTrg only picks targets from that map, and BigRobot / drones never enter
--   it by themselves (their collision apparently never triggers the sensor).
--
-- Turret modes (v0.8, config "mode", cycled in game with Ctrl+F9):
--   ally    : turrets ignore players and shoot monsters (everything above)
--   vanilla : untouched game behaviour
--   neutral : turrets shoot nobody
--   chaos   : turrets shoot everybody (players AND monsters)
--   phases  : turrets alternate between ally and hostile (vanilla) phases of random
--             length; hidden by default (same colour in both phases)
--
-- Turret logic runs on the host (HasAuthority). In multiplayer, the host needs the mod.

local VERSION = "1.0.0"
local MOD = "AlliedDefense"

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local okCfg, cfg = pcall(require, "config")
if not okCfg or type(cfg) ~= "table" then cfg = {} end
local function default(k, v) if cfg[k] == nil then cfg[k] = v end end
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
default("friendSubstituteClasses", { "BP_BigRobot_C" })
default("blockPlayerWake", true)
default("playerWakeThreshold", 1000000.0)
default("playerAgroToNone", false)
default("hidePlayersFromSensor", true)
default("retargetToMonster", false)
default("targetUnlessTrue", { BP_Monster_Eye_C = "HaveShield" })
default("purgePotentialTargets", true)
default("allyFireColor", nil)
default("dumpMonsterClasses", false)
default("listRefreshSeconds", 0.5)
default("backgroundIntervalMs", 1000)
default("modifier", "CONTROL")
default("toggleKey", "F10")
default("verboseKey", "F11")
default("verbose", false)
default("debugLogs", false)
default("mode", "phases")
default("modeKey", "F9")
default("modeCycle", { "phases", "ally", "chaos", "neutral", "vanilla" })
default("phasePerTurret", false)
default("phaseMinSeconds", 120)
default("phaseMaxSeconds", 300)
default("phaseStart", "random")
default("revealPhase", false)
default("chaosFireColor", nil)
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
local function modDir()
    local ok, info = pcall(debug.getinfo, modDir, "S")
    if ok and info and type(info.source) == "string" then
        local src = info.source:gsub("^@", "")
        local scripts = src:match("^(.*)[/\\][^/\\]+$")
        if scripts then return scripts:match("^(.*)[/\\][^/\\]+$") or scripts end
    end
    return "."
end

local LOG_PATH = modDir() .. "\\AlliedDefense.log"
local logFile = io.open(LOG_PATH, "w")

local function log(fmt, ...)
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

local errCount = 0
local function logErr(where, err)
    errCount = errCount + 1
    if errCount <= 30 then log("ERROR %s: %s", where, tostring(err)) end
    if errCount == 30 then log("(further errors hidden)") end
end

-- v0.9.2 diagnostic: how long does each part of the mod take? (player reported a short
-- freeze every ~5 s). Summary every 30 s ("PERF") + immediate "SLOW" line for long ticks.
local perf = { parts = {}, lastLog = os.clock() }
local function timed(name, fn, ...)
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
local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    return safe(function() return o:IsValid() end) == true
end

local function shortName(o) return safe(function() return o:GetFName():ToString() end) or "?" end
local function className(o) return shortName(safe(function() return o:GetClass() end)) end
local function isDefaultObject(o) return string.find(shortName(o), "Default__", 1, true) ~= nil end
local function readProp(o, name) return safe(function() return o[name] end) end
local function addr(o) return safe(function() return o:GetAddress() end) end

local function findAll(cname)
    local out = {}
    for _, a in ipairs(safe(function() return FindAllOf(cname) end) or {}) do
        if valid(a) and not isDefaultObject(a) then out[#out + 1] = a end
    end
    return out
end

local function location(a)
    local v = safe(function() return a:K2_GetActorLocation() end)
    if v == nil then return nil end
    local x, y, z = safe(function() return v.X end), safe(function() return v.Y end), safe(function() return v.Z end)
    if type(x) ~= "number" then return nil end
    return x, y or 0, z or 0
end

local function dist2(a, b)
    local ax, ay, az = location(a)
    local bx, by, bz = location(b)
    if not ax or not bx then return math.huge end
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

local function inList(name, list)
    for _, n in ipairs(list or {}) do if n == name then return true end end
    return false
end

---------------------------------------------------------------------------
-- Player / monster lists (short cache)
---------------------------------------------------------------------------
local cache = { t = -1, players = {}, monsters = {}, allMonsters = {}, friendSubs = {} }

-- Is this monster a valid target right now? (alive + optional condition)
local function isTargetable(m)
    if not valid(m) then return false end
    if readProp(m, "IsDead") == true then return false end
    local cn = className(m)
    local cond = cfg.targetOnlyWhen and cfg.targetOnlyWhen[cn]
    if cond and readProp(m, cond) ~= true then return false end
    local block = cfg.targetUnlessTrue and cfg.targetUnlessTrue[cn]
    if block and readProp(m, block) == true then return false end
    return true
end

-- IMPORTANT (crashes in v0.2/v0.4): never reuse a UObject across frames, the GC
-- may have freed it (crash inside K2_GetActorLocation on a freed BigRobot/drone).
-- We store path + address and re-validate through StaticFindObject before each use.
local function entry(o)
    local fn = safe(function() return o:GetFullName() end)
    if not fn then return nil end
    return { path = (fn:gsub("^%S+%s+", "")), addr = addr(o), cls = className(o) }
end

local function live(e)
    if not e then return nil end
    local o = safe(function() return StaticFindObject(e.path) end)
    if not valid(o) then return nil end
    if e.addr ~= nil then
        if addr(o) == e.addr then return o end
        return nil
    end
    return o   -- GetAddress unavailable: trust StaticFindObject
end

local function liveList(entries)
    local out = {}
    for _, e in ipairs(entries or {}) do
        local o = live(e)
        if o then out[#out + 1] = o end
    end
    return out
end

local function refreshLists(force)
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

local function turretRange2(t)
    local r = readProp(t, "Max Distance")
    if type(r) ~= "number" or r <= 0 then r = cfg.range end
    return r * r
end

local function hasAuthority(t)
    return safe(function() return t:HasAuthority() end) ~= false
end

---------------------------------------------------------------------------
-- Player / monster classification (cached per class)
---------------------------------------------------------------------------
local kindCache = {}

local function kindOf(o)
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

local function tag(o)
    if not valid(o) then return "None" end
    return shortName(o) .. " <" .. className(o) .. ">"
end

-- v0.9.4: targetable monsters + their position, computed ONCE per background tick and
-- shared by every turret (before: each of the ~90 turrets re-validated every monster =>
-- 30-40 ms per second with many monsters, e.g. BP_Moray_C). Never kept across ticks
-- (UObjects must not be reused across frames).
local tickSnap = nil
local function monstersNow()
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

local function d2xyz(x, y, z, s)
    local dx, dy, dz = x - s.x, y - s.y, z - s.z
    return dx * dx + dy * dy + dz * dz
end

local function nearestMonster(t)
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

local VALID_MODES = { ally = true, vanilla = true, neutral = true, chaos = true, phases = true }
if not VALID_MODES[cfg.mode] then cfg.mode = "phases" end

local phase = { global = nil, globalUntil = 0, turrets = {} }

local function phaseDuration()
    local lo, hi = math.floor(cfg.phaseMinSeconds), math.floor(cfg.phaseMaxSeconds)
    if hi < lo then hi = lo end
    return math.random(lo, hi)
end

local function startPhase()
    if cfg.phaseStart == "ally" or cfg.phaseStart == "hostile" then return cfg.phaseStart end
    return (math.random() < 0.5) and "ally" or "hostile"
end

-- Current phase ("ally" / "hostile") of a turret in "phases" mode.
local function phaseOf(t)
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
local function behaviourOf(t)
    if not cfg.enabled then return nil end
    local m = cfg.mode
    if m == "vanilla" then return nil end
    if m == "phases" then
        return (phaseOf(t) == "ally") and "ally" or nil
    end
    return m
end

-- Behaviour of a hooked turret (nil when the mod must not interfere).
local function behave(t)
    if not valid(t) or not hasAuthority(t) then return nil end
    return behaviourOf(t)
end

---------------------------------------------------------------------------
-- Statistics (periodic summary instead of log spam)
---------------------------------------------------------------------------
local stats = {}
local function count(k) stats[k] = (stats[k] or 0) + 1 end
local lastStats = os.clock()

local function flushStats(force)
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

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
local function getSelf(ctx) return safe(function() return ctx:get() end) end
local function getParam(p) return safe(function() return p:get() end) end
local function setParam(p, v) return pcall(function() p:set(v) end) end

-- Diagnostic: is the player inside the turret's potential_trgs map?
-- (tells us which path still puts the player in current_trg). Throttled.
local probeAt = {}
local function probePotentialTargets(t, name)
    local now = os.clock()
    if (now - (probeAt[name] or -100)) < 5 then return end
    probeAt[name] = now
    local map = readProp(t, "potential_trgs")
    if map == nil then count("probe_no_potential_trgs") return end
    local found, total = false, 0
    local ok = pcall(function()
        map:ForEach(function(k, v)
            total = total + 1
            local a = safe(function() return k:get() end)
            if kindOf(a) == "player" then found = true end
        end)
    end)
    if not ok then count("probe_map_unreadable") return end
    count(found and "probe_player_in_potential_trgs" or "probe_player_not_in_potential_trgs")
end

-- v0.7 probe showed the player is STILL inside potential_trgs (filled by a path
-- other than the overlap events). Remove players from that map directly.
local mapRemoveBroken = false
local learnDataClassHook = nil   -- set by the injector (v0.8.7): learn OBJ_SentryTrgData_C before purging
local function purgePlayersFromPotential(t, statKey)
    if not cfg.purgePotentialTargets or mapRemoveBroken then return end
    local map = readProp(t, "potential_trgs")
    if map == nil then return end
    if learnDataClassHook then pcall(learnDataClassHook, map) end
    for _, p in ipairs(liveList(cache.players)) do
        local has = safe(function() return map:Contains(p) end)
        if has ~= false then
            local ok, err = pcall(function() map:Remove(p) end)
            if ok then
                if has == true then count(statKey or "potential_trgs_player_removed") end
            else
                mapRemoveBroken = true
                logErr("potential_trgs:Remove", err)
                log("TMap removal not supported by this UE4SS build: potential_trgs purge disabled")
                return
            end
        end
    end
end

-- Throttled log of "turret -> player" events (what used to cause the beep).
local playerTargetLogAt = {}
local function logPlayerTarget(t, name, where, newTarget)
    local now = os.clock()
    if (now - (playerTargetLogAt[name] or -100)) < 5 then return end
    playerTargetLogAt[name] = now
    if cfg.verbose then
        log("TARGET %s -> player (via %s), replaced by %s", name, where, tag(newTarget))
    end
end

-- If the current target is a player, swap it for the nearest monster (or drop it).
local function fixPlayerTarget(t, where)
    local cur = readProp(t, "current_trg")
    if kindOf(cur) ~= "player" then return false end
    local name = shortName(t)
    local m = cfg.retargetToMonster and nearestMonster(t) or nil
    local ok
    if valid(m) then
        -- keep the aggro table consistent with the new target (setting current_trg
        -- alone could leave the turret frozen - seen in v0.7 with BigRobot)
        pcall(function() t:AddToAgroTable(m, cfg.monsterInitAgro, true) end)
        ok = pcall(function() t.current_trg = m end)
        count(ok and ("player_target_to_monster_" .. where) or "ERR_retarget")
    else
        ok = pcall(function() t.current_trg = nil end)
        count(ok and ("player_target_dropped_" .. where) or "ERR_drop_target")
    end
    -- v0.9.5: probePotentialTargets (v0.7 diagnostic) removed from here. It walked EVERY key
    -- of potential_trgs and read its class; a zombie being destroyed in that map crashed
    -- UE4SS (crash dump 15:30:23: access violation near "potential_trgs", "BP_Zombie_Simple_C",
    -- "HasAuthority", right after a "player target dropped").
    logPlayerTarget(t, name, where, m)
    return true
end

-- AddToAgroTable(trg, agro_value, init_only): a player's aggro is REDIRECTED to the
-- nearest monster (the turret gets angry at it instead). No monster: very negative aggro.
-- (v0.5-0.6 replaced the player with None: the None entry won SelectTrg ->
--  current_trg = None -> turrets stopped shooting BigRobot/drones.)
local function preAddToAgro(ctx, pTrg, pValue, pInit)
    local t = getSelf(ctx)
    local b = behave(t)
    if b == nil or b == "chaos" then return end
    local k = kindOf(getParam(pTrg))
    if b == "neutral" then
        if k ~= nil and setParam(pValue, -100000.0) then count("neutral_aggro_cancelled") end
        return
    end
    -- ally
    if not cfg.ignorePlayers or k ~= "player" then return end
    local m = nearestMonster(t)
    if valid(m) and setParam(pTrg, m) then count("aggro_redirected_to_monster")
    elseif cfg.playerAgroToNone and setParam(pTrg, nil) then count("aggro_player_to_none")
    elseif setParam(pValue, -100000.0) then count("aggro_player_cancelled")
    else count("ERR_aggro_param") end
end

-- IsFriend(Actor) -> is_friend: CORE OF THE MOD.
-- The game treats monsters as "friends" (except Poulpi) => never targeted.
-- We swap the tested actor BEFORE the evaluation:
--   monster -> test a player instead            => "not a friend" => valid target
--   player  -> test a friend monster (or turret) => "friend"       => ignored
local function friendSubstitute(t)
    for _, m in ipairs(liveList(cache.friendSubs)) do
        if valid(m) then return m end
    end
    return t   -- fallback: the turret itself
end

local function preIsFriend(ctx, pActor)
    local t = getSelf(ctx)
    local b = behave(t)
    if b == nil then return end
    local a = getParam(pActor)
    local k = kindOf(a)
    if k == nil then return end
    if k == "monster" and not isTargetable(a) then k = "ignored" end
    refreshLists(false)

    local makeEnemy = (k == "monster" and cfg.targetMonsters and (b == "ally" or b == "chaos"))
    local makeFriend = (b == "neutral")
                    or (k == "ignored")
                    or (b == "ally" and k == "player" and cfg.ignorePlayers)

    if makeEnemy then
        local p = liveList(cache.players)[1]
        if valid(p) and setParam(pActor, p) then count("isfriend_monster_enemy")
        else count("ERR_isfriend_monster") end
    elseif makeFriend then
        local subst = friendSubstitute(t)
        if setParam(pActor, subst) then
            count(k == "player" and "isfriend_player_friend" or "isfriend_" .. k .. "_friend")
            if subst == t then count("substitute_turret") end
        else count("ERR_isfriend_" .. k) end
    end
    -- chaos + player: untouched (vanilla: players are enemies)
end

-- BPI_SentryGun_SetPlayerWakeUpThreshold_1(Threshold): the manager sets the
-- player wake-up threshold; we replace it with an unreachable value.
local function preSetPlayerThreshold(ctx, pThreshold)
    local t = getSelf(ctx)
    local b = behave(t)
    if (b ~= "ally" and b ~= "neutral") or not cfg.blockPlayerWake then return end
    if setParam(pThreshold, cfg.playerWakeThreshold) then count("player_threshold_forced") end
end

-- TryToWakeUp(Enemy): a player no longer wakes the turret up; if a monster is in
-- range, the monster wakes it up instead.
local function preTryToWakeUp(ctx, pEnemy)
    local t = getSelf(ctx)
    local b = behave(t)
    if b == nil or b == "chaos" then return end
    local k = kindOf(getParam(pEnemy))
    if b == "neutral" then
        if k ~= nil and setParam(pEnemy, nil) then count("neutral_wake_blocked") end
        return
    end
    -- ally
    if not cfg.ignorePlayers or k ~= "player" then return end
    local m = nearestMonster(t)
    if valid(m) and setParam(pEnemy, m) then count("wake_redirected_to_monster")
    elseif setParam(pEnemy, nil) then count("wake_player_blocked")
    else count("wake_player_not_blocked") end
end

-- Right before target selection: clean the table, add monsters.
local lastTrg = {}
local function addNearbyMonsters(t)
    local r2 = turretRange2(t)
    for _, m in ipairs(liveList(cache.monsters)) do
        if isTargetable(m) and dist2(t, m) <= r2 then
            local ok, err = pcall(function()
                t:AddToAgroTable(m, cfg.monsterInitAgro, true)
                t:AddToAgroTable(m, cfg.monsterAgroPerCall, false)
            end)
            if not ok then logErr("AddToAgroTable", err) end
        end
    end
end

local function dropAnyTarget(t)
    if valid(readProp(t, "current_trg")) then
        if pcall(function() t.current_trg = nil end) then count("neutral_target_dropped") end
    end
end

local function preSelectTrg(ctx)
    local t = getSelf(ctx)
    local b = behave(t)
    if b == nil then return end
    refreshLists(false)
    if b == "neutral" then dropAnyTarget(t) return end
    if b == "ally" and cfg.ignorePlayers then
        for _, p in ipairs(liveList(cache.players)) do pcall(function() t:RemoveFromAgroTable(p) end) end
        -- purge a possible None entry (the game does it too)
        pcall(function() t:RemoveFromAgroTable(nil) end)
        purgePlayersFromPotential(t)
        fixPlayerTarget(t, "select")
    end
    addNearbyMonsters(t)   -- ally and chaos
end

-- Right before aiming/shooting: a player target is dropped (ally) / any target (neutral).
local restoreHookFn = nil   -- set once restoreAllyHits exists (v0.9.6)
local function preShoot(ctx)
    if restoreHookFn then pcall(restoreHookFn) end
    local t = getSelf(ctx)
    local b = behave(t)
    if b == "neutral" then dropAnyTarget(t) return end
    if b ~= "ally" or not cfg.ignorePlayers then return end
    purgePlayersFromPotential(t)
    fixPlayerTarget(t, "shoot")
end

local function logTarget(t)
    if not cfg.verbose or not valid(t) then return end
    local name = shortName(t)
    local s = tag(readProp(t, "current_trg"))
    if lastTrg[name] ~= s then
        lastTrg[name] = s
        log("TARGET %s -> %s", name, s)
    end
end

local HOOKS = {
    { fn = "IsFriend",                pre = preIsFriend },
    { fn = "BPI_SentryGun_SetPlayerWakeUpThreshold_1", pre = preSetPlayerThreshold },
    { fn = "AddToAgroTable",          pre = preAddToAgro },
    { fn = "TryToWakeUp",             pre = preTryToWakeUp },
    { fn = "SelectTrg",               pre = preSelectTrg },
    { fn = "Handle_Shoot (SRV side)", pre = preShoot },
    { fn = "CurrentTrg_Handle",       pre = preShoot },
}

-- Presence sensor (PawnDetectionSphere): a player entering/leaving the sphere is
-- replaced by None => never enters potential_trgs, the turret no longer "sees" them.
local function preSensor(ctx, pComp, pOther)
    local t = getSelf(ctx)
    local b = behave(t)
    if not cfg.hidePlayersFromSensor or (b ~= "ally" and b ~= "neutral") then return end
    local k = kindOf(getParam(pOther))
    if k == nil then return end
    if b == "ally" and (k ~= "player" or not cfg.ignorePlayers) then return end
    if setParam(pOther, nil) then
        count(k == "player" and "sensor_player_hidden" or "sensor_" .. k .. "_hidden")
    else count("ERR_sensor") end
end

local function sensorFunctions(cls)
    local out = {}
    pcall(function()
        cls:ForEachFunction(function(f)
            local n = shortName(f)
            if n:find("PawnDetectionSphere", 1, true) and n:find("Overlap", 1, true) then
                out[#out + 1] = n
            end
        end)
    end)
    return out
end

local hookState = { classAddr = nil, list = {}, pending = {}, tries = 0, lastTry = -100, failLogged = {} }
local sensorNames = { begin = nil, finish = nil }   -- sensor overlap events (used by the injector)

-- v0.8.4: right after the level loads, the turret class can be found while its Blueprint
-- functions are not linked yet ("UFunction::Func: 0x0"): RegisterHook fails. v0.8.3 never
-- retried (every hook failed for a whole game). Failed hooks are now retried every 2 s.
local function installHook(spec)
    local path = cfg.turretClassPath .. ":" .. spec.fn
    local fn = spec.pre
    local perfName = "hook:" .. (spec.fn:find("PawnDetectionSphere", 1, true) and "Sensor" or spec.fn)
    local ok, pre, post = pcall(RegisterHook, path, function(ctx, ...)
        timed(perfName, fn, ctx, ...)
        if spec.fn == "SelectTrg" then pcall(logTarget, getSelf(ctx)) end
    end)
    if ok then
        hookState.list[#hookState.list + 1] = { path = path, pre = pre, post = post }
        if cfg.debugLogs then
            log("Hook installed: %s%s", spec.fn,
                hookState.tries > 1 and string.format(" (attempt %d)", hookState.tries) or "")
        end
        return true
    end
    if cfg.debugLogs and not hookState.failLogged[spec.fn] then
        hookState.failLogged[spec.fn] = true
        local first = tostring(pre):match("^[^\n]*") or "?"
        local func = tostring(pre):match("UFunction::Func: (%S+)") or "?"
        log("Hook not ready yet: %s (Func=%s, %s) - will retry", spec.fn, func, first)
    end
    return false
end

-- v0.9.3: StaticFindObject on a path that does not exist (e.g. the turret class in the
-- hangar) costs ~10 ms. The lookup now runs every 5 s while the class is missing, every
-- 10 s once all hooks are installed (to notice a level change), every 2 s otherwise.
local hookCheck = { last = -100 }
local function tryRegisterHooks()
    local now0 = os.clock()
    local done = hookState.classAddr ~= nil and #hookState.pending == 0 and not hookState.needSensors
    local interval = done and 10 or (hookState.classAddr ~= nil and 2 or 5)
    if (now0 - hookCheck.last) < interval then return end
    hookCheck.last = now0
    local cls = safe(function() return StaticFindObject(cfg.turretClassPath) end)
    if not valid(cls) then return end
    local a = addr(cls)
    local now = os.clock()

    if hookState.classAddr == nil or hookState.classAddr ~= a then
        -- new (or reloaded) turret class: drop old hooks, start over
        for _, h in ipairs(hookState.list) do pcall(UnregisterHook, h.path, h.pre, h.post) end
        hookState = { classAddr = a, list = {}, pending = {}, tries = 0, lastTry = -100, failLogged = {} }
        for _, spec in ipairs(HOOKS) do hookState.pending[#hookState.pending + 1] = spec end
        hookState.needSensors = true
    end

    if #hookState.pending == 0 and not hookState.needSensors then return end
    if (now - hookState.lastTry) < 2 then return end
    hookState.lastTry = now
    hookState.tries = hookState.tries + 1

    if hookState.needSensors then
        local names = sensorFunctions(cls)
        if #names > 0 then
            hookState.needSensors = false
            sensorNames = { begin = nil, finish = nil }
            for _, n in ipairs(names) do
                hookState.pending[#hookState.pending + 1] = { fn = n, pre = preSensor }
                if n:find("BeginOverlap", 1, true) then sensorNames.begin = n end
                if n:find("EndOverlap", 1, true) then sensorNames.finish = n end
            end
        end
    end

    local still = {}
    for _, spec in ipairs(hookState.pending) do
        if not installHook(spec) then still[#still + 1] = spec end
    end
    hookState.pending = still
    if #still == 0 and not hookState.needSensors then
        log("All hooks installed (%d, after %d attempt%s)", #hookState.list, hookState.tries,
            hookState.tries == 1 and "" or "s")
    elseif hookState.tries % 30 == 0 then
        log("Still %d hook(s) not installed after %d attempts", #still, hookState.tries)
    end
end

---------------------------------------------------------------------------
-- Background loop: hooks + monsters waking turrets up
---------------------------------------------------------------------------
local wakeAt = {}   -- turret -> last attempt
-- v0.8.6 diagnostic: does TryToWakeUp(monster) actually open the turret?
-- pending[name] = { t0, monster class, dist } ; checked on the next background passes.
local wakePending = {}
local wakeLogs = 0
local WAKE_LOG_MAX = 15
local wakeNoEffectLogged = {}   -- one "no effect" line per turret

local function lockState(t)
    return string.format("gameprogress_locked=%s neighbour_locked=%s power_on=%s behaviour_state=%s",
        tostring(readProp(t, "is_gameprogress_locked")), tostring(readProp(t, "is_neighbour_locked")),
        tostring(readProp(t, "srv_power_on")), tostring(readProp(t, "behaviour_state")))
end

local function checkWakeResult(t, name, now)
    local p = wakePending[name]
    if not p then return end
    if readProp(t, "is_awake") == true then
        wakePending[name] = nil
        count("wake_ok")
        if cfg.debugLogs and wakeLogs < WAKE_LOG_MAX then
            wakeLogs = wakeLogs + 1
            log("WAKE ok: %s opened for %s (%.0f cm) after %.1f s", name, p.cls, p.dist, now - p.t0)
        end
    elseif (now - p.t0) >= cfg.wakeRetrySeconds - 0.5 then
        wakePending[name] = nil
        count("wake_no_effect")
        if cfg.debugLogs and wakeLogs < WAKE_LOG_MAX and not wakeNoEffectLogged[name] then
            wakeNoEffectLogged[name] = true
            wakeLogs = wakeLogs + 1
            log("WAKE no effect: %s for %s (%.0f cm)  %s", name, p.cls, p.dist, lockState(t))
        end
    end
end

local function wakeTurrets()
    if not cfg.enabled or not cfg.wakeOnMonster then return end
    if cfg.mode == "vanilla" or cfg.mode == "neutral" then return end
    if #cache.monsters == 0 and next(wakePending) == nil then return end
    local now = os.clock()
    for _, t in ipairs(findAll(cfg.turretClass)) do
        local name = shortName(t)
        checkWakeResult(t, name, now)
        local b = behave(t)
        if (b == "ally" or b == "chaos") and readProp(t, "is_awake") ~= true then
            local m = nearestMonster(t)
            if m and isTargetable(m) and (now - (wakeAt[name] or -100)) >= cfg.wakeRetrySeconds then
                wakeAt[name] = now
                pcall(function() t:TryToWakeUp(m) end)
                count("wake_by_monster")
                if wakePending[name] == nil then
                    wakePending[name] = { t0 = now, cls = className(m), dist = math.sqrt(dist2(t, m)) }
                end
                if cfg.forceDeploy then
                    local ok, err = pcall(function() t:Deploy() end)
                    if ok then count("forced_deploy") else logErr("Deploy", err) end
                end
            end
        end
    end
end


---------------------------------------------------------------------------
-- v0.8.3: inject monsters into potential_trgs
-- Ctrl+F6 (v0.8.2) showed turrets next to BigRobot with BigRobot/drones in agro_table
-- (100.0) but potential_trgs EMPTY and current_trg None: SelectTrg only picks from
-- potential_trgs (Actor -> OBJ_SentryTrgData_C), filled by the sensor overlap event.
-- BigRobot / drones never trigger that overlap, so we feed the map ourselves:
--   1) "event"     : call the turret's own sensor BeginOverlap event with the monster
--                    (the game builds the OBJ_SentryTrgData_C itself);
--   2) "construct" : if (1) is rejected, build an OBJ_SentryTrgData_C and add it.
-- Injected entries are removed when the monster dies / is shielded / leaves.
---------------------------------------------------------------------------
local inj = {
    turrets = {},          -- turret name -> { [monster path] = { e = entry, how = "event"|"construct" } }
    dataCls = nil,         -- OBJ_SentryTrgData_C class (taken from an existing map value)
    described = false,     -- OBJ_SentryTrgData_C described once in the log
    eventBroken = false, constructBroken = false,
    loggedClass = {},      -- first success/failure logged once per (class, method)
}

local function describeTrgData(v)
    if inj.described or not valid(v) then return end
    local c = safe(function() return v:GetClass() end)
    if not valid(c) then return end
    inj.described = true
    inj.dataCls = c
    if not cfg.debugLogs then return end
    log("TRGDATA class %s (%s)", shortName(c), tostring(safe(function() return c:GetFullName() end)))
    pcall(function()
        c:ForEachProperty(function(prop)
            local ty = safe(function() return prop:GetClass():GetFName():ToString() end) or "?"
            local pn = shortName(prop)
            local val = readProp(v, pn)
            local sv
            if type(val) == "userdata" then
                sv = valid(val) and tag(val) or (safe(function() return val:ToString() end) or "<struct/None>")
            else sv = tostring(val) end
            log("  TRGDATA prop %-30s %-18s = %s", pn, ty, tostring(sv))
        end)
    end)
    pcall(function()
        c:ForEachFunction(function(f) log("  TRGDATA func %s", shortName(f)) end)
    end)
end

-- Grab the OBJ_SentryTrgData_C class from any value already in a potential_trgs map.
local function learnDataClass(map)
    if inj.described then return end
    pcall(function()
        map:ForEach(function(k, v)
            if not inj.described then
                local val = safe(function() return v:get() end)
                if valid(val) then describeTrgData(val) end
            end
        end)
    end)
end

learnDataClassHook = learnDataClass

-- v0.8.7: v0.8.5 removes the player from potential_trgs every second, so the injector never
-- saw an OBJ_SentryTrgData_C to learn its class from => "construct" was impossible and
-- BigRobot/drones were never added. The class is now also looked up by its path.
local function resolveDataClass()
    if valid(inj.dataCls) then return true end
    local c = safe(function() return StaticFindObject(cfg.trgDataClassPath) end)
    if valid(c) then
        inj.dataCls = c
        if cfg.debugLogs then log("TRGDATA class found by path: %s", cfg.trgDataClassPath) end
        return true
    end
    return false
end

local function mapHas(map, m) return safe(function() return map:Contains(m) end) == true end

local function logOnce(key, fmt, ...)
    if inj.loggedClass[key] then return end
    inj.loggedClass[key] = true
    log(fmt, ...)
end

local function injectByEvent(t, m, map)
    if inj.eventBroken or not sensorNames.begin then return false end
    local root = readProp(m, "RootComponent")
    local sphere = readProp(t, "PawnDetectionSphere")
    local ok, err = pcall(function()
        t[sensorNames.begin](t, sphere, m, root, 0, false, {})
    end)
    if not ok then
        inj.eventBroken = true
        logErr("inject (sensor event)", err)
        log("INJECT: sensor event call not supported, event method disabled")
        return false
    end
    return mapHas(map, m)
end

local function injectByConstruct(t, m, map)
    if inj.constructBroken or not resolveDataClass() then return false end
    local ok, err = pcall(function()
        local obj = StaticConstructObject(inj.dataCls, t)
        if not valid(obj) then error("StaticConstructObject returned nothing") end
        -- point every Actor/Object reference of the data object that looks like a target at the monster
        pcall(function()
            inj.dataCls:ForEachProperty(function(prop)
                local ty = safe(function() return prop:GetClass():GetFName():ToString() end) or ""
                local pn = shortName(prop)
                local low = pn:lower()
                if ty == "ObjectProperty" and (low:find("trg") or low:find("actor") or low:find("target")
                                               or low:find("pawn")) then
                    pcall(function() obj[pn] = m end)
                end
            end)
        end)
        map:Add(m, obj)
    end)
    if not ok then
        inj.constructBroken = true
        logErr("inject (construct)", err)
        log("INJECT: construct method not supported, disabled")
        return false
    end
    return mapHas(map, m)
end

local function injectMonsters(t)
    local b = behave(t)
    local active = cfg.injectPotentialTargets and (b == "ally" or b == "chaos")
    local name = shortName(t)
    if not active and inj.turrets[name] == nil then return end
    local map = readProp(t, "potential_trgs")
    if map == nil then return end
    if active then learnDataClass(map) end

    local mine = inj.turrets[name] or {}
    inj.turrets[name] = mine
    local r = readProp(t, "pawn_detection_radius")
    if type(r) ~= "number" or r <= 0 then r = 2000 end
    local rIn, rOut = r * cfg.injectRadiusScale, r * cfg.injectRadiusScale * cfg.injectRemoveScale

    -- 1) drop our stale entries (dead, shielded, unfrozen ghost, out of range)
    for path, rec in pairs(mine) do
        local m = live(rec.e)
        if m == nil then
            mine[path] = nil                      -- destroyed: the GC clears the key itself
        elseif not active or not isTargetable(m) or dist2(t, m) > rOut * rOut then
            if mapHas(map, m) then
                local ok = false
                if rec.how == "event" and sensorNames.finish then
                    local sphere, root = readProp(t, "PawnDetectionSphere"), readProp(m, "RootComponent")
                    ok = pcall(function() t[sensorNames.finish](t, sphere, m, root, 0) end) and not mapHas(map, m)
                end
                if not ok then pcall(function() map:Remove(m) end) end
                count("inject_removed")
            end
            mine[path] = nil
        end
    end

    if not active then
        if next(mine) == nil then inj.turrets[name] = nil end
        return
    end

    -- 2) add the monsters in sensor range that are missing from the map
    local method = cfg.injectMethod
    local tx, ty, tz = location(t)
    if not tx then return end
    for _, s in ipairs(monstersNow()) do
        local m = s.o
        if d2xyz(tx, ty, tz, s) <= rIn * rIn and not mapHas(map, m) then
            local cn = className(m)
            local how = nil
            if (method == "auto" or method == "event") and injectByEvent(t, m, map) then how = "event"
            elseif (method == "auto" or method == "construct") and injectByConstruct(t, m, map) then how = "construct" end
            if how then
                local e = entry(m)
                if e then mine[e.path] = { e = e, how = how } end
                count("inject_" .. how .. "_ok")
                logOnce(cn .. how, "INJECT: %s added to %s's potential_trgs (method %s)", cn, name, how)
            else
                count("inject_failed")
                logOnce(cn .. "fail", "INJECT: could not add %s to potential_trgs (event broken=%s, data class=%s)",
                    cn, tostring(inj.eventBroken), valid(inj.dataCls) and shortName(inj.dataCls) or "unknown yet")
            end
        end
    end
end

-- v0.8.5: players are also removed from potential_trgs every second (background), not only
-- when the turret selects/shoots: removes the short "TARGET -> player (via shoot)" moments.
-- v0.8.8: OFF by default. A turret only deploys after a player entered its potential_trgs
-- (the mod then swaps the player for a monster); purging every second kept every turret
-- in the ceiling (v0.8.5-0.8.7: no "TARGET" line in a whole BigRobot game).
local function purgeAllPlayers()
    if not cfg.purgePlayersInBackground or not cfg.ignorePlayers then return end
    if #cache.players == 0 then return end
    for _, t in ipairs(findAll(cfg.turretClass)) do
        if behave(t) == "ally" then purgePlayersFromPotential(t, "bg_player_removed") end
    end
end

local function injectAll()
    if #hookState.pending > 0 or hookState.needSensors then return end   -- wait for the hooks
    -- also runs when disabled / vanilla / neutral, to remove the entries we added
    if #cache.monsters == 0 and next(inj.turrets) == nil then return end
    for _, t in ipairs(findAll(cfg.turretClass)) do
        local ok, err = pcall(injectMonsters, t)
        if not ok then logErr("injectMonsters", err) return end
    end
end

-- Ally colour + player wake threshold: applied while enabled, restored when disabled.
local origThreshold = {}
local origColor = {}
local colorErr = false

local function readColor(t)
    local c = readProp(t, "fire_color")
    if c == nil then return nil end
    local r, g, b, a = safe(function() return c.R end), safe(function() return c.G end),
                       safe(function() return c.B end), safe(function() return c.A end)
    if type(r) ~= "number" then return nil end
    return { R = r, G = g, B = b, A = a }
end

local function sameColor(x, y)
    return x and y and math.abs(x.R - y.R) < 1e-3 and math.abs(x.G - y.G) < 1e-3 and math.abs(x.B - y.B) < 1e-3
end

local function writeColor(t, c)
    local ok, err = pcall(function() t.fire_color = { R = c.R, G = c.G, B = c.B, A = c.A or 1.0 } end)
    if not ok and not colorErr then colorErr = true logErr("fire_color", err) end
end

-- Colour wanted for a turret (nil = game colour).
local function wantedColor(t)
    if not cfg.enabled or cfg.mode == "vanilla" then return nil end
    if cfg.mode == "phases" and not cfg.revealPhase then return cfg.allyFireColor end
    local b = behaviourOf(t)
    if b == "ally" or b == "neutral" then return cfg.allyFireColor end
    if b == "chaos" then return cfg.chaosFireColor end
    return nil   -- revealed hostile phase: game colour (red)
end

local function applyColor(t, name)
    local want = wantedColor(t)
    local cur = readColor(t)
    if not cur then return end
    if want then
        if not sameColor(cur, want) then
            if origColor[name] == nil then origColor[name] = cur end
            writeColor(t, want)
        end
    elseif origColor[name] ~= nil then
        writeColor(t, origColor[name])
        origColor[name] = nil
    end
end

local function applyTurretSettings()
    for _, t in ipairs(findAll(cfg.turretClass)) do
        local name = shortName(t)
        pcall(applyColor, t, name)
        local b = behaviourOf(t)
        local block = cfg.blockPlayerWake and (b == "ally" or b == "neutral")
        local cur = readProp(t, "player_wakeup_threshold")
        if type(cur) == "number" then
            if block then
                if cur ~= cfg.playerWakeThreshold then
                    if origThreshold[name] == nil then origThreshold[name] = cur end
                    pcall(function() t.player_wakeup_threshold = cfg.playerWakeThreshold end)
                end
            elseif origThreshold[name] ~= nil then
                local v = origThreshold[name]
                pcall(function() t.player_wakeup_threshold = v end)
                origThreshold[name] = nil
            end
        end
    end
end

-- Phase timers ("phases" mode). Reveal = small beep on the turrets that changed.
local function beep(t)
    pcall(function() readProp(t, "DetectionAudio"):Play(0.0) end)
end

local function updatePhases()
    if not cfg.enabled or cfg.mode ~= "phases" then return end
    local now = os.time()
    if not cfg.phasePerTurret then
        if phase.global == nil then phaseOf(nil) end
        if now >= phase.globalUntil then
            phase.global = (phase.global == "ally") and "hostile" or "ally"
            local d = phaseDuration()
            phase.globalUntil = now + d
            log("PHASE (all turrets) -> %s for %d s", phase.global, d)
            if cfg.revealPhase then
                for _, t in ipairs(findAll(cfg.turretClass)) do
                    if readProp(t, "is_awake") == true then beep(t) end
                end
            end
        end
        return
    end
    for _, t in ipairs(findAll(cfg.turretClass)) do
        phaseOf(t)
        local st = phase.turrets[shortName(t)]
        if st and now >= st.untilT then
            st.ph = (st.ph == "ally") and "hostile" or "ally"
            st.untilT = now + phaseDuration()
            count("phase_switch_" .. st.ph)
            if cfg.revealPhase and readProp(t, "is_awake") == true then beep(t) end
        end
    end
end

-- One-time dump of each monster class's properties (to find states such as the
-- ghost's IsFrozen or the Eye's HaveShield). Separate file.
local dumpedMonsterClass = {}
local DUMP_PATH = modDir() .. "\\monsters_dump.log"
local SIMPLE = { BoolProperty = true, ByteProperty = true, EnumProperty = true, IntProperty = true,
                 FloatProperty = true, DoubleProperty = true, NameProperty = true, ObjectProperty = true }

local function dumpMonsters()
    if not cfg.dumpMonsterClasses then return end
    for _, m in ipairs(liveList(cache.allMonsters)) do
        local cn = className(m)
        if valid(m) and not dumpedMonsterClass[cn] then
            dumpedMonsterClass[cn] = true
            local f = io.open(DUMP_PATH, "a")
            if f then
                f:write("==== ", os.date("%H:%M:%S"), " ", cn, " (", shortName(m), ")\n")
                local c = safe(function() return m:GetClass() end)
                local guard = 0
                while valid(c) and guard < 10 do
                    local ccn = shortName(c)
                    if ccn == "Character" then break end
                    f:write("  [", ccn, "]\n")
                    pcall(function()
                        c:ForEachProperty(function(prop)
                            local ty = safe(function() return prop:GetClass():GetFName():ToString() end) or "?"
                            if SIMPLE[ty] then
                                local pn = shortName(prop)
                                local v = readProp(m, pn)
                                local sv
                                if type(v) == "userdata" then
                                    sv = valid(v) and shortName(v) or (safe(function() return v:ToString() end) or "None")
                                else sv = tostring(v) end
                                f:write(string.format("    %-40s %-15s = %s\n", pn, ty, tostring(sv)))
                            end
                        end)
                    end)
                    local cur = c
                    c = safe(function() return cur:GetSuperStruct() end)
                    guard = guard + 1
                end
                f:close()
                log("Monster class described in monsters_dump.log: %s", cn)
            end
        end
    end
end

-- v0.8.9 diagnostic: which functions deal / receive bullet damage? (to stop turret
-- bullets from hurting players in the line of fire). One-time dump into damage_dump.log:
-- every function of the turret and player classes (and their parents) whose name looks
-- damage-related, with its parameters.
local DAMAGE_DUMP_PATH = modDir() .. "\\damage_dump.log"
local DAMAGE_WORDS = { "damage", "hit", "hurt", "health", "shoot", "bullet", "fire", "impact",
                       "kill", "die", "death", "injur", "wound", "trace", "projectile" }
local damageDumped = false

local function looksDamage(n)
    local low = n:lower()
    for _, w in ipairs(DAMAGE_WORDS) do if low:find(w, 1, true) then return true end end
    return false
end

local function dumpClassFunctions(f, cls, stopAt)
    local c, guard = cls, 0
    while valid(c) and guard < 12 do
        local cn = shortName(c)
        if cn == stopAt then break end
        f:write("  [", cn, "]\n")
        pcall(function()
            c:ForEachFunction(function(fn)
                local n = shortName(fn)
                if looksDamage(n) then
                    local params = {}
                    pcall(function()
                        fn:ForEachProperty(function(prop)
                            local ty = safe(function() return prop:GetClass():GetFName():ToString() end) or "?"
                            params[#params + 1] = shortName(prop) .. ":" .. ty
                        end)
                    end)
                    f:write("    ", n, "(", table.concat(params, ", "), ")\n")
                end
            end)
        end)
        local cur = c
        c = safe(function() return cur:GetSuperStruct() end)
        guard = guard + 1
    end
end

local function dumpDamageFunctions()
    if damageDumped or not cfg.dumpDamageFunctions then return end
    local turretCls = safe(function() return StaticFindObject(cfg.turretClassPath) end)
    local p = liveList(cache.players)[1]
    local playerCls = p and safe(function() return p:GetClass() end)
    if not valid(turretCls) or not valid(playerCls) then return end
    damageDumped = true
    local f = io.open(DAMAGE_DUMP_PATH, "w")
    if not f then return end
    f:write("AlliedDefense v", VERSION, " damage dump ", os.date("%Y-%m-%d %H:%M:%S"), "\n")
    f:write("== Turret ", shortName(turretCls), "\n")
    dumpClassFunctions(f, turretCls, "Actor")
    f:write("== Player ", shortName(playerCls), "\n")
    dumpClassFunctions(f, playerCls, "Object")
    f:close()
    log("Damage functions described in damage_dump.log")
end

---------------------------------------------------------------------------
-- v0.9.0: turret bullets no longer hurt players while the turret is ALLIED
-- (a hostile turret - "phases" hostile phase, "chaos" - still hurts, as asked).
-- Pre hooks on the player's damage entry points (from damage_dump.log): when the
-- DamageCauser is a turret (or owned by one) whose behaviour is "ally", Damage -> 0.
---------------------------------------------------------------------------
local dmgHooks = { classAddr = {}, installed = {}, list = {}, failLogged = {}, lastTry = -100 }
local dmgSeen = {}    -- first call per function+causer class, logged once (diagnostic)
-- v0.9.1: zeroing Damage in ReceivePointDamage/ReceiveAnyDamage (engine events) was not
-- enough (v0.9.0 test: blocked counted, damage still taken). The hit is now only MARKED
-- there; the player's own Blueprint damage chain (GetDamageEvent, CheckDamage...) called
-- right after gets Damage = 0 while the mark is fresh.
local allyHit = {}   -- player address -> { t = os.clock(), health = value before the hit }
local healthLogs = 0

local function turretFromCauser(c)
    if not valid(c) then return nil end
    if className(c) == cfg.turretClass then return c end
    local o = safe(function() return c:GetOwner() end)
    if valid(o) and className(o) == cfg.turretClass then return o end
    return nil
end

local function makeDamageHook(fnName)
    return function(ctx, ...)
        if not cfg.protectPlayersFromAllyFire then return end
        local args = { ... }
        -- find the Damage / DamageReceived and DamageCauser parameters by position
        local dmgIdx, causerIdx
        if fnName == "HitDamageFromMonster" then dmgIdx, causerIdx = 2, 4
        elseif fnName == "BPI_DamageSpecial_SetDamage" then dmgIdx, causerIdx = 1, 3
        elseif fnName == "ReceivePointDamage" then dmgIdx, causerIdx = 1, 9
        elseif fnName == "ReceiveAnyDamage" then dmgIdx, causerIdx = 1, 4
        else return end
        local causer = getParam(args[causerIdx])
        local key = fnName .. "|" .. (valid(causer) and className(causer) or "None")
        if not dmgSeen[key] and cfg.verbose then
            dmgSeen[key] = true
            log("DAMAGE seen: %s from %s (damage %s)", fnName, tag(causer), tostring(getParam(args[dmgIdx])))
        end
        local t = turretFromCauser(causer)
        if not t then return end
        if behaviourOf(t) ~= "ally" then count("turret_damage_allowed_hostile") return end
        local self = getSelf(ctx)
        local a = addr(self)
        if a then
            local prev = allyHit[a]
            local keep = prev and not prev.restored
            allyHit[a] = { t = os.clock(), health = (keep and prev.health) or readProp(self, "Health"),
                           self = entry(self), logged = prev and prev.logged }
        end
        count("ally_hit_marked_" .. fnName)
        setParam(args[dmgIdx], 0.0)   -- harmless if ignored by the engine
    end
end

local chainSeen = {}
local function makeChainHook(fnName, dmgIdx)
    return function(ctx, ...)
        if not cfg.protectPlayersFromAllyFire then return end
        local self = getSelf(ctx)
        local a = addr(self)
        local mark = a and allyHit[a]
        if not mark or (os.clock() - mark.t) > cfg.allyFireWindowSeconds then return end
        local args = { ... }
        local before = getParam(args[dmgIdx])
        if setParam(args[dmgIdx], 0.0) then
            count("turret_damage_zeroed_" .. fnName)
            if not chainSeen[fnName] and cfg.verbose then
                chainSeen[fnName] = true
                log("DAMAGE chain: %s damage %s -> 0 (ally turret hit)", fnName, tostring(before))
            end
        else count("ERR_chain_" .. fnName) end
    end
end

-- v0.9.4: zeroing the Damage parameters is NOT enough (v0.9.3 test: chain zeroed, health
-- still 92.5 -> 90.25). Fallback that works whatever the game does internally: the health
-- the player had before an allied turret hit is restored right after the hit (fast loop,
-- 0.1 s). Side effect: other damage taken in that same 0.1-0.3 s is also undone (rare).
local function restoreAllyHits()
    if not cfg.restoreHealthFromAllyFire then return end
    local now = os.clock()
    for a, mark in pairs(allyHit) do
        if not mark.restored and (now - mark.t) >= 0.05 and type(mark.health) == "number" then
            local p = live(mark.self)
            local h = p and readProp(p, "Health")
            if type(h) == "number" and h > 0 and h < mark.health then
                local before = mark.health
                if pcall(function() p.Health = before end) then
                    pcall(function() p:HealthHandle(before) end)   -- refresh HUD / effects (host)
                    count("ally_hit_health_restored")
                    if healthLogs < 5 and cfg.verbose then
                        healthLogs = healthLogs + 1
                        log("DAMAGE restore: health %.2f -> %.2f (ally turret hit)", h, before)
                    end
                else count("ERR_health_restore") end
            end
            mark.restored = true
        end
    end
end

restoreHookFn = function() if next(allyHit) ~= nil then restoreAllyHits() end end

-- Diagnostic: did the player's Health really stay the same after an ally hit? (5 lines max)
local function checkAllyHits()
    local now = os.clock()
    for a, mark in pairs(allyHit) do
        if now - mark.t > 0.6 then
            if healthLogs < 5 and not mark.logged and cfg.verbose then
                local p = live(mark.self)
                local h = p and readProp(p, "Health")
                healthLogs = healthLogs + 1
                log("DAMAGE check: health before ally hit %s, now %s", tostring(mark.health), tostring(h))
            end
            allyHit[a] = nil
        end
    end
end

-- v0.9.3: the v0.9.0-0.9.2 version looked every function name up with StaticFindObject
-- every 2 s; names that do not exist in a class cost ~5-10 ms each => 50-90 ms every 2 s
-- (the micro freezes). Each class's functions are now listed once (ForEachFunction), and
-- once everything is installed the player class is only re-checked every 15 s.
local function tryRegisterDamageHooks()
    if not cfg.protectPlayersFromAllyFire then return end
    local now = os.clock()
    local interval = dmgHooks.complete and 15 or 3
    if (now - dmgHooks.lastTry) < interval then return end
    dmgHooks.lastTry = now
    local p = liveList(cache.players)[1]
    if not p then return end
    dmgHooks.fnNames = dmgHooks.fnNames or {}
    local complete = true
    local c = safe(function() return p:GetClass() end)
    local guard = 0
    while valid(c) and guard < 10 do
        local cn = shortName(c)
        if inList(cn, cfg.damageHookClasses) then
            local a = addr(c)
            if dmgHooks.classAddr[cn] ~= a then
                -- new or reloaded class: hooks on the old one are gone with it
                dmgHooks.classAddr[cn] = a
                dmgHooks.fnNames[cn] = nil
                for k in pairs(dmgHooks.installed) do
                    if k:find(":" .. cn .. ":", 1, true) then dmgHooks.installed[k] = nil end
                end
            end
            if not dmgHooks.fnNames[cn] then
                local set = {}
                pcall(function() c:ForEachFunction(function(f) set[shortName(f)] = true end) end)
                dmgHooks.fnNames[cn] = set
            end
            local names = dmgHooks.fnNames[cn]
            local path = (safe(function() return c:GetFullName() end) or ""):gsub("^%S+%s+", "")
            local todo = {}
            for _, fnName in ipairs(cfg.damageHookFunctions) do todo[#todo + 1] = { fnName, makeDamageHook } end
            for fnName, idx in pairs(cfg.damageChainFunctions) do
                todo[#todo + 1] = { fnName, function(n) return makeChainHook(n, idx) end }
            end
            for _, item in ipairs(todo) do
                local fnName, maker = item[1], item[2]
                local key = ":" .. cn .. ":" .. fnName
                if names[fnName] and not dmgHooks.installed[key] then
                    local fpath = path .. ":" .. fnName
                    local hook = maker(fnName)
                    local ok, pre, post = pcall(RegisterHook, fpath, function(ctx, ...)
                        timed("dmg:" .. fnName, hook, ctx, ...)
                    end)
                    if ok then
                        dmgHooks.installed[key] = true
                        dmgHooks.list[#dmgHooks.list + 1] = { path = fpath, pre = pre, post = post }
                        log("Damage hook installed: %s:%s", cn, fnName)
                    else
                        complete = false   -- retried on the next pass (class not linked yet)
                        if not dmgHooks.failLogged[fpath] then
                            dmgHooks.failLogged[fpath] = true
                            log("Damage hook not ready yet: %s:%s - will retry", cn, fnName)
                        end
                    end
                end
            end
        end
        local cur = c
        c = safe(function() return cur:GetSuperStruct() end)
        guard = guard + 1
    end
    dmgHooks.complete = complete
end

local function flushPerf()
    if not cfg.debugLogs then perf.parts = {} return end
    if (os.clock() - perf.lastLog) < 30 then return end
    perf.lastLog = os.clock()
    local names = {}
    for k in pairs(perf.parts) do names[#names + 1] = k end
    table.sort(names)
    local out = {}
    for _, k in ipairs(names) do
        local p = perf.parts[k]
        if p.max >= 1 then
            out[#out + 1] = string.format("%s=%.1f/%.0f", k, p.total / math.max(p.n, 1), p.max)
        end
    end
    if #out > 0 then log("PERF 30s (avg/max ms, parts >= 1 ms): %s", table.concat(out, "  ")) end
    perf.parts = {}
end

local function background()
    local steps = {
        { "hooks", tryRegisterHooks }, { "lists", refreshLists, true },
        { "dmgHooks", tryRegisterDamageHooks }, { "restore", restoreHookFn }, { "allyHits", checkAllyHits },
        { "phases", updatePhases }, { "settings", applyTurretSettings }, { "wake", wakeTurrets },
        { "purge", purgeAllPlayers }, { "inject", injectAll }, { "dumpMonsters", dumpMonsters },
        { "dumpDamage", dumpDamageFunctions },
    }
    local total, parts = 0, {}
    -- the snapshot holds UObjects: it must NEVER survive this tick, even after an error
    tickSnap = nil
    local okSnap = pcall(function()
        refreshLists(true)
        tickSnap = monstersNow()
    end)
    if not okSnap then tickSnap = nil end
    local okSteps, errSteps = pcall(function()
        for _, st in ipairs(steps) do
            local dt = timed(st[1], st[2], st[3])
            total = total + dt
            if dt >= 5 then parts[#parts + 1] = string.format("%s=%.0f", st[1], dt) end
        end
    end)
    tickSnap = nil
    if not okSteps then logErr("background steps", errSteps) end
    if cfg.debugLogs and total >= 30 then log("SLOW background tick: %.0f ms (%s)", total, table.concat(parts, " ")) end
    flushStats(false)
    flushPerf()
end

-- v0.9.6: the 100 ms LoopAsync + ExecuteInGameThread of v0.9.4 was removed (two crashes
-- inside UE4SS right after it was added, one in the hangar with nothing happening). The
-- health is now restored from the turret's own shoot hooks (game thread, every shot) and
-- from the 1 s background loop as a fallback.
LoopAsync(cfg.backgroundIntervalMs, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(background)
        if not ok then logErr("background", err) end
    end)
    return false
end)

---------------------------------------------------------------------------
-- Key bindings
---------------------------------------------------------------------------
local function bind(keyName, fn, label)
    local k = Key and Key[keyName]
    if not k then log("Unknown key '%s' for %s", tostring(keyName), label) return end
    local cb = function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then logErr(label, err) end
        end)
    end
    local mod = cfg.modifier and ModifierKey and ModifierKey[cfg.modifier]
    local ok, err
    if mod then ok, err = pcall(RegisterKeyBind, k, { mod }, cb)
    else ok, err = pcall(RegisterKeyBind, k, cb) end
    if not ok then log("Could not register %s: %s", label, tostring(err)) end
end

bind(cfg.toggleKey, function()
    flushStats(true)
    cfg.enabled = not cfg.enabled
    lastTrg = {}
    log("AlliedDefense: %s", cfg.enabled and "ENABLED" or "DISABLED (vanilla behaviour)")
end, "toggle")

-- Inspector (Ctrl+F8): dumps the internal state of the turrets closest to a monster
-- (or to the player when no monster is around) into the log. Used to find out why
-- some monsters (BigRobot, drones) are never selected as targets.
local INSPECT_PROPS = { "is_awake", "behaviour_state", "can_see", "rep_is_trg_visible",
    "is_gameprogress_locked", "is_neighbour_locked", "srv_power_on", "auto_awake",
    "wait_for_shoot", "keep_shooting", "player_wakeup_threshold", "monster_wakeup_threshold",
    "creep_wakeup_threshold", "pawn_detection_radius", "Max Distance" }

local function fmtVal(v)
    if type(v) == "userdata" then
        if valid(v) then return tag(v) end
        local s = safe(function() return v:ToString() end)
        return s and ('"' .. s .. '"') or "None"
    end
    return tostring(v)
end

local function dumpMap(t, prop)
    local map = readProp(t, prop)
    if map == nil then log("    %s: <unreadable>", prop) return end
    local rows = {}
    local ok = pcall(function()
        map:ForEach(function(k, v)
            local key = safe(function() return k:get() end)
            local val = safe(function() return v:get() end)
            rows[#rows + 1] = tag(key) .. " = " .. fmtVal(val)
        end)
    end)
    if not ok then log("    %s: <ForEach failed>", prop) return end
    log("    %s: %d entr%s", prop, #rows, #rows == 1 and "y" or "ies")
    for _, r in ipairs(rows) do log("      %s", r) end
end

local function inspect()
    refreshLists(true)
    local monsters = liveList(cache.allMonsters)
    local players = liveList(cache.players)
    -- reference points: living targetable monsters first (dead zombies would flood the list)
    local living = {}
    for _, m in ipairs(monsters) do if isTargetable(m) then living[#living + 1] = m end end
    local refs = (#living > 0) and living or players
    local rows = {}
    for _, t in ipairs(findAll(cfg.turretClass)) do
        local best, bestRef = math.huge, nil
        for _, r in ipairs(refs) do
            local d = dist2(t, r)
            if d < best then best, bestRef = d, r end
        end
        rows[#rows + 1] = { t = t, d = best, ref = bestRef }
    end
    table.sort(rows, function(a, b) return a.d < b.d end)
    log("==== INSPECT (mode %s, %d monsters, %d players, %d turrets) ====",
        cfg.mode, #monsters, #players, #rows)
    local dead = 0
    for _, m in ipairs(monsters) do
        if isTargetable(m) then
            log("  monster %s  targetable=true", tag(m))
        else
            dead = dead + 1
        end
    end
    log("  (+ %d dead / untargetable monsters not listed)", dead)
    for i = 1, math.min(cfg.inspectCount, #rows) do
        local r = rows[i]
        local t = r.t
        log("  TURRET %s  dist=%.0f cm to %s  behaviour=%s", shortName(t),
            math.sqrt(r.d), tag(r.ref), tostring(behaviourOf(t)))
        local parts = {}
        for _, pn in ipairs(INSPECT_PROPS) do parts[#parts + 1] = pn .. "=" .. fmtVal(readProp(t, pn)) end
        log("    %s", table.concat(parts, "  "))
        log("    current_trg=%s  previous_trg=%s", fmtVal(readProp(t, "current_trg")),
            fmtVal(readProp(t, "previous_trg")))
        dumpMap(t, "potential_trgs")
        dumpMap(t, "agro_table")
    end
    log("==== END INSPECT ====")
end

local function describeMode()
    if cfg.mode ~= "phases" then return cfg.mode end
    return string.format("phases (%s, %s, %d-%d s)",
        cfg.phasePerTurret and "per turret" or "global",
        cfg.revealPhase and "revealed" or "hidden",
        cfg.phaseMinSeconds, cfg.phaseMaxSeconds)
end

bind(cfg.modeKey, function()
    local list = cfg.modeCycle
    local idx = 1
    for i, m in ipairs(list) do if m == cfg.mode then idx = i break end end
    cfg.mode = list[(idx % #list) + 1]
    if not VALID_MODES[cfg.mode] then cfg.mode = "ally" end
    phase.global, phase.turrets = nil, {}
    lastTrg = {}
    flushStats(true)
    log("MODE -> %s", describeMode())
end, "mode")

bind(cfg.inspectKey, inspect, "inspect")

bind(cfg.verboseKey, function()
    cfg.verbose = not cfg.verbose
    log("Verbose logs: %s", cfg.verbose and "ON" or "OFF")
end, "verbose")

local prefix = cfg.modifier and (cfg.modifier .. "+") or ""
log("AlliedDefense v%s loaded (%s, mode %s). %s%s = on/off, %s%s = next mode, %s%s = inspect, %s%s = verbose logs. Log: %s",
    VERSION, cfg.enabled and "enabled" or "disabled", describeMode(),
    prefix, cfg.toggleKey, prefix, cfg.modeKey, prefix, cfg.inspectKey, prefix, cfg.verboseKey, LOG_PATH)

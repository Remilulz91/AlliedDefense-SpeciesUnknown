-- AlliedDefense / turrets.lua - Turret hooks, explosive canisters, background loop, monster injection into potential_trgs.
-- Loaded by main.lua into the mod's shared environment: a top-level name set in any file
-- is visible to the files loaded after it (no "local" at file level: Lua caps a chunk at
-- 200 locals, which the single main.lua had reached).

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
function getSelf(ctx) return safe(function() return ctx:get() end) end
function getParam(p) return safe(function() return p:get() end) end
function setParam(p, v) return pcall(function() p:set(v) end) end

-- Diagnostic: is the player inside the turret's potential_trgs map?
-- (tells us which path still puts the player in current_trg). Throttled.
probeAt = {}
function probePotentialTargets(t, name)
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
mapRemoveBroken = false
learnDataClassHook = nil   -- set by the injector (v0.8.7): learn OBJ_SentryTrgData_C before purging
function purgePlayersFromPotential(t, statKey)
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
playerTargetLogAt = {}
function logPlayerTarget(t, name, where, newTarget)
    local now = os.clock()
    if (now - (playerTargetLogAt[name] or -100)) < 5 then return end
    playerTargetLogAt[name] = now
    if cfg.verbose then
        log("TARGET %s -> player (via %s), replaced by %s", name, where, tag(newTarget))
    end
end

-- v1.3.3: a turret whose player target was dropped normally re-selects a target
-- (SelectTrg) within ~1 s. Sometimes it does not: it stays out, frozen, servo sound looping,
-- until the next phase lets it shoot the player again (BigRobot game, 08/11, turret ...530
-- frozen 20:07:48 -> 20:11:02). We remember the drop; SelectTrg clears it; the background
-- tick closes a turret still waiting after stuckSeconds (it reopens normally later).
stuck = {}   -- turret name -> { e = entry, at = os.clock() }

-- If the current target is a player, swap it for the nearest monster (or drop it).
function fixPlayerTarget(t, where)
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
        if ok and not stuck[name] then
            local e = entry(t)
            if e then stuck[name] = { e = e, at = os.clock() } end
        end
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
function preAddToAgro(ctx, pTrg, pValue, pInit)
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
function friendSubstitute(t)
    for _, m in ipairs(liveList(cache.friendSubs)) do
        if valid(m) then return m end
    end
    return t   -- fallback: the turret itself
end

-- v1.1.0 canisters: defined further down (forward declarations, used by IsFriend)
canisters = { list = {}, armed = {} }
-- (shared) isCanister, canisterIsArmedNow

function preIsFriend(ctx, pActor)
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
function preSetPlayerThreshold(ctx, pThreshold)
    local t = getSelf(ctx)
    local b = behave(t)
    if (b ~= "ally" and b ~= "neutral") or not cfg.blockPlayerWake then return end
    if setParam(pThreshold, cfg.playerWakeThreshold) then count("player_threshold_forced") end
end

-- TryToWakeUp(Enemy): a player no longer wakes the turret up; if a monster is in
-- range, the monster wakes it up instead.
function preTryToWakeUp(ctx, pEnemy)
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
lastTrg = {}
function addNearbyMonsters(t)
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

function dropAnyTarget(t)
    if valid(readProp(t, "current_trg")) then
        if pcall(function() t.current_trg = nil end) then count("neutral_target_dropped") end
    end
end

function preSelectTrg(ctx)
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

---------------------------------------------------------------------------
-- v1.1.0: explosive canisters (fire / frost). An ALLIED turret treats an explosive
-- canister lying next to a monster as a target, as long as no player stands in the blast.
-- Canister facts (canister_dump.log, v1.0.1-diag):
--   BP_HoldItem_ExplosiveCanister_Fire_C (Frost_C is a child), Health = 6,
--   HaveExploded, IsGrabbed; damage -> ReceiveAnyDamage -> Explosion(Instigator).
-- test3: a shot of an allied turret at a monster it SEES also hits an armed canister lying
-- next to that monster (game damage -> the canister's own Health / Explosion logic).
-- Tests: test1 swapped current_trg (the turret switched back within 1 s) and forced the
-- explosion after 4 s (explosions through walls); test2 added the canister to the turret's
-- target lists, but the turret's own selection ignores non-pawns (never aimed at it).
-- Canisters are listed once per background tick as {path, addr, x, y, z} (never as
-- UObjects) and re-validated right before use.
---------------------------------------------------------------------------
isCanister = function(o)
    return valid(o) and className(o):find("ExplosiveCanister", 1, true) ~= nil
end

function canisterArmed(c)
    if not valid(c) then return false end
    if readProp(c, "HaveExploded") == true or readProp(c, "IsGrabbed") == true then return false end
    return not valid(safe(function() return c:GetAttachParentActor() end))
end

function playerNear(x, y, z, r)
    local r2 = r * r
    for _, p in ipairs(liveList(cache.players)) do
        local px, py, pz = location(p)
        if px and ((px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2) <= r2 then return true end
    end
    return false
end

-- list  = every canister not exploded yet (on the ground OR carried by a player)
-- armed = the ones an ALLIED turret may hit: on the ground, next to a monster, nobody in the blast
-- (v1.2.0: a HOSTILE turret - "phases" hostile phase, "chaos" - may hit any of the list,
--  even one a player is carrying: shooting a player holding a canister blows it up)
function refreshCanisters()
    canisters.list, canisters.armed = {}, {}
    if not cfg.enabled or not cfg.shootCanisters then return end
    if cfg.mode == "vanilla" or cfg.mode == "neutral" then return end
    local snap = monstersNow()
    local tr2 = cfg.canisterTriggerRadius ^ 2
    for _, c in ipairs(findAll(cfg.canisterClass)) do
        if readProp(c, "HaveExploded") ~= true then
            local x, y, z = location(c)
            local e = x and entry(c)
            if e then
                e.x, e.y, e.z = x, y, z
                canisters.list[#canisters.list + 1] = e
                local near = false
                for _, m in ipairs(snap) do
                    if ((m.x - x) ^ 2 + (m.y - y) ^ 2 + (m.z - z) ^ 2) <= tr2 then near = true break end
                end
                if near and canisterArmed(c) and not playerNear(x, y, z, cfg.canisterSafeRadius) then
                    canisters.armed[e.path] = true
                end
            end
        end
    end
end

canisterIsArmedNow = function(c)
    if not canisterArmed(c) then return false end
    local e = entry(c)
    if not e or not canisters.armed[e.path] then return false end
    local x, y, z = location(c)
    return x ~= nil and not playerNear(x, y, z, cfg.canisterSafeRadius)
end

-- Each real shot (Handle_Shoot, server side) of a turret at a target it sees: the canister
-- nearest to that target (within canisterTriggerRadius) takes the bullet damage.
--   allied turret : monster targets only, never with a player in the blast
--   hostile turret: its target (player or monster), no safety - that is the point
canHitLogged = {}
function canisterShot(t, hostile)
    if #canisters.list == 0 then return end
    local m = readProp(t, "current_trg")
    local k = kindOf(m)
    if hostile then
        if k ~= "monster" and k ~= "player" then return end
    elseif k ~= "monster" or not isTargetable(m) then return end
    if readProp(t, "is_awake") == false or readProp(t, "rep_is_trg_visible") == false then return end
    local mx, my, mz = location(m)
    if not mx then return end
    local tr2 = cfg.canisterTriggerRadius ^ 2
    local best, bd = nil, math.huge
    for _, e in ipairs(canisters.list) do
        local d = (e.x - mx) ^ 2 + (e.y - my) ^ 2 + (e.z - mz) ^ 2
        if d <= tr2 and d < bd then best, bd = e, d end
    end
    if not best then return end
    local c = live(best)
    if hostile then
        if not valid(c) or readProp(c, "HaveExploded") == true then return end
    elseif not canisterIsArmedNow(c) then return end
    local before = readProp(c, "Health")
    local how = nil
    local gs = safe(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
    if valid(gs) and pcall(function() gs:ApplyDamage(c, cfg.canisterShotDamage, nil, t, nil) end) then
        how = "ApplyDamage"
    elseif pcall(function() c:ReceiveAnyDamage(cfg.canisterShotDamage, nil, nil, t) end) then
        how = "ReceiveAnyDamage"
    end
    if not how then count("ERR_canister_hit") return end
    count(hostile and "canister_hit_hostile" or "canister_hit")
    if cfg.verbose and not canHitLogged[best.path] then
        canHitLogged[best.path] = true
        log("CANISTER %s hit by %s %s (shooting %s, %.0f cm away) via %s: health %s -> %s",
            shortName(c), hostile and "HOSTILE" or "allied", shortName(t), shortName(m), math.sqrt(bd), how,
            tostring(before), tostring(readProp(c, "Health")))
    end
end


-- Right before aiming/shooting: a player target is dropped (ally) / any target (neutral).
restoreHookFn = nil   -- set once restoreAllyHits exists (v0.9.6)
colorHookFn = nil     -- set once applyColor exists (v1.3.0)
-- v1.4.3: a monster that became untargetable while being the target (the ghost when its
-- freeze wears off, the Eye raising its shield) is dropped. The game never re-checks its
-- target: the turret stayed locked on the unfrozen ghost, green and silent, until it left.
function fixUntargetableTarget(t, where)
    local cur = readProp(t, "current_trg")
    if kindOf(cur) ~= "monster" or isTargetable(cur) then return false end
    local ok = pcall(function() t.current_trg = nil end)
    count(ok and ("untargetable_target_dropped_" .. where) or "ERR_drop_untargetable")
    if ok then
        local name = shortName(t)
        if not stuck[name] then
            local e = entry(t)
            if e then stuck[name] = { e = e, at = os.clock() } end
        end
        -- (the game picks it again many times a second: one line per turret every 3 s)
        untargetableLogged = untargetableLogged or {}
        local now = os.clock()
        if cfg.verbose and (untargetableLogged[name] or -1e9) + 3 < now then
            untargetableLogged[name] = now
            log("TARGET %s -> %s no longer targetable (%s), dropped", name, tag(cur), where)
        end
    end
    return ok
end

function preShootInner(ctx)
    if restoreHookFn then pcall(restoreHookFn) end
    local t = getSelf(ctx)
    local b = behave(t)
    if b ~= nil and valid(t) and hasAuthority(t) then pcall(fixUntargetableTarget, t, "shoot") end
    if b == "neutral" then dropAnyTarget(t) return end
    if b ~= "ally" or not cfg.ignorePlayers then return end
    purgePlayersFromPotential(t)
    fixPlayerTarget(t, "shoot")
end

-- v1.3.0: colours follow the target right away (not only on the 1 s background tick)
function preShoot(ctx)
    preShootInner(ctx)
    if colorHookFn then
        local t = getSelf(ctx)
        if valid(t) then pcall(colorHookFn, t, shortName(t)) end
    end
end

-- v1.1.0: real shots only (Handle_Shoot): also hit an armed canister next to the target
function preShootFire(ctx)
    preShoot(ctx)
    -- v1.4.2: turret upgrades (upgrades.lua) set the fire rate from its target
    if applyUpgradeDamage then
        local t0 = getSelf(ctx)
        if valid(t0) and hasAuthority(t0) then
            local okU, errU = pcall(applyUpgradeDamage, t0)
            if not okU and upgLogOnce then upgLogOnce("dmgerr", "UPGRADES: damage step failed: %s", tostring(errU)) end
        end
    end
    if not cfg.shootCanisters then return end
    local t = getSelf(ctx)
    if not valid(t) or not hasAuthority(t) or not cfg.enabled then return end
    local b = behave(t)
    if b == "ally" then pcall(canisterShot, t, false)
    elseif cfg.hostileShootCanisters and (b == "chaos" or (b == nil and cfg.mode == "phases")) then
        pcall(canisterShot, t, true)
    end
end

function logTarget(t)
    if not cfg.verbose or not valid(t) then return end
    local name = shortName(t)
    local s = tag(readProp(t, "current_trg"))
    if lastTrg[name] ~= s then
        lastTrg[name] = s
        log("TARGET %s -> %s", name, s)
    end
end

HOOKS = {
    { fn = "IsFriend",                pre = preIsFriend },
    { fn = "BPI_SentryGun_SetPlayerWakeUpThreshold_1", pre = preSetPlayerThreshold },
    { fn = "AddToAgroTable",          pre = preAddToAgro },
    { fn = "TryToWakeUp",             pre = preTryToWakeUp },
    { fn = "SelectTrg",               pre = preSelectTrg },
    { fn = "Handle_Shoot (SRV side)", pre = preShootFire },
    { fn = "CurrentTrg_Handle",       pre = preShoot },
}

-- Presence sensor (PawnDetectionSphere): a player entering/leaving the sphere is
-- replaced by None => never enters potential_trgs, the turret no longer "sees" them.
function preSensor(ctx, pComp, pOther)
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

function sensorFunctions(cls)
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

hookState = { classAddr = nil, list = {}, pending = {}, tries = 0, lastTry = -100, failLogged = {} }
sensorNames = { begin = nil, finish = nil }   -- sensor overlap events (used by the injector)

-- v0.8.4: right after the level loads, the turret class can be found while its Blueprint
-- functions are not linked yet ("UFunction::Func: 0x0"): RegisterHook fails. v0.8.3 never
-- retried (every hook failed for a whole game). Failed hooks are now retried every 2 s.
function installHook(spec)
    local path = cfg.turretClassPath .. ":" .. spec.fn
    local fn = spec.pre
    local perfName = "hook:" .. (spec.fn:find("PawnDetectionSphere", 1, true) and "Sensor" or spec.fn)
    local ok, pre, post = pcall(RegisterHook, path, function(ctx, ...)
        timed(perfName, fn, ctx, ...)
        if spec.fn == "SelectTrg" then
            local st = getSelf(ctx)
            if valid(st) then stuck[shortName(st)] = nil end
            pcall(logTarget, st)
        end
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
hookCheck = { last = -100 }
function tryRegisterHooks()
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
wakeAt = {}   -- turret -> last attempt
-- v0.8.6 diagnostic: does TryToWakeUp(monster) actually open the turret?
-- pending[name] = { t0, monster class, dist } ; checked on the next background passes.
wakePending = {}
wakeLogs = 0
WAKE_LOG_MAX = 15
wakeNoEffectLogged = {}   -- one "no effect" line per turret

function lockState(t)
    return string.format("gameprogress_locked=%s neighbour_locked=%s power_on=%s behaviour_state=%s",
        tostring(readProp(t, "is_gameprogress_locked")), tostring(readProp(t, "is_neighbour_locked")),
        tostring(readProp(t, "srv_power_on")), tostring(readProp(t, "behaviour_state")))
end

function checkWakeResult(t, name, now)
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

function wakeTurrets()
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
inj = {
    turrets = {},          -- turret name -> { [monster path] = { e = entry, how = "event"|"construct" } }
    dataCls = nil,         -- OBJ_SentryTrgData_C class (taken from an existing map value)
    described = false,     -- OBJ_SentryTrgData_C described once in the log
    eventBroken = false, constructBroken = false,
    loggedClass = {},      -- first success/failure logged once per (class, method)
}

function describeTrgData(v)
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
function learnDataClass(map)
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
function resolveDataClass()
    if valid(inj.dataCls) then return true end
    local c = safe(function() return StaticFindObject(cfg.trgDataClassPath) end)
    if valid(c) then
        inj.dataCls = c
        if cfg.debugLogs then log("TRGDATA class found by path: %s", cfg.trgDataClassPath) end
        return true
    end
    return false
end

function mapHas(map, m) return safe(function() return map:Contains(m) end) == true end

function logOnce(key, fmt, ...)
    if inj.loggedClass[key] then return end
    inj.loggedClass[key] = true
    log(fmt, ...)
end

function injectByEvent(t, m, map)
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

function injectByConstruct(t, m, map)
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

function injectMonsters(t)
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
function purgeAllPlayers()
    if not cfg.purgePlayersInBackground or not cfg.ignorePlayers then return end
    if #cache.players == 0 then return end
    for _, t in ipairs(findAll(cfg.turretClass)) do
        if behave(t) == "ally" then purgePlayersFromPotential(t, "bg_player_removed") end
    end
end

function injectAll()
    if #hookState.pending > 0 or hookState.needSensors then return end   -- wait for the hooks
    -- also runs when disabled / vanilla / neutral, to remove the entries we added
    if #cache.monsters == 0 and next(inj.turrets) == nil then return end
    for _, t in ipairs(findAll(cfg.turretClass)) do
        local ok, err = pcall(injectMonsters, t)
        if not ok then logErr("injectMonsters", err) return end
    end
end

-- Turret colours + player wake threshold: applied while enabled, restored when disabled.
-- v1.3.0: one colour per state (a friend's feedback: the game's green "searching" light
-- looked like "allied"). Two turret properties:
--   search_color : no target, scanning   -> searchColor (amber), neutral -> neutralColor
--   fire_color   : aiming / shooting     -> ally green, chaos purple, neutral grey,
--                                           revealed hostile phase: game red
-- "phases" hidden: the SAME fire colour (green) in both phases, as before (secret kept).
origThreshold = {}
origColor = { fire_color = {}, search_color = {} }
colorErr = {}

function readColor(t, prop)
    local c = readProp(t, prop)
    if c == nil then return nil end
    local r, g, b, a = safe(function() return c.R end), safe(function() return c.G end),
                       safe(function() return c.B end), safe(function() return c.A end)
    if type(r) ~= "number" then return nil end
    return { R = r, G = g, B = b, A = a }
end

function sameColor(x, y)
    return x and y and math.abs(x.R - y.R) < 1e-3 and math.abs(x.G - y.G) < 1e-3 and math.abs(x.B - y.B) < 1e-3
end

function writeColor(t, prop, c)
    local ok, err = pcall(function() t[prop] = { R = c.R, G = c.G, B = c.B, A = c.A or 1.0 } end)
    if not ok and not colorErr[prop] then colorErr[prop] = true logErr(prop, err) end
end

-- Colours wanted for a turret (nil/false = game colour): fire, search
-- test2: the fire colour is only shown while the turret really has a target (an allied
-- turret: a monster). Otherwise fire_color = search colour, so the short "alert" flash of a
-- turret opening (it opens because it saw a player, the mod then drops the player) stays amber.
function wantedColors(t)
    if not cfg.enabled or not cfg.modColours then return nil, nil end
    -- v1.4.1: a client cannot read the host's settings (not replicated), so its own mode is
    -- ignored: always amber scanning / green shooting, as in the default hidden phases
    if not hasAuthority(t) then return cfg.allyFireColor, cfg.searchColor end
    if cfg.mode == "vanilla" then return nil, nil end
    local b = behaviourOf(t)
    if b == "neutral" then return cfg.neutralColor, cfg.neutralColor end
    local fire
    -- a client's phase clock is its own (not the host's): it never "reveals" a phase
    if cfg.mode == "phases" and (not cfg.revealPhase or not hasAuthority(t)) then fire = cfg.allyFireColor
    elseif b == "ally" then fire = cfg.allyFireColor
    elseif b == "chaos" then fire = cfg.chaosFireColor
    else fire = nil end   -- revealed hostile phase: game red when shooting
    -- host only: on a client the turret's target is not known (not replicated), so the
    -- client keeps the fire colour and lets the game switch between search / fire itself
    if hasAuthority(t) then
        local k = kindOf(readProp(t, "current_trg"))
        local hasTarget = (k == "monster") or (k == "player" and b ~= "ally")
        if not hasTarget and cfg.searchColor then fire = cfg.searchColor end
    end
    return fire, cfg.searchColor
end

function applyOne(t, name, prop, want)
    local cur = readColor(t, prop)
    if not cur then return false end
    local orig = origColor[prop]
    if want then
        if not sameColor(cur, want) then
            if orig[name] == nil then orig[name] = cur end
            writeColor(t, prop, want)
            return true
        end
    elseif orig[name] ~= nil then
        writeColor(t, prop, orig[name])
        orig[name] = nil
        return true
    end
    return false
end

-- v1.3.2: the turret only reads fire_color / search_color when its light switches state
-- (Switch_RangLightColor timeline). A new colour therefore showed up only at the next
-- detection (and never on a client until then). Re-running the timeline's update applies
-- the current colours right away, at the light's current search <-> fire blend.
refreshErr = false
function refreshLight(t)
    local ok, err = pcall(function() t:Switch_RangLightColor__UpdateFunc() end)
    if ok then count("light_refreshed")
    elseif not refreshErr then refreshErr = true logErr("light refresh", err) end
end

function applyColor(t, name)
    local fire, search = wantedColors(t)
    local a = applyOne(t, name, "fire_color", fire)
    local b = applyOne(t, name, "search_color", search)
    if a or b then refreshLight(t) end
end
colorHookFn = applyColor

function applyTurretSettings()
    for _, t in ipairs(findAll(cfg.turretClass)) do
        local name = shortName(t)
        pcall(applyColor, t, name)
        if not hasAuthority(t) then goto continue end   -- client: colours only
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
        ::continue::
    end
end

-- Phase timers ("phases" mode). Reveal = small beep on the turrets that changed.
function beep(t)
    pcall(function() readProp(t, "DetectionAudio"):Play(0.0) end)
end

function updatePhases()
    if not cfg.enabled or cfg.mode ~= "phases" then return end
    local now = os.time()
    -- v1.3.4: no turret in this level (lobby, menu, mission without the Sentry Turrets
    -- modifier): the phase clock is paused and restarts from scratch with the next turrets
    if #findAll(cfg.turretClass) == 0 then
        if phase.global ~= nil or next(phase.turrets) ~= nil then
            phase.global, phase.turrets = nil, {}
            log("PHASE paused: no turret in this level")
        end
        return
    end
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
dumpedMonsterClass = {}
DUMP_PATH = modDir() .. "\\monsters_dump.log"
SIMPLE = { BoolProperty = true, ByteProperty = true, EnumProperty = true, IntProperty = true,
                 FloatProperty = true, DoubleProperty = true, NameProperty = true, ObjectProperty = true }

function dumpMonsters()
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
DAMAGE_DUMP_PATH = modDir() .. "\\damage_dump.log"
DAMAGE_WORDS = { "damage", "hit", "hurt", "health", "shoot", "bullet", "fire", "impact",
                       "kill", "die", "death", "injur", "wound", "trace", "projectile" }
damageDumped = false

function looksDamage(n)
    local low = n:lower()
    for _, w in ipairs(DAMAGE_WORDS) do if low:find(w, 1, true) then return true end end
    return false
end

function dumpClassFunctions(f, cls, stopAt)
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

function dumpDamageFunctions()
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

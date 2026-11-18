-- AlliedDefense / protect.lua - Experimental ally-fire protection (off by default).
-- Loaded by main.lua into the mod's shared environment: a top-level name set in any file
-- is visible to the files loaded after it (no "local" at file level: Lua caps a chunk at
-- 200 locals, which the single main.lua had reached).

---------------------------------------------------------------------------
-- v0.9.0: turret bullets no longer hurt players while the turret is ALLIED
-- (a hostile turret - "phases" hostile phase, "chaos" - still hurts, as asked).
-- Pre hooks on the player's damage entry points (from damage_dump.log): when the
-- DamageCauser is a turret (or owned by one) whose behaviour is "ally", Damage -> 0.
---------------------------------------------------------------------------
dmgHooks = { classAddr = {}, installed = {}, list = {}, failLogged = {}, lastTry = -100 }
dmgSeen = {}    -- first call per function+causer class, logged once (diagnostic)
-- v0.9.1: zeroing Damage in ReceivePointDamage/ReceiveAnyDamage (engine events) was not
-- enough (v0.9.0 test: blocked counted, damage still taken). The hit is now only MARKED
-- there; the player's own Blueprint damage chain (GetDamageEvent, CheckDamage...) called
-- right after gets Damage = 0 while the mark is fresh.
allyHit = {}   -- player address -> { t = os.clock(), health = value before the hit }
healthLogs = 0

function turretFromCauser(c)
    if not valid(c) then return nil end
    if className(c) == cfg.turretClass then return c end
    local o = safe(function() return c:GetOwner() end)
    if valid(o) and className(o) == cfg.turretClass then return o end
    return nil
end

function makeDamageHook(fnName)
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

chainSeen = {}
function makeChainHook(fnName, dmgIdx)
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
function restoreAllyHits()
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
function checkAllyHits()
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
function tryRegisterDamageHooks()
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

function flushPerf()
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

-- v1.3.1: colours are NOT replicated (each PC draws its own turret lights), so a friend
-- who joins with the mod installed runs it in "client" mode: colours only, no gameplay
-- (targets, wake-ups, injection, canisters stay the host's job).
clientState = { is = false, logged = nil }
function amClient()
    local t = findAll(cfg.turretClass)[1]
    local c = valid(t) and not hasAuthority(t) or false
    if c ~= clientState.logged then
        clientState.logged = c
        if c then log("CLIENT: joined someone else's game -> colours only (the host's mod handles the turrets)") end
    end
    return c
end

function unstickTurrets()
    if not cfg.enabled or not cfg.unstickTurrets then stuck = {} return end
    local now = os.clock()
    for name, st in pairs(stuck) do
        if (now - st.at) >= cfg.stuckSeconds then
            stuck[name] = nil
            local t = live(st.e)
            if valid(t) and behave(t) == "ally" and not valid(readProp(t, "current_trg"))
               and readProp(t, "is_awake") ~= false then
                if pcall(function() t:Close() end) then
                    count("turret_unstuck")
                    log("UNSTUCK %s: no new target %.0f s after its player target was dropped -> closed",
                        name, now - st.at)
                else
                    count("ERR_unstick")
                end
            end
        end
    end
end

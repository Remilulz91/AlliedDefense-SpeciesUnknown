-- AlliedDefense / keys.lua - Key bindings, inspector, canister diagnostic, startup line.
-- Loaded by main.lua into the mod's shared environment: a top-level name set in any file
-- is visible to the files loaded after it (no "local" at file level: Lua caps a chunk at
-- 200 locals, which the single main.lua had reached).

---------------------------------------------------------------------------
-- Key bindings
---------------------------------------------------------------------------
function bind(keyName, fn, label)
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
-- (shared) inspect, dumpCanisters -- (block-scoped helpers: Lua caps a chunk at 200 locals)
do
INSPECT_PROPS = { "is_awake", "behaviour_state", "can_see", "rep_is_trg_visible",
    "is_gameprogress_locked", "is_neighbour_locked", "srv_power_on", "auto_awake",
    "wait_for_shoot", "keep_shooting", "player_wakeup_threshold", "monster_wakeup_threshold",
    "creep_wakeup_threshold", "pawn_detection_radius", "Max Distance" }

function fmtVal(v)
    if type(v) == "userdata" then
        if valid(v) then return tag(v) end
        local s = safe(function() return v:ToString() end)
        return s and ('"' .. s .. '"') or "None"
    end
    return tostring(v)
end

function dumpMap(t, prop)
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

function inspect()
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
            -- why not: the turret ignores dead monsters, the unfrozen ghost, the shielded Eye
            if dead <= 5 then
                local why = {}
                for _, pn in ipairs({ "IsDead", "IsFrozen", "HaveShield" }) do
                    local v = readProp(m, pn)
                    if v ~= nil then why[#why + 1] = pn .. "=" .. tostring(v) end
                end
                log("  monster %s  targetable=false  %s", tag(m), table.concat(why, "  "))
            end
        end
    end
    if dead > 5 then log("  (+ %d more untargetable monsters not listed)", dead - 5) end
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

---------------------------------------------------------------------------
-- v1.0.1-diag: explosive canisters (Ctrl+F7, read-only, no hook).
-- Can turrets shoot the explosive canisters? A v0.6.1 log once showed a turret
-- targeting BP_HoldItem_ExplosiveCanister_Frost_C. This dump lists every hold item
-- class of the level, then describes the canister classes (parents, properties with
-- values, ALL functions with parameters) and each canister's surroundings.
---------------------------------------------------------------------------
CANISTER_DUMP_PATH = modDir() .. "\\canister_dump.log"
CANISTER_GUESSES = { "BP_HoldItem_ExplosiveCanister_Frost_C", "BP_HoldItem_ExplosiveCanister_Fire_C",
    "BP_HoldItem_ExplosiveCanister_C", "BP_HoldItem_C", "BP_ParentHoldItem_C", "BP_Parent_HoldItem_C",
    "BP_HoldItem_Parent_C" }
CANISTER_WORDS = { "explos", "canister", "bomb", "barrel", "gas", "fuel", "grenade", "mine" }

function looksCanister(n)
    local low = n:lower()
    for _, w in ipairs(CANISTER_WORDS) do if low:find(w, 1, true) then return true end end
    return false
end

function describeClassFull(f, obj, stopAt)
    local c, guard = safe(function() return obj:GetClass() end), 0
    while valid(c) and guard < 12 do
        local cn = shortName(c)
        if cn == stopAt then break end
        f:write("  [", cn, "]\n")
        pcall(function()
            c:ForEachProperty(function(prop)
                local ty = safe(function() return prop:GetClass():GetFName():ToString() end) or "?"
                local pn = shortName(prop)
                local sv = ""
                if SIMPLE[ty] then
                    local v = readProp(obj, pn)
                    if type(v) == "userdata" then
                        sv = valid(v) and shortName(v) or (safe(function() return v:ToString() end) or "None")
                    else sv = tostring(v) end
                    sv = " = " .. tostring(sv)
                end
                f:write(string.format("    prop %-38s %-16s%s\n", pn, ty, sv))
            end)
        end)
        pcall(function()
            c:ForEachFunction(function(fn)
                local params = {}
                pcall(function()
                    fn:ForEachProperty(function(prop)
                        local ty = safe(function() return prop:GetClass():GetFName():ToString() end) or "?"
                        params[#params + 1] = shortName(prop) .. ":" .. ty
                    end)
                end)
                f:write("    func ", shortName(fn), "(", table.concat(params, ", "), ")\n")
            end)
        end)
        local cur = c
        c = safe(function() return cur:GetSuperStruct() end)
        guard = guard + 1
    end
end

function nearestOf(a, list)
    local best, who = math.huge, nil
    for _, o in ipairs(list) do
        local d = dist2(a, o)
        if d < best then best, who = d, o end
    end
    return who, (best < math.huge) and math.sqrt(best) or -1
end

function dumpCanisters()
    refreshLists(true)
    local f = io.open(CANISTER_DUMP_PATH, "w")
    if not f then log("CANISTER: cannot write canister_dump.log") return end
    f:write("AlliedDefense v", VERSION, " canister dump ", os.date("%Y-%m-%d %H:%M:%S"), "\n\n")
    -- 1) find any known hold item, then its Blueprint parents
    local parents, seenParent = {}, {}
    for _, g in ipairs(CANISTER_GUESSES) do
        local objs = findAll(g)
        f:write(string.format("guess %-42s : %d\n", g, #objs))
        if objs[1] then
            local c, guard = safe(function() return objs[1]:GetClass() end), 0
            while valid(c) and guard < 12 do
                local cn = shortName(c)
                if cn == "Actor" or cn == "Object" then break end
                if cn:sub(-2) == "_C" and not seenParent[cn] then
                    seenParent[cn] = true
                    parents[#parents + 1] = cn
                end
                local cur = c
                c = safe(function() return cur:GetSuperStruct() end)
                guard = guard + 1
            end
        end
    end
    f:write("\nBlueprint classes in the chain: ", table.concat(parents, " > "), "\n\n")
    -- 2) every class under those parents (all hold items of the level)
    local byClass, order = {}, {}
    for _, pcn in ipairs(parents) do
        for _, o in ipairs(findAll(pcn)) do
            local cn = className(o)
            if not byClass[cn] then byClass[cn] = {} order[#order + 1] = cn end
            local list = byClass[cn]
            local known = false
            local a = addr(o)
            for _, e in ipairs(list) do if addr(e) == a then known = true break end end
            if not known then list[#list + 1] = o end
        end
    end
    table.sort(order)
    f:write("== Classes found (", #order, ")\n")
    for _, cn in ipairs(order) do
        f:write(string.format("  %-50s x%d%s\n", cn, #byClass[cn], looksCanister(cn) and "   <== candidate" or ""))
    end
    -- 3) canister classes in detail + every instance's surroundings
    local players, monsters = liveList(cache.players), monstersNow()
    local mlist = {}
    for _, e in ipairs(monsters) do mlist[#mlist + 1] = e.o end
    local candidates = 0
    for _, cn in ipairs(order) do
        if looksCanister(cn) then
            candidates = candidates + 1
            f:write("\n==== ", cn, "\n")
            for _, o in ipairs(byClass[cn]) do
                local x, y, z = location(o)
                local p, dp = nearestOf(o, players)
                local m, dm = nearestOf(o, mlist)
                local owner = safe(function() return o:GetOwner() end)
                local parent = safe(function() return o:GetAttachParentActor() end)
                f:write(string.format("  instance %s pos=(%.0f, %.0f, %.0f) owner=%s attachedTo=%s nearestPlayer=%.0f cm nearestMonster=%s %.0f cm\n",
                    shortName(o), x or 0, y or 0, z or 0, tag(owner), tag(parent), dp, tag(m), dm))
            end
            describeClassFull(f, byClass[cn][1], "Actor")
        end
    end
    f:close()
    log("CANISTER dump: %d hold item classes, %d canister candidate(s) -> canister_dump.log", #order, candidates)
end

end

function describeMode()
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

-- v1.3.2: straight back to the startup mode (phases by default) without cycling
bind(cfg.defaultModeKey, function()
    if cfg.mode == STARTUP_MODE then log("MODE already %s", describeMode()) return end
    cfg.mode = STARTUP_MODE
    phase.global, phase.turrets = nil, {}
    lastTrg = {}
    flushStats(true)
    log("MODE -> %s (default)", describeMode())
end, "default mode")

bind(cfg.inspectKey, inspect, "inspect")
-- developer diagnostic, only with debugLogs = true
if cfg.debugLogs then bind(cfg.canisterKey, dumpCanisters, "canister dump") end

bind(cfg.verboseKey, function()
    cfg.verbose = not cfg.verbose
    log("Verbose logs: %s", cfg.verbose and "ON" or "OFF")
end, "verbose")

prefix = cfg.modifier and (cfg.modifier .. "+") or ""
log("AlliedDefense v%s loaded (%s, mode %s). %s%s = on/off, %s%s = next mode, %s%s = default mode, %s%s = inspect, %s%s = verbose logs. Log: %s",
    VERSION, cfg.enabled and "enabled" or "disabled", describeMode(),
    prefix, cfg.toggleKey, prefix, cfg.modeKey, prefix, cfg.defaultModeKey, prefix, cfg.inspectKey, prefix, cfg.verboseKey, LOG_PATH)

-- v1.4.3, diagnostic (debugLogs = true only): the ghost's state over time. IsFrozen went
-- back to false 3 s after a freeze while the ghost still looked frozen: every ghost property
-- that looks like a freeze / damage / state flag is logged once, then each time it changes.
GHOST_WORDS = { "freez", "frozen", "ice", "frost", "cold", "stun", "slow", "immun", "invul", "vuln",
    "damage", "dmg", "state", "visib", "hidden", "materiali", "phase", "solid", "hit", "can" }
GHOST_TYPES = { BoolProperty = true, FloatProperty = true, DoubleProperty = true, IntProperty = true,
    ByteProperty = true, EnumProperty = true, NameProperty = true }
ghostWatchState = { props = nil, last = {} }
function ghostWatchProps(g)
    local list = {}
    local cls = g:GetClass()
    local depth = 0
    while valid(cls) and depth < 8 do
        local cn = shortName(cls)
        if cn == "Pawn" or cn == "Character" or cn == "Actor" then break end
        pcall(function()
            cls:ForEachProperty(function(p)
                local pt = shortName(p:GetClass())
                if GHOST_TYPES[pt] then
                    local n = p:GetFName():ToString()
                    local nl = n:lower()
                    for _, w in ipairs(GHOST_WORDS) do
                        if nl:find(w, 1, true) then list[#list + 1] = n break end
                    end
                end
            end)
        end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end)
        cls = ok and sup or nil
        depth = depth + 1
    end
    return list
end
function ghostWatch()
    if not cfg.debugLogs then return end
    local ghosts = findAll("BP_Monster_Ghost_C")
    for _, g in ipairs(ghosts) do
        if valid(g) then
            if not ghostWatchState.props then
                ghostWatchState.props = ghostWatchProps(g)
                log("GHOST: watching %d properties: %s", #ghostWatchState.props, table.concat(ghostWatchState.props, ", "))
            end
            local key = shortName(g)
            local last = ghostWatchState.last[key] or {}
            local changes = {}
            for _, n in ipairs(ghostWatchState.props) do
                local v = readProp(g, n)
                local s
                if type(v) == "number" then s = string.format("%.2f", v)
                elseif type(v) == "boolean" or type(v) == "string" then s = tostring(v)
                else local ok, t = pcall(function() return v:ToString() end); s = ok and tostring(t) or "?" end
                if last[n] ~= s then
                    changes[#changes + 1] = n .. (last[n] and (" " .. last[n] .. " -> ") or " = ") .. s
                    last[n] = s
                end
            end
            ghostWatchState.last[key] = last
            if #changes > 0 then log("GHOST %s: %s", key, table.concat(changes, "  ")) end
        end
    end
end

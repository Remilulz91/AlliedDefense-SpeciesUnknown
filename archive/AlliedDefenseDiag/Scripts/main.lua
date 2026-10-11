-- AlliedDefenseDiag v0.2 - diagnostic UE4SS (Lua) pour Species: Unknown
-- Auteur : Remilulz_91
--
-- v0.1 a identifie la tourelle : BP_SentryGun_C (Blueprint), avec IsFriend(),
-- une table d'agro (AddToAgroTable / RemoveFromAgroTable / SelectTrg) et current_trg.
-- v0.2 cible uniquement ces elements pour comprendre comment elle choisit sa cible.
--
-- Corrections v0.2 (crash v0.1) :
--   - plus de NotifyOnNewObject / ExecuteWithDelay (callbacks hors thread de jeu
--     pendant le chargement asynchrone = corruption de l'etat Lua) ;
--   - les ~480 BP_DummySentryGun_C (points d'apparition) sont ignores ;
--   - le monitor ne lit que quelques proprietes et ne logge que les changements.
--
-- LECTURE SEULE : aucune propriete ecrite, aucune fonction bloquee.

local VERSION = "0.2.0"
local MOD = "AlliedDefenseDiag"

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local okCfg, cfg = pcall(require, "config")
if not okCfg or type(cfg) ~= "table" then cfg = {} end
local function default(k, v) if cfg[k] == nil then cfg[k] = v end end
default("turretClass", "BP_SentryGun_C")
default("managerClass", "BP_SentryGunManager_C")
default("keys", { scan = "F5", marker = "F6", monitor = "F7", hooks = "F8", summary = "F9" })
default("monitorIntervalMs", 250)
default("monitorProps", { "current_trg", "previous_trg", "behaviour_state", "is_awake" })
default("hookFunctions", { { name = "IsFriend", args = { 1 }, post = { 2 } } })
default("hookDedupSeconds", 2.0)

---------------------------------------------------------------------------
-- Log
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

local LOG_PATH = modDir() .. "\\diag_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local logFile = io.open(LOG_PATH, "a")

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

local function fullName(o)  return safe(function() return o:GetFullName() end) or "?" end
local function shortName(o) return safe(function() return o:GetFName():ToString() end) or "?" end
local function fieldClassName(p) return safe(function() return p:GetClass():GetFName():ToString() end) or "?" end
local function isDefaultObject(o) return string.find(shortName(o), "Default__", 1, true) ~= nil end

local function classChain(o)
    local names = {}
    local c = safe(function() return o:GetClass() end)
    local guard = 0
    while valid(c) and guard < 40 do
        names[#names + 1] = shortName(c)
        local cur = c
        c = safe(function() return cur:GetSuperStruct() end)
        guard = guard + 1
    end
    return names
end

local function chainHas(o, name)
    for _, n in ipairs(classChain(o)) do if n == name then return true end end
    return false
end

local function readProp(o, name) return safe(function() return o[name] end) end

-- Joueur = Pawn avec un PlayerState
local function pawnTag(o)
    if not valid(o) or not chainHas(o, "Pawn") then return "" end
    if valid(readProp(o, "PlayerState")) then return " [JOUEUR]" end
    return " [PNJ/SPECIMEN]"
end

local function fmtVec(v)
    local x = safe(function() return v.X end)
    if type(x) ~= "number" then return nil end
    return string.format("(%.0f, %.0f, %.0f)", x, safe(function() return v.Y end) or 0, safe(function() return v.Z end) or 0)
end

-- Format court : nom d'instance + tag joueur/specimen
local function fmtValue(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "table" then return fmtVec(v) or tostring(v) end
    if t ~= "userdata" then return tostring(v) end
    local n = safe(function() return v:GetArrayNum() end)
    if type(n) == "number" then return "TArray[" .. n .. "]" end
    local isObj = safe(function() return v.IsValid ~= nil and v.GetFullName ~= nil end)
    if isObj then
        if not valid(v) then return "None" end
        return shortName(v) .. " <" .. shortName(safe(function() return v:GetClass() end)) .. ">" .. pawnTag(v)
    end
    local s = safe(function() return v:ToString() end)
    if type(s) == "string" then return '"' .. s .. '"' end
    return fmtVec(v) or tostring(v)
end

local function findAll(cname)
    local out = {}
    for _, a in ipairs(safe(function() return FindAllOf(cname) end) or {}) do
        if valid(a) and not isDefaultObject(a) then out[#out + 1] = a end
    end
    return out
end

local function dumpClassOnce(obj, label)
    local cls = safe(function() return obj:GetClass() end)
    if not valid(cls) then return end
    log("  [%s : %s]", label, fullName(cls))
    safe(function()
        cls:ForEachProperty(function(p)
            local pname = shortName(p)
            log("    prop  %-34s %-18s = %s", pname, fieldClassName(p), fmtValue(readProp(obj, pname)))
        end)
    end)
    local funcs = {}
    safe(function() cls:ForEachFunction(function(f) funcs[#funcs + 1] = f end) end)
    for _, f in ipairs(funcs) do
        local params = {}
        safe(function()
            f:ForEachProperty(function(p)
                local pn = shortName(p)
                if not pn:find("^CallFunc_") and not pn:find("^K2Node_") and not pn:find("^Temp_") then
                    params[#params + 1] = pn .. ":" .. fieldClassName(p)
                end
            end)
        end)
        log("    func  %s(%s)", shortName(f), table.concat(params, ", "))
    end
end

---------------------------------------------------------------------------
-- SCAN (Ctrl+F5)
---------------------------------------------------------------------------
local function scan()
    log("==================== SCAN v%s ====================", VERSION)

    local pcs = findAll("PlayerController")
    log("-- PlayerControllers : %d", #pcs)
    for _, pc in ipairs(pcs) do
        log("  %s  local=%s  pawn=%s", shortName(pc),
            fmtValue(safe(function() return pc:IsLocalController() end)),
            fmtValue(readProp(pc, "Pawn")))
        local pawn = readProp(pc, "Pawn")
        if valid(pawn) then log("     heritage pawn : %s", table.concat(classChain(pawn), " > ")) end
    end

    -- Recensement des pawns (joueurs vs specimens)
    local byClass, order = {}, {}
    for _, p in ipairs(findAll("Pawn")) do
        local cn = shortName(safe(function() return p:GetClass() end))
        local e = byClass[cn]
        if not e then
            e = { n = 0, players = 0, chain = table.concat(classChain(p), " > ") }
            byClass[cn] = e
            order[#order + 1] = cn
        end
        e.n = e.n + 1
        if pawnTag(p) == " [JOUEUR]" then e.players = e.players + 1 end
    end
    log("-- Pawns par classe : %d (si 0, FindAllOf ne gere pas l'heritage : voir heritage pawn ci-dessus)", #order)
    for _, cn in ipairs(order) do
        local e = byClass[cn]
        log("  %-36s x%-3d joueurs=%d  | %s", cn, e.n, e.players, e.chain)
    end

    local turrets = findAll(cfg.turretClass)
    log("-- %s en jeu : %d", cfg.turretClass, #turrets)
    local awake = 0
    for _, t in ipairs(turrets) do
        if readProp(t, "is_awake") == true then awake = awake + 1 end
    end
    log("   dont reveillees (is_awake) : %d", awake)
    if turrets[1] then
        log("   exemple : %s  pos=%s  authority=%s", shortName(turrets[1]),
            fmtValue(safe(function() return turrets[1]:K2_GetActorLocation() end)),
            fmtValue(safe(function() return turrets[1]:HasAuthority() end)))
    end

    local managers = findAll(cfg.managerClass)
    log("-- %s : %d", cfg.managerClass, #managers)
    if managers[1] then dumpClassOnce(managers[1], "manager") end
    log("==================== FIN SCAN ====================")
end

---------------------------------------------------------------------------
-- MONITOR (Ctrl+F7)
---------------------------------------------------------------------------
local monitor = { on = false, gen = 0, last = {}, busy = false }

local function monitorTick()
    for _, t in ipairs(findAll(cfg.turretClass)) do
        local tname = shortName(t)
        for _, pn in ipairs(cfg.monitorProps) do
            local v = fmtValue(readProp(t, pn))
            local k = tname .. "|" .. pn
            local old = monitor.last[k]
            if old == nil then
                monitor.last[k] = v
                if pn == "current_trg" and v ~= "None" then log("INIT   %s.%s = %s", tname, pn, v) end
            elseif old ~= v then
                monitor.last[k] = v
                log("CHANGE %s.%s : %s  ->  %s", tname, pn, old, v)
            end
        end
    end
end

local function toggleMonitor()
    monitor.on = not monitor.on
    monitor.gen = monitor.gen + 1
    if not monitor.on then log("MONITOR : OFF") return end
    monitor.last = {}
    log("MONITOR : ON (%d ms, %s)", cfg.monitorIntervalMs, table.concat(cfg.monitorProps, ", "))
    local myGen = monitor.gen
    LoopAsync(cfg.monitorIntervalMs, function()
        if not monitor.on or monitor.gen ~= myGen then return true end
        if not monitor.busy then
            monitor.busy = true
            ExecuteInGameThread(function()
                local ok, err = pcall(monitorTick)
                if not ok then log("MONITOR erreur : %s", tostring(err)) end
                monitor.busy = false
            end)
        end
        return false
    end)
end

---------------------------------------------------------------------------
-- HOOKS (Ctrl+F8)
---------------------------------------------------------------------------
local hooks = { on = false, registered = false, list = {}, counts = {}, lastLine = {} }

local function paramValues(params, idxs)
    local out = {}
    for _, i in ipairs(idxs or {}) do
        local p = params[i]
        out[#out + 1] = (p ~= nil) and fmtValue(safe(function() return p:get() end)) or "?"
    end
    return table.concat(out, ", ")
end

local function report(spec, phase, ctx, params, idxs)
    local selfName = shortName(safe(function() return ctx:get() end))
    local line = string.format("%s %s(%s)", phase, spec.name, paramValues(params, idxs))
    local key = selfName .. "|" .. phase .. "|" .. spec.name
    local now = os.clock()
    local prev = hooks.lastLine[key]
    if prev and prev.line == line and (now - prev.t) < cfg.hookDedupSeconds then return end
    hooks.lastLine[key] = { line = line, t = now }
    log("%-5s %-26s %s", phase, selfName, line:sub(#phase + 2))
end

local function registerHooks()
    local turret = findAll(cfg.turretClass)[1]
    if not turret then
        log("HOOKS : aucune %s chargee - lance un contrat 'Sentry Turrets' puis reessaie", cfg.turretClass)
        return false
    end
    local clsPath = (fullName(turret:GetClass()):gsub("^%S+%s+", ""))  -- /Game/.../BP_SentryGun.BP_SentryGun_C
    for _, spec in ipairs(cfg.hookFunctions) do
        local path = clsPath .. ":" .. spec.name
        local pre = function(ctx, ...)
            hooks.counts[spec.name] = (hooks.counts[spec.name] or 0) + 1
            if not hooks.on or spec.quiet then return end
            local ok, err = pcall(report, spec, "CALL", ctx, { ... }, spec.args)
            if not ok then log("HOOK erreur %s : %s", spec.name, tostring(err)) end
        end
        local post = nil
        if spec.post and #spec.post > 0 then
            post = function(ctx, ...)
                if not hooks.on then return end
                local ok, err = pcall(report, spec, "RET", ctx, { ... }, spec.post)
                if not ok then log("HOOK erreur %s : %s", spec.name, tostring(err)) end
            end
        end
        local ok, a, b
        if post then
            ok, a, b = pcall(RegisterHook, path, pre, post)
        else
            ok, a, b = pcall(RegisterHook, path, pre)
        end
        if ok then
            hooks.list[#hooks.list + 1] = { path = path, pre = a, post = b }
            log("HOOK +  %s%s", spec.name, post and "  (+ retour)" or "")
        else
            log("HOOK x  %s : %s", spec.name, tostring(a))
        end
    end
    return #hooks.list > 0
end

local function toggleHooks()
    if not hooks.registered then
        hooks.registered = registerHooks()
        if not hooks.registered then return end
    end
    -- Les hooks restent enregistres ; on ne fait que couper l'affichage (plus sur que les retirer)
    hooks.on = not hooks.on
    hooks.lastLine = {}
    log("HOOKS : %s", hooks.on and "ON" or "OFF")
end

local function summary()
    local rows = {}
    for name, n in pairs(hooks.counts) do rows[#rows + 1] = { name = name, n = n } end
    table.sort(rows, function(x, y) return x.n > y.n end)
    log("-------- RESUME DES APPELS --------")
    for _, r in ipairs(rows) do log("  %10d  %s", r.n, r.name) end
    log("-----------------------------------")
end

local markerN = 0
local function marker()
    markerN = markerN + 1
    log("######## MARQUEUR %d ########", markerN)
end

---------------------------------------------------------------------------
-- Touches
---------------------------------------------------------------------------
local function bind(keyName, fn, label)
    local k = Key and Key[keyName]
    if not k then log("Touche inconnue '%s' pour %s", tostring(keyName), label) return end
    local cb = function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("ERREUR %s : %s", label, tostring(err)) end
        end)
    end
    local mod = cfg.modifier and ModifierKey and ModifierKey[cfg.modifier]
    local ok, err
    if mod then ok, err = pcall(RegisterKeyBind, k, { mod }, cb)
    else ok, err = pcall(RegisterKeyBind, k, cb) end
    if not ok then log("Impossible d'enregistrer %s : %s", label, tostring(err)) end
end

local prefix = cfg.modifier and (cfg.modifier .. "+") or ""
log("AlliedDefenseDiag v%s charge. Log : %s", VERSION, LOG_PATH)
log("Touches : %s%s scan | %s%s marqueur | %s%s monitor | %s%s hooks | %s%s resume",
    prefix, cfg.keys.scan, prefix, cfg.keys.marker, prefix, cfg.keys.monitor,
    prefix, cfg.keys.hooks, prefix, cfg.keys.summary)

bind(cfg.keys.scan, scan, "scan")
bind(cfg.keys.marker, marker, "marqueur")
bind(cfg.keys.monitor, toggleMonitor, "monitor")
bind(cfg.keys.hooks, toggleHooks, "hooks")
bind(cfg.keys.summary, summary, "resume")

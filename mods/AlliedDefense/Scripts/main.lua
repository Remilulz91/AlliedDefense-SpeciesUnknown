-- AlliedDefense v1.4.3 - Species: Unknown (UE4SS Lua)
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
--     Handle_Shoot (v1.1.0)    : a shot at a visible monster also hits an explosive canister
--                                lying next to it (no player in the blast) -> it explodes
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

-- Since 1.4.2 the code is split into several files, loaded in this order into one shared
-- environment (a table that falls back to the global one): a name set at the top of a file
-- is visible to the files loaded after it, and nothing leaks into other mods.
local VERSION = "1.4.3"
local MOD = "AlliedDefense"

local FILES = { "core", "turrets", "protect", "board", "upgrades", "keys" }
local Env = setmetatable({ VERSION = VERSION, MOD = MOD }, { __index = _G })
ALLIED_DEFENSE_ENV = Env   -- (each UE4SS mod has its own Lua state: only for tests / debugging)

local function scriptsDir()
    local src = (debug.getinfo(1, "S") or {}).source or ""
    local dirs = { src:gsub("^@", ""):match("^(.*[/\\])") or "", "", "ue4ss/Mods/AlliedDefense/Scripts/" }
    for _, d in ipairs(dirs) do
        local f = io.open(d .. "core.lua", "r")
        if f then f:close() return d end
    end
    return dirs[1]
end

local dir = scriptsDir()
for _, name in ipairs(FILES) do
    local chunk, err = loadfile(dir .. name .. ".lua", "t", Env)
    if not chunk then
        print("[" .. MOD .. "] " .. name .. ".lua failed to load: " .. tostring(err) .. "\n")
        return
    end
    local ok, errRun = pcall(chunk)
    if not ok then
        print("[" .. MOD .. "] " .. name .. ".lua failed: " .. tostring(errRun) .. "\n")
        if Env.log then pcall(Env.log, "%s.lua failed: %s", name, tostring(errRun)) end
        return
    end
end

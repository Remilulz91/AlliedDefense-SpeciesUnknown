-- AlliedDefense - configuration
-- Reload: Ctrl+R (if UE4SS hot reload is enabled) or restart the game.

return {
    enabled = true,           -- state at startup (toggle in game: Ctrl+F10)

    -- Turret mode (cycle in game with Ctrl+F9):
    --   "ally"    turrets ignore players and shoot monsters
    --   "vanilla" untouched game behaviour
    --   "neutral" turrets shoot nobody
    --   "chaos"   turrets shoot everybody (players AND monsters)
    --   "phases"  turrets alternate between ally and hostile (vanilla) phases
    -- Default: "phases" (normal play). For troubleshooting, switch to "ally" (Ctrl+F9 once).
    mode = "phases",
    modeCycle = { "phases", "ally", "chaos", "neutral", "vanilla" },  -- Ctrl+F9 order

    -- "phases" mode
    phasePerTurret = false,   -- false: the whole level switches together; true: each turret has its own phase
    phaseMinSeconds = 120,    -- shortest phase (seconds)
    phaseMaxSeconds = 300,    -- longest phase (seconds)
    phaseStart = "random",    -- "random", "ally" or "hostile"
    revealPhase = false,      -- false: same colour in both phases (you never know);
                              -- true: game colour (red) when hostile + a beep on phase change

    -- Game classes (found with AlliedDefenseDiag)
    turretClassPath  = "/Game/Blueprints/Monsters/SentryGun/BP_SentryGun.BP_SentryGun_C",
    turretClass      = "BP_SentryGun_C",
    monsterBaseClass = "BP_ParentMonster_C",    -- parent of BP_BigRobot_C, BP_SphereBot_C...
    playerBaseClass  = "BP_ParentCharacter_C",  -- parent of BP_Character_C

    -- Monster targeting
    range = 3000,             -- range (cm) when the turret has no "Max Distance" property
    monsterInitAgro = 30.0,   -- initial aggro of a monster entering the table (= game's detect_agro_value)
    monsterAgroPerCall = 1.0, -- aggro added on every target selection (offsets agro_cool_rate)
    wakeOnMonster = true,     -- wake a sleeping turret up when a monster comes in range
    wakeRetrySeconds = 5,     -- delay between two wake-up attempts on the same turret
    ignorePlayers = true,     -- turrets treat players as "friends"
    targetMonsters = true,    -- monsters are no longer "friends" (=> targets)
    retargetToMonster = false, -- true: a player target is swapped for the nearest monster instead of
                               -- dropped (v0.7 default; suspected of freezing a turret on BigRobot)
    purgePotentialTargets = true, -- remove players from the turret's potential_trgs map (stops the beep)
    purgePlayersInBackground = false, -- true = also every second (v0.8.5). Keep false: turrets only deploy
                                      -- after a player entered potential_trgs; true kept them in the ceiling
    forceDeploy = false,      -- v0.2 forced opening (Deploy) - crash suspect, disabled

    -- v0.8.3: turrets only pick targets from their potential_trgs map, which BigRobot and
    -- drones never enter on their own. The mod adds the monsters in sensor range to it.
    injectPotentialTargets = true,
    injectMethod = "auto",    -- "event" (turret's own sensor event), "construct" (build the
                              -- OBJ_SentryTrgData_C ourselves) or "auto" (event, then construct)
    injectRadiusScale = 1.0,  -- x pawn_detection_radius (2000 cm) to add a monster
    injectRemoveScale = 1.25, -- x the above to remove it again (hysteresis)
    -- v0.9.0: bullets of an ALLIED turret no longer hurt players standing in the line of fire.
    -- Hostile turrets ("phases" hostile phase, "chaos") still hurt.
    -- EXPERIMENTAL - keep false: crashed the game several times (v0.9.4 - v0.9.6).
    protectPlayersFromAllyFire = false,
    restoreHealthFromAllyFire = true, -- give back the health lost to an ALLIED turret bullet (0.1 s later)
    dumpDamageFunctions = false,  -- true: write damage_dump.log once (diagnostic, v0.8.9)
    -- v1.1.0: explosive canisters (fire / frost). When an allied turret shoots a monster it can
    -- see, its shots also hit an explosive canister lying next to that monster (it explodes
    -- after a few shots), unless a player stands in the blast.
    shootCanisters = true,
    canisterClass = "BP_HoldItem_ExplosiveCanister_Fire_C",  -- also covers the frost canister (child class)
    canisterTriggerRadius = 400,   -- a monster must be this close to the canister (cm)
    canisterSafeRadius = 800,      -- no player within this distance of the canister (cm)
    canisterShotDamage = 2.0,      -- damage per turret shot (canister health = 6, so 3 shots)
    hostileShootCanisters = true,  -- v1.2.0: a HOSTILE turret (phases hostile phase, chaos) also blows up the canister
                                   -- nearest to its target - player or monster, no safety distance
    trgDataClassPath = "/Game/Blueprints/Monsters/SentryGun/OBJ_SentryTrgData.OBJ_SentryTrgData_C",

    -- Monsters turrets must NEVER aim at (class names)
    -- Crash test: set { "BP_SphereBot_C" } to make turrets ignore drones
    ignoredMonsters = {},
    -- Monsters targeted only while a boolean property is true
    -- (ghost: immune to bullets unless frozen). Dead monsters (IsDead) are never targeted.
    targetOnlyWhen = { BP_Monster_Ghost_C = "IsFrozen" },
    -- Monsters NOT targeted while a boolean property is true (Eye: shield blocks bullets)
    targetUnlessTrue = { BP_Monster_Eye_C = "HaveShield" },
    -- Vanilla "friend" monsters, used as a substitute to make a player a "friend"
    friendSubstituteClasses = { "BP_BigRobot_C" },   -- not drones: they are constantly destroyed

    -- Players no longer wake turrets up
    blockPlayerWake = true,
    playerWakeThreshold = 1000000.0,
    -- false (default): a player's aggro is redirected to the nearest monster,
    -- otherwise made very negative. true = old "None" method (broke BigRobot targeting).
    playerAgroToNone = false,
    -- The turret's presence sensor ignores players
    hidePlayersFromSensor = true,

    -- Turret "alert/fire" colour while the mod is enabled (red in vanilla).
    -- nil = game colour. R,G,B values between 0 and 1. Examples:
    --   green { R = 0.0, G = 1.0, B = 0.2, A = 1.0 }
    --   blue  { R = 0.1, G = 0.4, B = 1.0, A = 1.0 }
    allyFireColor = { R = 0.1, G = 0.4, B = 1.0, A = 1.0 },
    -- Colour in "chaos" mode (nil = game red). Example purple: { R = 0.6, G = 0.0, B = 1.0, A = 1.0 }
    chaosFireColor = nil,

    -- Describe each monster class once in monsters_dump.log
    dumpMonsterClasses = false,

    -- Player/monster list refresh (seconds)
    listRefreshSeconds = 0.5,
    -- Background loop (turret wake-up, hook registration)
    backgroundIntervalMs = 1000,

    -- Keys
    modifier = "CONTROL",
    toggleKey = "F10",        -- enable / disable the mod
    modeKey = "F9",           -- next mode (see modeCycle)
    inspectKey = "F6",        -- dump the state of the turrets closest to a living monster into the log
    inspectCount = 4,         -- number of turrets dumped by the inspector
    verboseKey = "F11",       -- enable / disable verbose logs
    canisterKey = "F7",       -- diagnostic (only with debugLogs = true): explosive canisters -> canister_dump.log

    verbose = false,          -- true: log target changes + stats every 10 s (toggle in game: Ctrl+F11)
    debugLogs = false,        -- true: developer diagnostics (hook install, WAKE, TRGDATA, PERF/SLOW timings)
}

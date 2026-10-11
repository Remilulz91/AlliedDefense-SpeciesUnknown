# Allied Defense — Species: Unknown

Port of the **AlliedDefenses** idea (Lethal Company) and **Allied Defense — L4D2**
to *Species: Unknown*: the ceiling turrets of the **Sentry Turrets** modifier
never shoot players anymore and fight the specimens instead.

> Separate project from `../AlliedDefenses` (C#/BepInEx) and `../AlliedDefense-L4D2` (VScript).
> Here: **UE4SS Lua**, no Unreal Engine tooling required.
> Author: **Remilulz_91** — © 2026 Remilulz_91, all rights reserved.

## Requirements

- Species: Unknown (UE 5.7)
- **RE-UE4SS experimental build** (the stable 3.0.1 release does not support UE 5.7),
  plus the UE5.7 signature file from Nexus ("UE4SS Signatures for Species Unknown").
- Mods are loaded through their `enabled.txt` file — no need to edit `mods.txt`.
- Installing any mod locks public lobbies (game rule since 0.25): solo / private games only.
- Multiplayer: turret logic runs on the **host**, so the host needs the mod.

## Install

```bat
tools\install.bat        :: copies the mods into ue4ss\Mods
tools\install-dev.bat    :: links them instead (edits are live, logs land in the project)
tools\uninstall.bat
```

If the game folder is not found automatically:

```bat
set SU_MODS_DIR=D:\SteamLibrary\steamapps\common\Species Unknown\SpeciesUnknown\Binaries\Win64\ue4ss\Mods
tools\install.bat
```

Check: the first line of `mods\AlliedDefense\AlliedDefense.log` must show the expected version.

## Keys

| Key | Action |
|---|---|
| **Ctrl+F6** | Inspector: dumps the state of the turrets closest to a monster into the log |
| **Ctrl+F9** | Next mode: phases → ally → chaos → neutral → vanilla |
| **Ctrl+F10** | Enable / disable the mod (compare with vanilla) |
| **Ctrl+F11** | Verbose logs on / off (target changes + stats every 10 s; off by default) |

Settings live in `mods\AlliedDefense\Scripts\config.lua` (ally colour, ignored monsters,
ghost condition, ranges...). For troubleshooting: `verbose = true` (target changes + stats)
and `debugLogs = true` (hook install, `WAKE`, `TRGDATA`, `PERF` / `SLOW` timings).

## Modes

| Mode | Behaviour |
|---|---|
| `ally` | turrets ignore players and shoot monsters (use it for troubleshooting) |
| `vanilla` | untouched game behaviour |
| `neutral` | turrets shoot nobody |
| `chaos` | turrets shoot everybody, players and monsters |
| `phases` (default) | turrets alternate between **ally** and **hostile** phases of random length (2–5 min by default) |

`phases` options (`config.lua`): `phasePerTurret` (whole level or each turret on its own),
`phaseMinSeconds` / `phaseMaxSeconds`, `phaseStart`, and `revealPhase`:
hidden by default (same colour in both phases — you never know which side they are on),
or revealed (red when hostile + a beep on change).

Idea for `phases`: a friend's suggestion — "neither fully allied nor fully hostile".
A real new mission modifier in the contract menu would need Unreal Editor asset changes,
so the mode is selected through the config / Ctrl+F9 instead.

## How it works

The turret (`BP_SentryGun_C`, a Blueprint) classifies every pawn with `IsFriend(Actor)`.
In vanilla, most monsters are "friends" and players are not. The mod only alters the
**inputs** of a few turret functions ("pre" hooks); aiming, shooting and damage stay vanilla:

| Function | What the mod does |
|---|---|
| `IsFriend` | living monsters → enemies; players, dead monsters, unfrozen ghost → friends |
| `BPI_SentryGun_SetPlayerWakeUpThreshold_1` | players can never wake a turret up |
| `AddToAgroTable` | a player's aggro goes to the nearest monster (or becomes very negative) |
| `TryToWakeUp` | player → nearest monster, otherwise None |
| `SelectTrg` | removes players from the aggro table and `potential_trgs`, adds nearby monsters |
| `Handle_Shoot (SRV side)` / `CurrentTrg_Handle` | a player target is swapped for the nearest monster (or dropped) |
| `PawnDetectionSphere` overlap events | players never enter the turret sensor |
| `potential_trgs` map (background loop) | monsters in sensor range are added to it (see below) |

`SelectTrg` only picks targets from the turret's `potential_trgs` map (Actor → `OBJ_SentryTrgData_C`),
normally filled by the sensor overlap. BigRobot and drones never enter it on their own
(aggro alone is useless), so the mod adds living monsters in sensor range to it: first by
calling the turret's own sensor event, otherwise by building the `OBJ_SentryTrgData_C` itself
(`injectMethod` in `config.lua`). Entries are removed when the monster dies, gets shielded
or leaves.

A background loop applies the ally colour, the player wake threshold, and asks sleeping
turrets to wake up when a monster is in range.

### Monster notes

| Monster | Class | Notes |
|---|---|---|
| Big robot + drones | `BP_BigRobot_C`, `BP_SphereBot_C` | drones are destroyed/respawned constantly |
| Poulpi | `BP_Monster_Poulpi_C` | the only monster vanilla turrets already shoot |
| Michel (dog) | `BP_Monster_Michel_C` | |
| Eye | `BP_Monster_Eye_C` | `IsSpider`, `HaveShield`; not targeted while shielded (bullets are blocked) |
| Ghost | `BP_Monster_Ghost_C` | immune to bullets, targeted only while `IsFrozen` |
| Zombies | `BP_Monster_ZombieMaster_C` | |

All monsters inherit `BP_ParentMonster_C` (with `IsDead`); players inherit `BP_ParentCharacter_C`.

## Project layout

```
AlliedDefense-SpeciesUnknown/
├── mods/
│   ├── AlliedDefense/              <- the mod
│   │   ├── enabled.txt
│   │   └── Scripts/ main.lua, config.lua
├── archive/AlliedDefenseDiag/      <- diagnostic tool used to reverse the turret (not installed;
│                                      its Ctrl+F5..F9 hooks crashed the game alongside the mod)
└── tools/                          <- install / install-dev / uninstall / find-mods (.bat)
```

## Changelog

- **1.0.0** — first stable release. Tested on full games with BigRobot + drones, Poulpi and
  Michel without crash or freeze. Verbose logs off by default; developer diagnostics
  (hook install, `WAKE`, `TRGDATA`, `PERF` / `SLOW`) moved behind `debugLogs = true`.
  Ally-fire protection stays experimental and off. Default mode is now `phases`
  (Ctrl+F9 once switches to full `ally` for troubleshooting).
- **0.9.7** — stability: ally-fire protection (damage hook + health restore) OFF by default
  while the crashes seen since 0.9.4 are investigated (`protectPlayersFromAllyFire = true` to
  re-enable, experimental); the per-tick monster snapshot can no longer outlive its tick.
- **0.9.6** — crash fix (crash in the hangar with 0.9.5): the 100 ms async loop added in 0.9.4
  was removed (health is restored from the turret shoot hooks + the 1 s loop), and the damage
  hooks were cut from 14 to 1 (`ReceiveAnyDamage` on `BP_ParentCharacter_C`).
- **0.9.5** — crash fix (zombie game): the old v0.7 diagnostic that walked every key of a
  turret's `potential_trgs` (and read each actor's class) was removed; a zombie being destroyed
  in that map caused an access violation in UE4SS.
- **0.9.4** — ally-fire protection, 3rd attempt: zeroing damage parameters has no effect
  (health still dropped), so the health lost to an allied turret bullet is restored right after
  the hit (`restoreHealthFromAllyFire`). Perf: monster list + positions computed once per tick
  instead of once per turret (30-40 ms/s with many monsters, e.g. `BP_Moray_C`).
- **0.9.3** — fix: micro freeze every 2 s since 0.9.0. The damage-hook installer looked up
  missing function names with `StaticFindObject` every 2 s (50-90 ms each time); functions are
  now listed once per class. Turret class lookup throttled (5 s while absent, 10 s once hooked);
  `damage_dump.log` off by default.
- **0.9.2** — diagnostic: `PERF` (every 30 s) and `SLOW background tick` log lines measure how
  long each part of the mod takes (investigating a short freeze every few seconds).
- **0.9.1** — ally-fire protection, 2nd attempt: zeroing the damage in the engine events
  (`ReceivePointDamage` / `ReceiveAnyDamage`) was not enough; the hit is now marked there and
  the player's own Blueprint damage chain (`GetDamageEvent`, `CheckDamage`...) gets Damage = 0.
- **0.9.0** — bullets of an allied turret no longer hurt players in the line of fire
  (`protectPlayersFromAllyFire`); hostile turrets (phases hostile phase, chaos) still hurt.
  Pre hooks on the player's damage functions set the damage to 0 when the causer is an ally turret.
- **0.8.9** — diagnostic: `damage_dump.log` lists the damage-related functions of the turret and
  player classes (preparing an option so turret bullets no longer hurt players).
- **0.8.8** — fix: per-second player purge (0.8.5) turned OFF by default. A turret only deploys
  after a player entered its `potential_trgs` (the mod then swaps the player for a monster);
  purging every second kept every turret in the ceiling (0.8.5-0.8.7). Back to 0.8.4 behaviour.
- **0.8.7** — fix (regression from 0.8.5): BigRobot/drones were no longer added to `potential_trgs`
  because the per-second player purge emptied the map before the injector could learn the
  `OBJ_SentryTrgData_C` class; the class is now learned before purging and found by path.
- **0.8.6** — diagnostic: `WAKE ok` / `WAKE no effect` lines (with lock state) tell whether
  `TryToWakeUp(monster)` really opens a turret; `wake_ok` / `wake_no_effect` stats.
- **0.8.5** — players removed from every ally turret's `potential_trgs` every second (background loop),
  not only when it selects/shoots: removes the brief "turret -> player" moments.
- **0.8.4** — hooks retried every 2 s when the turret class is not ready yet
  (`UFunction::Func: 0x0` right after loading: in 0.8.3 every hook failed for a whole game).
- **0.8.3** — monsters injected into the turret's `potential_trgs` map (Ctrl+F6 showed BigRobot
  and drones in `agro_table` but never in `potential_trgs`, so never selected); `TRGDATA` log
  lines describe `OBJ_SentryTrgData_C`.
- **0.8.2** — inspector moved to Ctrl+F6 (Ctrl+F8 also enabled the diagnostic mod's hooks:
  crash); inspector ignores dead monsters; diagnostic mod moved to `archive/`.
- **0.8.1** — inspector (Ctrl+F8): turret state, `potential_trgs` and `agro_table` contents.
- **0.8.0** — turret modes: ally, vanilla, neutral, chaos, phases (hidden or revealed,
  global or per turret); Ctrl+F9 cycles modes.
- **0.7.1** — players purged from the turret's `potential_trgs` map (they were still in it:
  cause of the "beep"); Eye not targeted while shielded; retarget-to-monster off by default
  (suspected of freezing a turret on BigRobot).
- **0.7.0** — English code, comments and logs. A player target is now swapped for the
  nearest monster instead of being dropped; diagnostic probe of `potential_trgs`.
- **0.6.1** — player aggro redirected to the nearest monster (0.5's "None" entry won
  target selection and stopped turrets from shooting BigRobot/drones).
- **0.6.0** — players hidden from the presence sensor; blue ally colour.
- **0.5.2** — crash fix: UObjects are never reused across frames (freed drones crashed
  `K2_GetActorLocation`), entries are re-validated with `StaticFindObject`.
- **0.5.0** — dead monsters ignored; ghost targeted only when frozen; player wake-up blocked.
- **0.4.0** — player wake threshold forced; monster class dump.
- **0.3.0** — `IsFriend` swap: monsters become enemies, players friends.
- **0.1–0.2** — first aggro-table approach; forced `Deploy()` removed (crash suspect).

## Known limitations

- **Turrets only deploy when a player comes close** (game logic): a monster alone does not
  open them. Once open, the mod swaps the player target for a monster.
- **Bullets of an allied turret still hurt players standing in the line of fire.** The
  protection (`protectPlayersFromAllyFire`) is experimental and **off**: every working version
  (0.9.4–0.9.6) crashed the game. Do not enable it in a real game.
- The Eye is not targeted while shielded, the ghost only while frozen (bullets are blocked).
- **Multiplayer untested**: turret logic runs on the host, so in theory only the host needs
  the mod; friends playing vanilla should see the same allied turrets.
- Zombie games: one crash in 0.9.4 (code removed since); not re-tested with 1.0.0.
- Every game update may rename classes/functions: if turrets act vanilla again, enable
  `debugLogs = true` and look for `Still N hook(s) not installed` / `Hook not ready yet` lines.

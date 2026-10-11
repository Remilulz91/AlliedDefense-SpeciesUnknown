-- AlliedDefenseDiag - configuration (v0.2, cible BP_SentryGun_C)

return {
    -- Classe de la vraie tourelle (trouvee par le diagnostic v0.1).
    -- BP_DummySentryGun_C = simples points d'apparition, ignores.
    turretClass  = "BP_SentryGun_C",
    managerClass = "BP_SentryGunManager_C",

    -- Touches (enum Key d'UE4SS) + modificateur ("CONTROL", "SHIFT", "ALT" ou nil)
    modifier = "CONTROL",
    keys = {
        scan    = "F5",  -- joueurs, pawns, 1 dump de tourelle
        marker  = "F6",  -- marqueur dans le log
        monitor = "F7",  -- suivi des cibles des tourelles (ON/OFF)
        hooks   = "F8",  -- espionnage des fonctions de ciblage (ON/OFF)
        summary = "F9",  -- resume des appels
    },

    -- Monitor : proprietes lues sur chaque tourelle, seuls les CHANGEMENTS sont logges
    monitorIntervalMs = 250,
    monitorProps = {
        "current_trg", "previous_trg", "behaviour_state", "is_awake",
        "can_see", "rep_is_trg_visible", "wait_for_shoot", "keep_shooting",
    },

    -- Hooks : fonctions espionnees sur BP_SentryGun_C.
    -- args = index des parametres a afficher (seulement objets/nombres, jamais de struct)
    -- post = index lus APRES l'appel (valeurs de sortie)
    -- quiet = compte seulement, n'affiche rien (fonctions appelees en boucle)
    hookFunctions = {
        { name = "IsFriend",            args = { 1 }, post = { 2 } },
        { name = "AddToAgroTable",      args = { 1, 2, 3 } },
        { name = "RemoveFromAgroTable", args = { 1 } },
        { name = "SelectTrg",           args = {} },
        { name = "TryToWakeUp",         args = { 1 } },
        { name = "SetBehaviourState",   args = { 1 } },
        { name = "CurrentTrg_Handle",   args = {} },
        { name = "Handle_Shoot (SRV side)", args = {} },
        { name = "ManageTrgs",          quiet = true },
        { name = "CheckActorVisibility", quiet = true },
        { name = "Die",                 args = {} },
    },
    -- Un appel identique (meme tourelle, memes args) n'est re-affiche qu'apres ce delai
    hookDedupSeconds = 2.0,
}

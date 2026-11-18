-- AlliedDefense / board.lua - Settings on the lobby's Personal Board (SHOP page).
-- Loaded by main.lua into the mod's shared environment: a top-level name set in any file
-- is visible to the files loaded after it (no "local" at file level: Lua caps a chunk at
-- 200 locals, which the single main.lua had reached).

---------------------------------------------------------------------------
-- v1.4.0: settings on the lobby's Personal Board (SHOP page).
-- One extra entry at the END of the SHOP list ("Allied Defense: <mode>"): first click selects
-- it and shows the mode's description; each further click goes to the next mode, saved in
-- settings.txt. Keys stay as a fallback (in missions the Board cannot be opened, and if a game
-- update breaks this page the mod keeps working with the saved mode).
-- Game widgets used (names read from the game; OmuAmmoPack adds its entry under the tools,
-- ours goes after the weapons so both can live on the same page):
--   WBP_EquipmentShop_C        : Items_ScrollBox, entryBtns, mainWidget, WBP_ItemInfo,
--                                equipedEntryIdx, SetupButtonStyle, ShowEntry
--   WBP_SelectEntryBtnBuy_C    : one list entry (TxtTitle, bought, SetupPrice, click event)
-- Never kept across frames: every step finds the pages and our entry again.
---------------------------------------------------------------------------
BOARD = {
    index = 98,   -- an index the game's lists never use (OmuAmmoPack uses 99)
    pageClass = "WBP_EquipmentShop_C",
    pagePath = "/Game/Blueprints/Screens/Terminals/Equipment/WBP_EquipmentShop.WBP_EquipmentShop_C",
    entryClass = "WBP_SelectEntryBtnBuy_C",
    entryPath = "/Game/Blueprints/Screens/Terminals/Common/WBP_SelectEntryBtnBuy.WBP_SelectEntryBtnBuy_C",
    clickEvent = "BndEvt__WBP_SelectEntryBtnBuy_WanaCross_Button_128_K2Node_ComponentBoundEvent_3_OnButtonSelfClickedSignature__DelegateSignature",
}
-- S_ToolInfo members read by the info panel (generated names of the game's struct)
BOARD_INFO = {
    name = "name_22_DF53FCB945C10E89DD252081735211E6",
    description = "description_8_48BD289C4ADECF7DE7ED6B9D964B2E6F",
    price = "price_19_9C1078A245DAAA1D2BA7CAA789069692",
    grade = "GradeUnlock_47_9B0032F74E5F8E4EDAF39D93DCB43CFE",
}
-- v1.4.1: Board texts in English or French (game language, or boardLanguage in config.lua).
-- Every text below is a pair { English, French }.
MODE_NAME = { phases = { "Phases", "Phases" }, ally = { "Ally", "Alliées" }, chaos = { "Chaos", "Chaos" },
    neutral = { "Neutral", "Neutres" }, vanilla = { "Vanilla", "Jeu de base" } }
MODE_TEXT = {
    phases = { "The ship's defence system was damaged when the specimens escaped. Its ceiling turrets "
        .. "still protect the crew... most of the time: they silently switch between allied and hostile.",
        "Le système de défense du vaisseau a été endommagé lors de l'évasion des spécimens. Ses tourelles "
        .. "protègent encore l'équipage... la plupart du temps : elles passent en silence d'alliées à hostiles." },
    ally = { "Repaired defence system: the turrets ignore the crew and shoot the specimens, all the time.",
        "Système de défense réparé : les tourelles ignorent l'équipage et tirent sur les spécimens, en permanence." },
    chaos = { "Total malfunction: the turrets shoot everybody, crew and specimens.",
        "Panne totale : les tourelles tirent sur tout le monde, équipage et spécimens." },
    neutral = { "Defence system offline: the turrets come out but shoot nobody.",
        "Système de défense hors ligne : les tourelles sortent mais ne tirent sur personne." },
    vanilla = { "Allied Defense off: the turrets behave as in the original game.",
        "Allied Defense désactivé : les tourelles se comportent comme dans le jeu original." },
}
board = { hooked = false, ours = {}, logged = {}, headers = {}, lang = nil, locked = false }
B_HIDDEN = 2

function resetPhases()
    phase.global, phase.turrets = nil, {}
    lastTrg = {}
end

function cycle(list, cur)
    for i, v in ipairs(list) do if v == cur then return list[(i % #list) + 1] end end
    return list[1]
end

-- text of a { English, French } pair in the Board language
function board.L(pair)
    if type(pair) ~= "table" then return tostring(pair) end
    return board.lang == "fr" and pair[2] or pair[1]
end

-- One Board entry per setting. index: the page's selection index (never used by the game's
-- lists; OmuAmmoPack uses 99). Clicking a selected entry runs next(). hostOnly: locked in
-- another player's lobby (only the host's settings drive the turrets).
-- label / value / text return { English, French } pairs.
board.onOff = function(b) return b and { "On", "Oui" } or { "Off", "Non" } end
BOARD_ITEMS = {
    { key = "mode", index = 98, hostOnly = true,
      label = { "Allied Defense", "Allied Defense" },
      value = function() return MODE_NAME[cfg.mode] or { cfg.mode, cfg.mode } end,
      text = function() return MODE_TEXT[cfg.mode] or { "", "" } end,
      next = function()
          local m = cycle(cfg.modeCycle, cfg.mode)
          if not VALID_MODES[m] then m = "phases" end
          cfg.mode = m
          STARTUP_MODE = m
          resetPhases()
          flushStats(true)
          return m
      end },
    { key = "lights", index = 97, hostOnly = true,
      label = { "Turret lights", "Voyants" },
      value = function() return cfg.revealPhase and { "Revealed", "Révélés" } or { "Hidden", "Cachés" } end,
      text = function()
          return { "Phases mode only. Hidden: a hostile turret shoots in green like an allied one, you never "
              .. "know which side it is on. Revealed: a hostile turret shoots in red.",
              "Mode Phases uniquement. Cachés : une tourelle hostile tire en vert comme une alliée, impossible "
              .. "de savoir de quel côté elle est. Révélés : une tourelle hostile tire en rouge." }
      end,
      next = function() cfg.revealPhase = not cfg.revealPhase return cfg.revealPhase and "revealed" or "hidden" end },
    { key = "length", index = 96, hostOnly = true,
      label = { "Phase length", "Durée des phases" },
      value = function()
          local n = phaseLengthName()
          return n == "short" and { "Short", "Courte" } or n == "long" and { "Long", "Longue" }
              or n == "normal" and { "Normal", "Normale" } or { "Custom", "Perso" }
      end,
      text = function()
          return { string.format("Phases mode only. How long the turrets stay on one side: Short 1-2 min, "
              .. "Normal 2-5 min, Long 5-10 min. Now: %d-%d s.", cfg.phaseMinSeconds, cfg.phaseMaxSeconds),
              string.format("Mode Phases uniquement. Combien de temps les tourelles restent d'un côté : Courte "
              .. "1-2 min, Normale 2-5 min, Longue 5-10 min. Actuellement : %d-%d s.", cfg.phaseMinSeconds, cfg.phaseMaxSeconds) }
      end,
      next = function()
          local n = cycle({ "short", "normal", "long" }, phaseLengthName())
          cfg.phaseMinSeconds, cfg.phaseMaxSeconds = PHASE_LENGTHS[n][1], PHASE_LENGTHS[n][2]
          resetPhases()
          return n
      end },
    { key = "sync", index = 95, hostOnly = true,
      label = { "Phase sync", "Synchro des phases" },
      value = function() return cfg.phasePerTurret and { "Each turret", "Par tourelle" } or { "All turrets", "Globale" } end,
      text = function()
          return { "Phases mode only. All turrets: the whole ship's defence switches side at once. "
              .. "Each turret: every turret has its own clock, allied and hostile turrets at the same time.",
              "Mode Phases uniquement. Globale : toute la défense du vaisseau change de camp en même temps. "
              .. "Par tourelle : chaque tourelle a sa propre horloge, alliées et hostiles en même temps." }
      end,
      next = function() cfg.phasePerTurret = not cfg.phasePerTurret resetPhases() return cfg.phasePerTurret and "each" or "all" end },
    { key = "canisters", index = 94, hostOnly = true,
      label = { "Explosive canisters", "Bidons explosifs" },
      value = function() return board.onOff(cfg.shootCanisters) end,
      text = function()
          return { "On: an allied turret shooting a specimen also hits a fire or frost canister lying next to it "
              .. "(never when a crew member stands within 8 m). Off: canisters are never hit by the mod.",
              "Oui : une tourelle alliée qui tire sur un spécimen touche aussi un bidon de feu ou de glace posé "
              .. "à côté (jamais si un membre d'équipage est à moins de 8 m). Non : le mod ne touche jamais les bidons." }
      end,
      next = function() cfg.shootCanisters = not cfg.shootCanisters return onoff(cfg.shootCanisters) end },
    { key = "hostileCanisters", index = 93, hostOnly = true,
      label = { "Hostile canisters", "Bidons hostiles" },
      value = function() return board.onOff(cfg.hostileShootCanisters) end,
      text = function()
          return { "On: a hostile turret also blows up the canister nearest to its target - even the one in "
              .. "your hands. Off: only allied turrets hit canisters.",
              "Oui : une tourelle hostile fait aussi exploser le bidon le plus proche de sa cible - même celui "
              .. "que vous tenez. Non : seules les tourelles alliées touchent les bidons." }
      end,
      next = function() cfg.hostileShootCanisters = not cfg.hostileShootCanisters return onoff(cfg.hostileShootCanisters) end },
    { key = "colours", index = 92,
      label = { "Turret colours", "Couleurs" },
      value = function() return cfg.modColours and { "Mod", "Mod" } or { "Game", "Jeu" } end,
      text = function()
          return { "Mod: amber scanning, green shooting (allied), purple chaos, grey neutral. In another player's "
              .. "game: always amber and green (the host's mode is secret). Game: the original green and red lights.",
              "Mod : ambre en veille, vert en tir (alliées), violet en chaos, gris en neutre. Dans la partie d'un "
              .. "autre joueur : toujours ambre et vert (le mode de l'hôte est secret). Jeu : les voyants vert "
              .. "et rouge d'origine." }
      end,
      next = function() cfg.modColours = not cfg.modColours return cfg.modColours and "mod" or "game" end },
}
-- entry title / description, in the Board language, "Host" when locked
function board.title(it)
    local sep = board.lang == "fr" and " : " or ": "
    local v = (it.hostOnly and board.locked) and { "Host", "Hôte" } or it.value()
    return board.L(it.label) .. sep .. board.L(v)
end
function board.text(it)
    if it.hostOnly and board.locked then
        return board.L({ "You are in another player's lobby: the host's settings drive the turrets. Your own choice ("
            .. it.value()[1] .. ") is kept for the games you host.",
            "Vous êtes dans le lobby d'un autre joueur : ce sont les réglages de l'hôte qui pilotent les tourelles. "
            .. "Votre choix (" .. it.value()[2] .. ") est conservé pour les parties que vous hébergez." })
    end
    return board.L(it.text()) .. "\n\n" .. board.L({ "Click again to change. Saved for your next games.",
        "Cliquez à nouveau pour changer. Enregistré pour vos prochaines parties." })
end
BOARD_BY_INDEX = {}
for _, it in ipairs(BOARD_ITEMS) do BOARD_BY_INDEX[it.index] = it end

function boardLogOnce(key, fmt, ...)
    if board.logged[key] then return end
    board.logged[key] = true
    log(fmt, ...)
end

function localController()
    for _, pc in ipairs(findAll("BP_MyPlayerController_C")) do
        local ok, isLocal = pcall(function() return pc:IsLocalController() end)
        if ok and isLocal then return pc end
    end
    return nil
end

-- our entries: full name -> item key
function boardKeyOf(e)
    if not valid(e) then return nil end
    local ok, n = pcall(function() return e:GetFullName() end)
    return ok and board.ours[n] or nil
end

function boardPages()
    local out = {}
    for _, w in ipairs(findAll(BOARD.pageClass)) do
        if valid(w) and valid(readProp(w, "Items_ScrollBox")) then out[#out + 1] = w end
    end
    return out
end

-- key -> our entry on this page
function boardEntries(w)
    local out = {}
    local sb = w.Items_ScrollBox
    for i = 0, sb:GetChildrenCount() - 1 do
        local c = sb:GetChildAt(i)
        local k = boardKeyOf(c)
        if k then out[k] = c end
    end
    return out
end

-- entry -> Items_ScrollBox -> the page's WidgetTree -> the page
function boardPageOf(e)
    local sb = e:GetParent()
    if not valid(sb) then return nil end
    local tree = sb:GetOuter()
    local w = tree and tree:GetOuter()
    if valid(w) and valid(readProp(w, "Items_ScrollBox")) then return w end
    return nil
end

function itemOf(key)
    for _, it in ipairs(BOARD_ITEMS) do if it.key == key then return it end end
    return nil
end

function boardDress(e, it)
    if e.bought ~= true then
        e.bought = true      -- the "bought" look: no price shown on the entry
        e:SetupPrice()
    end
    local t = board.title(it)
    if e.TxtTitle:GetText():ToString() ~= t then e.TxtTitle:SetText(FText(t)) end
end

-- the panel's picture: our PNG, imported when shown (a texture made from a file lives only
-- while something holds it: the brush does)
BOARD_ICON = modDir() .. "\\art\\AlliedDefense_icon.png"
function boardPicture(w, info)
    local pic = nil
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if valid(krl) then
        local ok, t = pcall(function() return krl:ImportFileAsTexture2D(w:GetWorld(), BOARD_ICON) end)
        if ok and valid(t) then pic = t end
    end
    local img = readProp(info, "Image")
    if pic then
        pcall(function() info.DynMat:SetTextureParameterValue(FName("Texture"), pic) end)
        if valid(img) then pcall(function() img:SetBrushFromTexture(pic, false) end) end
    else
        boardLogOnce("icon", "BOARD: picture not loaded (%s): panel picture hidden", BOARD_ICON)
        if valid(img) then pcall(function() img:SetVisibility(1) end) end   -- collapsed
    end
end

function boardShowInfo(w, it)
    local info = readProp(w, "WBP_ItemInfo")
    if not valid(info) then return end
    info:UpdateInfo({
        [BOARD_INFO.name] = FText(board.title(it)),
        [BOARD_INFO.description] = FText(board.text(it)),
        [BOARD_INFO.price] = 0,
        [BOARD_INFO.grade] = 0,
    })
    local sw = readProp(info, "WidgetSwitcher")
    if valid(sw) then sw:SetVisibility(B_HIDDEN) end   -- no price box
    pcall(boardPicture, w, info)
end

-- v1.4.0: our own section title ("ALLIED DEFENSE") above our entries, cloned from the page's
-- last section title (the "WEAPONS" one). The title's structure is not known in advance, so
-- the clone copies it generically: a Blueprint widget is created anew from its class, a
-- native panel / text / image is rebuilt piece by piece with its look copied (whole structs
-- copied from the original widget, never Lua tables). Logged once (layout) for diagnosis.
-- (shared) addHeader, headersOf, dressHeader -- (block-scoped helpers: Lua caps a chunk at 200 locals)
do
HEADER_TEXT = "ALLIED DEFENSE"
function wclass(wd)
    local ok, n = pcall(function() return wd:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end
function wchildren(wd)
    local out = {}
    local ok, n = pcall(function() return wd:GetChildrenCount() end)
    if ok and type(n) == "number" then
        for i = 0, n - 1 do
            local c = wd:GetChildAt(i)
            if valid(c) then out[#out + 1] = c end
        end
    else
        local tree = readProp(wd, "WidgetTree")
        local root = valid(tree) and readProp(tree, "RootWidget") or nil
        if valid(root) then out[1] = root end
    end
    return out
end
function wtext(wd)
    if wclass(wd) ~= "TextBlock" then return nil end
    local ok, t = pcall(function() return wd:GetText():ToString() end)
    return ok and t or nil
end
function textBlocks(wd, out, depth)
    out = out or {}
    depth = depth or 0
    if depth > 6 or not valid(wd) then return out end
    if wclass(wd) == "TextBlock" then out[#out + 1] = wd end
    for _, c in ipairs(wchildren(wd)) do textBlocks(c, out, depth + 1) end
    return out
end
function dumpTree(wd, depth, lines)
    if depth > 4 or not valid(wd) then return end
    local t = wtext(wd)
    lines[#lines + 1] = string.rep("  ", depth) .. wclass(wd) .. " " .. shortName(wd) .. (t and (' "' .. t .. '"') or "")
    for _, c in ipairs(wchildren(wd)) do dumpTree(c, depth + 1, lines) end
end

LOOK_PROPS = { "Font", "ColorAndOpacity", "Justification", "ShadowOffset", "ShadowColorAndOpacity",
    "Brush", "Size", "Margin", "MinDesiredWidth", "RenderOpacity", "Visibility", "AutoWrapText",
    "TextTransformPolicy", "LineHeightPercentage" }
SLOT_FUNCS = { { "Padding", "SetPadding" }, { "HorizontalAlignment", "SetHorizontalAlignment" },
    { "VerticalAlignment", "SetVerticalAlignment" }, { "Size", "SetSize" } }

-- native widget rebuilt piece by piece (depth-limited)
function cloneNative(src, tree, depth)
    if depth > 4 then return nil end
    local cls = src:GetClass()
    local dst = StaticConstructObject(cls, tree)
    if not valid(dst) then return nil end
    for _, pn in ipairs(LOOK_PROPS) do
        pcall(function() local v = src[pn]; if v ~= nil then dst[pn] = v end end)
    end
    local t = wtext(src)
    if t then pcall(function() dst:SetText(FText(t)) end) end
    for _, c in ipairs(wchildren(src)) do
        local cc = cloneNative(c, tree, depth + 1)
        if cc then
            local okA, slot = pcall(function() return dst:AddChild(cc) end)
            if okA and slot then
                for _, sf in ipairs(SLOT_FUNCS) do
                    pcall(function() slot[sf[2]](slot, c.Slot[sf[1]]) end)
                end
            end
        end
    end
    return dst
end

function cloneHeader(w, src)
    local cn = wclass(src)
    local dst
    if cn:sub(-2) == "_C" then
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        dst = valid(wbl) and wbl:Create(w, src:GetClass(), localController()) or nil
    else
        dst = cloneNative(src, w.WidgetTree, 0)
    end
    return dst
end

-- the page's last section title: the last child of the list that is not an entry button
-- The list holds, per section, a title (TextBlock) and a separator line (Image); a first try
-- copied only the separator. Now: the page's last text-bearing non-entry child is the title,
-- the last text-less one the separator; both copied, in the page's own order. No title found
-- in the list -> our own TextBlock, styled like an entry's title (font + colour).
function findHeader(w)
    local sb = w.Items_ScrollBox
    local title, sep, ti, si
    for i = 0, sb:GetChildrenCount() - 1 do
        local c = sb:GetChildAt(i)
        -- (entries: WBP_SelectEntryBtnBuy on SHOP, WBP_SelectEntryBtnUpgrades on UPGRADES)
        if valid(c) and wclass(c):sub(1, 15) ~= "WBP_SelectEntry" and not board.headers[c:GetFullName()] then
            if #textBlocks(c) > 0 then title, ti = c, i else sep, si = c, i end
        end
    end
    return title, sep, (ti or 1e9) < (si or 1e9)
end

function makeTitle(w)
    local cls = StaticFindObject("/Script/UMG.TextBlock")
    if not valid(cls) then return nil end
    local tb = StaticConstructObject(cls, w.WidgetTree)
    if not valid(tb) then return nil end
    local model = nil
    local sb = w.Items_ScrollBox
    for i = 0, sb:GetChildrenCount() - 1 do
        local c = sb:GetChildAt(i)
        if valid(c) and wclass(c):sub(1, 15) == "WBP_SelectEntry" then model = c.TxtTitle break end
    end
    if valid(model) then
        for _, pn in ipairs({ "Font", "ColorAndOpacity", "ShadowOffset", "ShadowColorAndOpacity", "TextTransformPolicy" }) do
            pcall(function() local v = model[pn]; if v ~= nil then tb[pn] = v end end)
        end
    end
    pcall(function() tb:SetText(FText(HEADER_TEXT)) end)
    return tb
end

function dressHeader(hd)
    local any = false
    local tbs = textBlocks(hd)
    for _, tb in ipairs(tbs) do
        local ok, cur = pcall(function() return tb:GetText():ToString() end)
        if ok and cur ~= "" then
            any = true
            if cur ~= HEADER_TEXT then pcall(function() tb:SetText(FText(HEADER_TEXT)) end) end
        end
    end
    if not any and tbs[1] then pcall(function() tbs[1]:SetText(FText(HEADER_TEXT)) end) end
end

function appendHeader(w, hd, src)
    if not valid(hd) then return end
    board.headers[hd:GetFullName()] = true
    local okA, slot = pcall(function() return w.Items_ScrollBox:AddChild(hd) end)
    if okA and slot and src then
        for _, sf in ipairs(SLOT_FUNCS) do pcall(function() slot[sf[2]](slot, src.Slot[sf[1]]) end) end
    end
    dressHeader(hd)
end

function addHeader(w)
    if cfg.debugLogs and not board.layoutLogged then
        board.layoutLogged = true
        local lines = {}
        local sb = w.Items_ScrollBox
        for i = 0, sb:GetChildrenCount() - 1 do
            local c = sb:GetChildAt(i)
            if valid(c) and wclass(c) ~= BOARD.entryClass then dumpTree(c, 1, lines)
            elseif valid(c) then lines[#lines + 1] = "  (entry)" end
        end
        log("BOARD: SHOP list layout:\n%s", table.concat(lines, "\n"))
    end
    local title, sep, titleFirst = findHeader(w)
    local okT, th = false, nil
    if title then okT, th = pcall(cloneHeader, w, title) end
    if not okT or not valid(th) then
        title = nil
        okT, th = pcall(makeTitle, w)
        if not okT or not valid(th) then
            boardLogOnce("hdr", "BOARD: could not make the section title (%s): no ALLIED DEFENSE title", tostring(th))
            th = nil
        end
    end
    local sh = nil
    if sep then local okS, x = pcall(cloneHeader, w, sep); if okS and valid(x) then sh = x end end
    if titleFirst or not sh then
        appendHeader(w, th, title); appendHeader(w, sh, sep)
    else
        appendHeader(w, sh, sep); appendHeader(w, th, title)
    end
    if cfg.debugLogs then boardLogOnce("hdrok", "BOARD: section title %s (%s)%s", th and "added" or "missing",
        title and ("copied from " .. wclass(title)) or "own TextBlock", sh and " + separator" or "") end
end

function headersOf(w)
    local out = {}
    local sb = w.Items_ScrollBox
    for i = 0, sb:GetChildrenCount() - 1 do
        local c = sb:GetChildAt(i)
        if valid(c) and board.headers[c:GetFullName()] then out[#out + 1] = c end
    end
    return out
end
end

-- Our missing entries, appended after the last entry of the list (in BOARD_ITEMS order).
function boardFit(w)
    local have = boardEntries(w)
    local missing = {}
    for _, it in ipairs(BOARD_ITEMS) do if not have[it.key] then missing[#missing + 1] = it end end
    if #missing == 0 then return 0 end
    local btns = w.entryBtns
    local n = #btns
    if n < 1 or not valid(readProp(w, "mainWidget")) then return 0 end
    local last = btns[n]
    if not valid(last) then return 0 end
    local cls = StaticFindObject(BOARD.entryPath)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local pc = localController()
    if not valid(cls) or not valid(wbl) or not valid(pc) then return 0 end
    local lp = last.Slot.Padding
    -- first time on this page: our section title first
    if #missing == #BOARD_ITEMS and cfg.boardSectionTitle then pcall(addHeader, w) end
    local added = 0
    for _, it in ipairs(missing) do
        local e = wbl:Create(w, cls, pc)
        if not valid(e) then break end
        board.ours[e:GetFullName()] = it.key
        e.Data = last.Data          -- a whole struct copied from another widget (never a Lua table)
        e.bought = true
        e.Price = 0
        e.Unavailable = false
        e.GradeUnlock = 0
        w.Items_ScrollBox:AddChild(e):SetPadding({ Left = lp.Left, Top = lp.Top, Right = lp.Right, Bottom = lp.Bottom })
        w:SetupButtonStyle(e)
        w.mainWidget:RegisterDynWidget(e.WanaCross_Button_128)
        pcall(function() e.WanaCross_Button_128.rightBlock = true end)
        e:SetupPrice()
        e:SetSelected(false)
        boardDress(e, it)
        added = added + 1
    end
    return added
end

function boardRefreshAll()
    for _, w in ipairs(boardPages()) do
        for key, e in pairs(boardEntries(w)) do
            local it = itemOf(key)
            if it then pcall(boardDress, e, it) end
        end
        local sel = BOARD_BY_INDEX[w.equipedEntryIdx]
        if sel then pcall(boardShowInfo, w, sel) end
    end
end

function boardClick(w, e, it)
    if w.equipedEntryIdx ~= it.index then
        -- first click: select this entry, like the game selects its own
        w.equipedEntryIdx = it.index
        local arr = w.entryBtns
        for i = 1, #arr do
            local b = arr[i]
            if valid(b) then pcall(function() b:ResetSelectAnim() end) end
        end
        for key, other in pairs(boardEntries(w)) do
            if key ~= it.key and other.Selected then pcall(function() other:ResetSelectAnim() end) end
        end
        if not e.Selected then e:SetSelected(true) end
        boardShowInfo(w, it)
        return
    end
    if it.hostOnly and board.locked then
        boardShowInfo(w, it)
        boardLogOnce("locked" .. it.key, "BOARD: %s locked (another player's lobby: the host decides)", it.key)
        return
    end
    local v = it.next()
    local saved = saveSettings()
    log("BOARD: %s -> %s%s", it.key, tostring(v), saved and " (saved)" or " (could not write settings.txt)")
    boardRefreshAll()
end

function boardInstallHooks()
    if board.hooked then return end
    if not valid(FindFirstOf(BOARD.pageClass)) or not valid(FindFirstOf(BOARD.entryClass)) then return end
    if not valid(StaticFindObject(BOARD.pagePath)) or not valid(StaticFindObject(BOARD.entryPath)) then return end
    board.hooked = true
    local ok1, err1 = pcall(RegisterHook, BOARD.entryPath .. ":" .. BOARD.clickEvent, function(ctx)
        local e = ctx:get()
        local it = itemOf(boardKeyOf(e) or "")
        if not it then return end
        local w = boardPageOf(e)
        if not w then return end
        pcall(function() w.errorSoundNeeded = false end)
        ExecuteInGameThread(function()
            if valid(w) and valid(e) then
                local ok, err = pcall(boardClick, w, e, it)
                if not ok then logErr("board click", err) end
            end
        end)
    end)
    if not ok1 then log("BOARD: click hook failed: %s", tostring(err1)) end
    -- the game selected one of its entries: ours lose their highlight
    local ok2, err2 = pcall(RegisterHook, BOARD.pagePath .. ":ShowEntry", function(ctx)
        local w = ctx:get()
        if not valid(w) or BOARD_BY_INDEX[w.equipedEntryIdx] then return end
        for _, e in pairs(boardEntries(w)) do
            if e.Selected then pcall(function() e:ResetSelectAnim() end) end
        end
    end)
    if not ok2 then log("BOARD: ShowEntry hook failed: %s", tostring(err2)) end
    log("BOARD: Personal Board hooks in")
end

-- ~1 s background step: nothing to do outside the lobby (no SHOP page loaded).
-- v1.4.1: Board language (game culture, else the game's own section titles) and lock state
-- (the local controller has no authority = we joined another player's lobby)
function board.context()
    -- v1.4.1: the language is checked on every step (the player can switch it in the game's
    -- options while the Board is open). First source: the game's own section titles on the SHOP
    -- page, which show the language the game really displays ("Armes" / "Outils" = French,
    -- anything else = English). Fallback when the page has no title: the engine culture.
    local lang, how
    local want = cfg.boardLanguage
    if want == "en" or want == "fr" then lang, how = want, "config"
    else
        for _, w in ipairs(boardPages()) do
            local sb = w.Items_ScrollBox
            for i = 0, sb:GetChildrenCount() - 1 do
                local c = sb:GetChildAt(i)
                if valid(c) and not board.headers[c:GetFullName()] then
                    local okT, t = pcall(function() return c:GetText():ToString() end)
                    if okT and type(t) == "string" and t ~= "" then
                        local tl = t:lower()
                        if tl == "armes" or tl == "outils" then lang = "fr" else lang = lang or "en" end
                        how = 'section title "' .. t .. '"'
                        if lang == "fr" then break end
                    end
                end
            end
            if lang then break end
        end
        if not lang then
            if not board.culture then
                board.culture = "?"
                local lib = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
                if valid(lib) then
                    local ok, c = pcall(function() return lib:GetCurrentLanguage() end)
                    if ok and c ~= nil and type(c) ~= "string" then local ok2, sv = pcall(function() return c:ToString() end); c = ok2 and sv or nil end
                    if type(c) == "string" and c ~= "" then board.culture = c end
                end
            end
            lang = board.culture:lower():sub(1, 2) == "fr" and "fr" or "en"
            how = "culture " .. board.culture
        end
    end
    if lang ~= board.lang then
        board.lang = lang
        log("BOARD: language %s (%s)", lang, how)
    end
    local pc = localController()
    local locked = valid(pc) and not hasAuthority(pc)
    if locked ~= board.locked then
        board.locked = locked
        log(locked and "BOARD: another player's lobby -> host settings locked (only Turret colours can be changed)"
            or "BOARD: own lobby -> all settings unlocked")
        return true
    end
    return false
end

function boardStep()
    if upgradesStep then pcall(upgradesStep) end   -- upgrades.lua (UPGRADES page)
    if not cfg.boardSettings then return end
    if not valid(FindFirstOf(BOARD.pageClass)) then return end
    boardInstallHooks()
    pcall(board.context)
    local added, pages = 0, 0
    for _, w in ipairs(boardPages()) do
        local ok, res = pcall(boardFit, w)
        if not ok then boardLogOnce("fit", "BOARD: could not add the entries: %s", tostring(res))
        elseif res > 0 then added = added + res pages = pages + 1 end
        for key, e in pairs(boardEntries(w)) do
            local it = itemOf(key)
            if it then pcall(boardDress, e, it) end
        end
        for _, hd in ipairs(headersOf(w)) do pcall(dressHeader, hd) end
    end
    if added > 0 then
        log("BOARD: %d Allied Defense entries added to %d SHOP page(s) (mode %s)", added, pages, cfg.mode)
    end
end

function background()
    local client = false
    pcall(function() client = amClient() end)
    pcall(boardStep)
    if client then
        pcall(refreshLists, true)
        pcall(applyTurretSettings)
        flushStats(false)
        return
    end
    local steps = {
        { "hooks", tryRegisterHooks }, { "lists", refreshLists, true },
        { "dmgHooks", tryRegisterDamageHooks }, { "restore", restoreHookFn }, { "allyHits", checkAllyHits },
        { "phases", updatePhases }, { "canisters", refreshCanisters }, { "unstick", unstickTurrets }, { "settings", applyTurretSettings }, { "wake", wakeTurrets },
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

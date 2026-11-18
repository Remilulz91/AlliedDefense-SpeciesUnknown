-- AlliedDefense / upgrades.lua - turret upgrades bought with the game's U.Credits on the
-- Personal Board's UPGRADES page (v1.4.2).
-- Loaded by main.lua into the mod's shared environment (see core.lua).
--
-- The page (WBP_EquipmentUpgradePage) lists one WBP_SelectEntryBtnUpgrades per game upgrade
-- in Items_ScrollBox, under section titles (TextBlock + separator Image), and keeps the game's
-- ones in ButtonsUpgrades (indexes 0-9). Ours go at the end, under our own ALLIED DEFENSE title,
-- and are never put in ButtonsUpgrades (the page indexes the game's save by that position):
-- the entry's own click event is hooked instead.
--
-- Buying goes through the game's own popup: our price in the page's Price and our index in
-- HoveredEntryIdx, then ShowPopupBuyItem. Its Yes checks the wallet, takes the money and calls
-- ConfirmBuyItem(index); the game finds nothing at our index and saves nothing, we raise the
-- level in upgrades.txt (this mod's file, never the game's save).
--
-- Levels: 0 = nothing bought, 1 = I, 2 = II. The page's own level runs one below (-1, 0, 1).
--
-- Effect: the turret has no damage value of its own (the shot's damage is fixed inside
-- its Blueprint), so the upgrades act on its fire rate instead: Handle_Shoot (host side, called
-- every frame while it aims) sets fire_delay from its original 0.1 s: /(1 + calibration) on a
-- specimen, /(1 - dampers) on a crew member. Same firepower change per second as the damage.
-- Vanilla mode / mod disabled: the original value.

UPG = {
    pageClass = "WBP_EquipmentUpgradePage_C",
    pagePath = "/Game/Blueprints/Screens/Terminals/Equipment/WBP_EquipmentUpgradePage.WBP_EquipmentUpgradePage_C",
    entryClass = "WBP_SelectEntryBtnUpgrades_C",
    entryPath = "/Game/Blueprints/Screens/Terminals/Common/WBP_SelectEntryBtnUpgrades.WBP_SelectEntryBtnUpgrades_C",
    path = modDir() .. "\\upgrades.txt",
    hooked = false,
    levels = {},
    base = {},      -- turret full name -> its original fire_delay
    drawn = {},     -- entry full name -> what its circles show
    logged = {},
}
-- S_ToolInfo members (generated names of the game's struct)
UPG_INFO = {
    name = "name_22_DF53FCB945C10E89DD252081735211E6",
    description = "description_8_48BD289C4ADECF7DE7ED6B9D964B2E6F",
    price = "price_19_9C1078A245DAAA1D2BA7CAA789069692",
    up0 = "Upgrade_0_Text_25_64FB35A0473625AA032FD78EEFE7D143",
    up1 = "Upgrade_1_Text_28_2413556B47B7D5382CC49C99F995F9D9",
    up1Price = "Upgrade_1_Price_32_F8244B754A9067D6AFF99C916B777EDD",
    up2 = "Upgrade_2_Text_29_9FC6A2E148AEE17C7C22928CF0D05081",
    up2Price = "Upgrade_2_Price_34_D6E4A0E145F978BFF8B69DA2F9FB1BB4",
    grade = "GradeUnlock_47_9B0032F74E5F8E4EDAF39D93DCB43CFE",
}
-- Prices: middle of the game's own upgrades (level I 1 000 - 12 500, level II 1 500 - 14 500).
-- index: the page's selection index (game upgrades use 0-9, OmuAmmoPack 99).
UPGRADES = {
    { key = "calibration", index = 91, row = "AlliedDefense_Calibration", art = "Calibration",
      prices = { 4000, 6000 }, values = { 0.5, 1.0 },
      title = { "Gun calibration", "Calibrage des canons" },
      text = { "The ceiling turrets were tuned for a crew that never fought back. A careful recalibration "
          .. "of their feed lets them keep up a much faster fire against the specimens.",
          "Les tourelles du plafond ont été réglées pour un équipage qui ne ripostait jamais. Un "
          .. "recalibrage soigné de leur alimentation leur permet de tirer bien plus vite sur les spécimens." },
      levels = { { "Fires 50% faster at specimens", "Tire 50 % plus vite sur les spécimens" },
          { "Fires twice as fast at specimens", "Tire deux fois plus vite sur les spécimens" } } },
    { key = "dampers", index = 90, row = "AlliedDefense_Dampers", art = "Dampers",
      prices = { 3500, 5000 }, values = { 0.25, 0.5 },
      title = { "Crew dampers", "Amortisseurs" },
      text = { "When the defence system turns on the crew, it still has to go through the dampers: "
          .. "its fire slows down as soon as the target wears a suit.",
          "Quand le système de défense se retourne contre l'équipage, il doit encore passer par les "
          .. "amortisseurs : son tir ralentit dès que la cible porte une combinaison." },
      levels = { { "Fires 25% slower at the crew", "Tire 25 % moins vite sur l'équipage" },
          { "Fires half as fast at the crew", "Tire deux fois moins vite sur l'équipage" } } },
}
UPG_BY_INDEX, UPG_BY_ROW = {}, {}
for _, it in ipairs(UPGRADES) do UPG_BY_INDEX[it.index] = it; UPG_BY_ROW[it.row] = it end

---------------------------------------------------------------------------
-- Levels (upgrades.txt) and wallet
---------------------------------------------------------------------------
function upgLoad()
    for _, it in ipairs(UPGRADES) do UPG.levels[it.key] = 0 end
    if cfg.resetUpgrades then
        upgSave()
        log("UPGRADES: reset (resetUpgrades = true in config.lua)")
        return
    end
    local f = io.open(UPG.path, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(%d+)")
        if k and UPG.levels[k] ~= nil then UPG.levels[k] = math.max(0, math.min(2, tonumber(v))) end
    end
    f:close()
end

function upgSave()
    local f = io.open(UPG.path, "w")
    if not f then return false end
    f:write("-- Allied Defense turret upgrades (0 = none, 1 = I, 2 = II), bought on the Personal Board.\n")
    for _, it in ipairs(UPGRADES) do f:write(it.key, "=", tostring(UPG.levels[it.key] or 0), "\n") end
    f:close()
    return true
end

function upgLevel(it) return UPG.levels[it.key] or 0 end
function upgValue(key)
    for _, it in ipairs(UPGRADES) do
        if it.key == key then
            local l = upgLevel(it)
            return l > 0 and it.values[l] or 0
        end
    end
    return 0
end

function upgMoney()
    local gi = FindFirstOf("BP_MyGameInstance_C")
    local save = valid(gi) and readProp(gi, "progressSaveInstance") or nil
    local m = valid(save) and readProp(save, "moneyAmount") or nil
    return type(m) == "number" and m or nil
end

-- can the wallet pay the next level? (unknown wallet: yes, the game's popup checks again)
function upgAffordable(it)
    local price = it.prices[upgLevel(it) + 1]
    local money = upgMoney()
    return price ~= nil and (money == nil or money >= price)
end

function upgLogOnce(key, fmt, ...)
    if UPG.logged[key] then return end
    UPG.logged[key] = true
    log(fmt, ...)
end

---------------------------------------------------------------------------
-- Effect on the shots (called by preShootFire, host only)
---------------------------------------------------------------------------
function applyUpgradeDamage(t)
    local okN, key = pcall(function() return t:GetFullName() end)
    if not okN or not key then return end
    local base = UPG.base[key]
    if base == nil then
        base = readProp(t, "fire_delay")
        if type(base) ~= "number" or base <= 0 then
            upgLogOnce("nodelay", "UPGRADES: %s has no readable fire_delay (%s): upgrades have no effect", shortName(t), tostring(base))
            return
        end
        UPG.base[key] = base
    end
    -- firepower multiplier: x(1 + calibration) on a specimen, x(1 - dampers) on a crew member
    local mult = 1
    local k = kindOf(readProp(t, "current_trg"))
    if cfg.enabled and cfg.mode ~= "vanilla" then
        if k == "monster" then mult = 1 + upgValue("calibration")
        elseif k == "player" then mult = 1 - upgValue("dampers") end
    end
    local want = base / mult      -- delay between two shots: shorter = faster
    local cur = readProp(t, "fire_delay")
    if type(cur) == "number" and math.abs(cur - want) > 1e-6 then
        t.fire_delay = want
        if mult > 1 then count("firerate_up") elseif mult < 1 then count("firerate_down") else count("firerate_reset") end
        UPG.changes = (UPG.changes or 0) + 1
        if cfg.debugLogs and UPG.changes <= 8 then
            log("UPGRADES: %s aiming at a %s: fire_delay %.3f -> %.3f s (read back %s)", shortName(t), tostring(k),
                cur, want, tostring(readProp(t, "fire_delay")))
        end
    end
end

---------------------------------------------------------------------------
-- The UPGRADES page
---------------------------------------------------------------------------
function upgPages()
    local out = {}
    for _, w in ipairs(findAll(UPG.pageClass)) do
        if valid(readProp(w, "Items_ScrollBox")) then out[#out + 1] = w end
    end
    return out
end

function upgItemOf(e)
    if not valid(e) then return nil end
    local ok, r = pcall(function() return e.RowName:ToString() end)
    return ok and UPG_BY_ROW[r] or nil
end

function upgEntries(w)
    local out = {}
    local sb = w.Items_ScrollBox
    for i = 0, sb:GetChildrenCount() - 1 do
        local c = sb:GetChildAt(i)
        if valid(c) and wclass(c) == UPG.entryClass then
            local it = upgItemOf(c)
            if it then out[it.key] = c end
        end
    end
    return out
end

-- the game's last upgrade entry (a weapon: two levels, like ours): layout and circle pictures
function upgModel(w)
    local arr = w.ButtonsUpgrades
    local n = #arr
    for i = n, 1, -1 do
        local b = arr[i]
        if valid(b) then return b end
    end
    return nil
end

UPG_CIRCLE_PARTS = { "ImgSeparator2", "FakeCircleUpgradeSpacer3", "WBP_CircleUpgrade3", "Spacer2" }

function upgCircles(e, it, model)
    local pageLevel = upgLevel(it) - 1
    local affordable = upgAffordable(it)
    for i = 1, 2 do
        local c = e["WBP_CircleUpgrade" .. i]
        if valid(c) then
            -- our circle pictures (art/<Upgrade>_<level>.png), else the model's (a game weapon)
            local tex = upgTexture(e, it.art .. "_" .. i .. ".png")
            if tex then
                pcall(function() c.lockedUpgradeTexture = tex end)
                pcall(function() c.boughtUpgradeTexture = tex end)
            elseif model then
                local mc = model["WBP_CircleUpgrade" .. i]
                if valid(mc) then
                    pcall(function() c.lockedUpgradeTexture = mc.lockedUpgradeTexture end)
                    pcall(function() c.boughtUpgradeTexture = mc.boughtUpgradeTexture end)
                end
            end
            c:SetLocked()
            if pageLevel >= i - 1 then c:SetBought()
            elseif pageLevel + 1 == i - 1 then
                c:SetUnlockable()
                if not affordable then c:SetNotBuyable() end   -- the game's red price mark
            end
        end
    end
    if model then
        for _, n in ipairs(UPG_CIRCLE_PARTS) do
            pcall(function() e[n]:SetVisibility(model[n]:GetVisibility()) end)
        end
        pcall(function()
            local p = model.ImgUpgradesBG.Slot.Padding
            e.ImgUpgradesBG.Slot:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
        end)
    end
    pcall(function() e.MaxLevel = 2 end)
    pcall(function() e.UpgradeLevel = pageLevel end)
    pcall(function() e.BorderMax:SetVisibility(pageLevel >= 1 and 4 or 1) end)
end

function upgDrawKey(it) return upgLevel(it) .. ":" .. tostring(upgAffordable(it)) .. ":" .. tostring(board.lang) end

function upgDress(e, it, model)
    local t = board.L(it.title)
    pcall(function()
        if e.TxtTitle:GetText():ToString() ~= t then e.TxtTitle:SetText(FText(t)) end
    end)
    local name = e:GetFullName()
    local k = upgDrawKey(it)
    if UPG.drawn[name] ~= k then
        UPG.drawn[name] = k
        upgCircles(e, it, model)
    end
end

function upgFit(w)
    local have = upgEntries(w)
    local missing = {}
    for _, it in ipairs(UPGRADES) do if not have[it.key] then missing[#missing + 1] = it end end
    if #missing == 0 then return 0 end
    local model = upgModel(w)
    if not model or not valid(readProp(w, "mainWidget")) then return 0 end
    local cls = StaticFindObject(UPG.entryPath)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local pc = localController()
    if not valid(cls) or not valid(wbl) or not valid(pc) then return 0 end
    if #missing == #UPGRADES and cfg.boardSectionTitle then pcall(addHeader, w) end
    local mp = model.Slot.Padding
    local added = 0
    for _, it in ipairs(missing) do
        local e = wbl:Create(w, cls, pc)
        if not valid(e) then break end
        e.RowName = FName(it.row)
        w.Items_ScrollBox:AddChild(e):SetPadding({ Left = mp.Left, Top = mp.Top, Right = mp.Right, Bottom = mp.Bottom })
        w.mainWidget:RegisterDynWidget(e.WanaCross_Button_128)
        pcall(function() e.WanaCross_Button_128.rightBlock = true end)
        UPG.drawn[e:GetFullName()] = nil
        upgDress(e, it, model)
        e:SetSelected(false)
        added = added + 1
    end
    return added
end

---------------------------------------------------------------------------
-- Info panel, clicks, buying
---------------------------------------------------------------------------
-- our pictures (art folder), imported once and kept while the texture lives
UPG_ART = modDir() .. "\\art\\"
UPG.tex = {}
function upgTexture(w, file)
    local t = UPG.tex[file]
    if valid(t) then return t end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not valid(krl) then return nil end
    local ok, pic = pcall(function() return krl:ImportFileAsTexture2D(w:GetWorld(), UPG_ART .. file) end)
    if ok and valid(pic) then UPG.tex[file] = pic return pic end
    upgLogOnce("tex" .. file, "UPGRADES: picture not loaded: %s", UPG_ART .. file)
    return nil
end

-- wide picture for the info panel, tall one for the purchase splash (square icon as fallback)
function upgPicture(w, img, file)
    if not valid(img) then return end
    local pic = upgTexture(w, file) or upgTexture(w, "AlliedDefense_icon.png")
    if pic then pcall(function() img:SetBrushFromTexture(pic, false) end) end
end

function upgShowInfo(w, it)
    local info = readProp(w, "WBP_UpgradeInfo")
    if not valid(info) then return end
    local text = board.L(it.text) .. "\n\n" .. board.L({
        "Applies to the turrets of the games you host. Click again to buy the next level.",
        "S'applique aux tourelles des parties que vous hébergez. Cliquez à nouveau pour acheter le niveau suivant." })
    info:UpdateInfo({
        [UPG_INFO.name] = FText(board.L(it.title)),
        [UPG_INFO.description] = FText(text),
        [UPG_INFO.price] = 0,
        [UPG_INFO.up0] = FText(""),
        [UPG_INFO.up1] = FText(board.L(it.levels[1])),
        [UPG_INFO.up1Price] = it.prices[1],
        [UPG_INFO.up2] = FText(board.L(it.levels[2])),
        [UPG_INFO.up2Price] = it.prices[2],
        [UPG_INFO.grade] = 0,
    })
    pcall(function() info:ChangeIndexUpgradeInfo(upgLevel(it) - 1) end)
    pcall(upgPicture, w, readProp(info, "ImgUpgrade"), "AlliedDefense_wide.png")
end

-- first click selects (the panel shows ours), a click on the selected entry buys the next level
function upgClick(w, e, it)
    if w.equipedEntryIdx ~= it.index then
        w.equipedEntryIdx = it.index
        local arr = w.ButtonsUpgrades
        for i = 1, #arr do
            local b = arr[i]
            if valid(b) then pcall(function() b:ResetSelectAnim() end) end
        end
        for key, other in pairs(upgEntries(w)) do
            if key ~= it.key and other.Selected then pcall(function() other:ResetSelectAnim() end) end
        end
        if not e.Selected then e:SetSelected(true) end
        upgShowInfo(w, it)
        return
    end
    local price = it.prices[upgLevel(it) + 1]
    if not price then return end   -- (maxed out: refused in the click hook)
    w.Price = price
    w.HoveredEntryIdx = it.index
    w:ShowPopupBuyItem()
end

-- the game's "upgrade purchased" splash gets our name, level line and picture
function upgDressSplash(w, it, level)
    local s = readProp(readProp(w, "mainWidget"), "WidgetUpgradePurchased")
    if not valid(s) then return end
    pcall(upgPicture, w, readProp(s, "ImgUpgrade"), "AlliedDefense_tall.png")
    pcall(function() s.TextItem:SetText(FText(board.L(it.title))) end)
    pcall(function() s.TextUpgradeDesc:SetText(FText(board.L(it.levels[level]))) end)
    pcall(function() s.TextIndexUpgrade:SetText(FText(level == 2 and "II" or "I")) end)
end

-- the popup's Yes took the money and called ConfirmBuyItem(our index)
function upgBought(w, it)
    local level = upgLevel(it)
    if level >= 2 then return end
    UPG.levels[it.key] = level + 1
    local saved = upgSave()
    log("UPGRADES: %s -> level %d (%d credits)%s", it.key, level + 1, it.prices[level + 1],
        saved and " (saved)" or " (could not write upgrades.txt)")
    pcall(upgDressSplash, w, it, level + 1)
    for _, p in ipairs(upgPages()) do
        local e = upgEntries(p)[it.key]
        if e then pcall(upgDress, e, it, nil) end
    end
    if w.equipedEntryIdx == it.index then pcall(upgShowInfo, w, it) end
end

function upgInstallHooks()
    if UPG.hooked then return end
    if not valid(FindFirstOf(UPG.pageClass)) or not valid(FindFirstOf(UPG.entryClass)) then return end
    if not valid(StaticFindObject(UPG.pagePath)) or not valid(StaticFindObject(UPG.entryPath)) then return end
    UPG.hooked = true
    local ok1, err1 = pcall(RegisterHook, UPG.entryPath .. ":" .. BOARD.clickEvent, function(ctx)
        local e = ctx:get()
        local it = upgItemOf(e)
        if not it then return end
        local w = boardPageOf(e)
        if not w then return end
        if w.equipedEntryIdx == it.index then
            -- a buy click: maxed out or too little money is refused here (shake + error sound)
            local price = it.prices[upgLevel(it) + 1]
            local money = price and upgMoney()
            local refused = price == nil or (money ~= nil and money < price)
            pcall(function() w.errorSoundNeeded = refused end)
            if refused then pcall(function() e:PlayErrorAnim() end) return end
        else
            pcall(function() w.errorSoundNeeded = false end)
        end
        ExecuteInGameThread(function()
            if valid(w) and valid(e) then
                local ok, err = pcall(upgClick, w, e, it)
                if not ok then logErr("upgrade click", err) end
            end
        end)
    end)
    if not ok1 then log("UPGRADES: click hook failed: %s", tostring(err1)) end
    local ok2, err2 = pcall(RegisterHook, UPG.pagePath .. ":ConfirmBuyItem", function(ctx, pIndex)
        local w = ctx:get()
        local okI, idx = pcall(function() return pIndex:get() end)
        local it = okI and UPG_BY_INDEX[idx] or nil
        if not it or not valid(w) then return end
        ExecuteInGameThread(function()
            if valid(w) then
                local ok, err = pcall(upgBought, w, it)
                if not ok then logErr("upgrade bought", err) end
            end
        end)
    end)
    if not ok2 then log("UPGRADES: ConfirmBuyItem hook failed: %s", tostring(err2)) end
    -- the game selected one of its entries: ours lose their highlight
    local ok3, err3 = pcall(RegisterHook, UPG.pagePath .. ":ShowItemEntry", function(ctx)
        local w = ctx:get()
        if not valid(w) or UPG_BY_INDEX[w.equipedEntryIdx] then return end
        for _, e in pairs(upgEntries(w)) do
            if e.Selected then pcall(function() e:ResetSelectAnim() end) end
        end
    end)
    if not ok3 then log("UPGRADES: ShowItemEntry hook failed: %s", tostring(err3)) end
    log("UPGRADES: upgrade page hooks in")
end

-- ~1 s, from boardStep (game thread)
function upgradesStep()
    if not cfg.boardUpgrades then return end
    if not valid(FindFirstOf(UPG.pageClass)) then return end
    upgInstallHooks()
    local added, pages = 0, 0
    for _, w in ipairs(upgPages()) do
        local ok, res = pcall(upgFit, w)
        if not ok then upgLogOnce("fit", "UPGRADES: could not add the entries: %s", tostring(res))
        elseif res > 0 then added = added + res pages = pages + 1 end
        for key, e in pairs(upgEntries(w)) do
            for _, it in ipairs(UPGRADES) do
                if it.key == key then pcall(upgDress, e, it, nil) end
            end
        end
        for _, hd in ipairs(headersOf(w)) do pcall(dressHeader, hd) end
    end
    if added > 0 then
        log("UPGRADES: %d entries added to %d UPGRADES page(s) (calibration %d, dampers %d)", added, pages,
            UPG.levels.calibration or 0, UPG.levels.dampers or 0)
    end
end

upgLoad()
log("UPGRADES: calibration level %d, dampers level %d", UPG.levels.calibration or 0, UPG.levels.dampers or 0)

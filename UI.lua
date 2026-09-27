local _, ns = ...
local cfg, util, comms, bettor, bookie = ns.config, ns.util, ns.comms, ns.bettor, ns.bookie
local money = util.money
local COPPER_PER_GOLD = util.COPPER_PER_GOLD

local ui = {}
ns.ui = ui

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
local SIDE_COLOR = { red = { 1, 0.32, 0.32 }, blue = { 0.35, 0.65, 1 } } -- fighter card colours

local DIALOG_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local TOOLTIP_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- Helpers

local function makeText(parent, font, point, x, y)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetPoint(point, x, y)
    return text
end

local function makeButton(parent, label, width, x, y, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetPoint("TOPLEFT", x, y)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

local function setEnabled(button, enabled)
    if enabled then button:Enable() else button:Disable() end
end

local function setShown(region, shown)
    if shown then region:Show() else region:Hide() end
end

-- Measures text, so windows can grow to fit long names
local measurer = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
measurer:SetAlpha(0) -- invisible but still shown: hidden text may report no width
measurer:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 0, -100) -- off screen

local function textWidth(font, text)
    measurer:SetFontObject(font)
    measurer:SetText(text or "")
    return measurer:GetStringWidth()
end

local BUTTON_PADDING = 28 -- room around a button's label

-- Buttons whose width follows the window: column 1 hugs the left edge, column 2 the right
local halfButtons = {}

local function makeHalfButton(parent, label, column, y, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(160, 22)
    button:SetPoint(column == 1 and "TOPLEFT" or "TOPRIGHT", 0, y)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    table.insert(halfButtons, button)
    return button
end

local editBoxCount = 0 -- for unique edit box names

local function makeNumberBox(parent, width, x, y)
    editBoxCount = editBoxCount + 1
    local box = CreateFrame("EditBox", "GamblerNumberBox" .. editBoxCount, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetPoint("TOPLEFT", x, y)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(7)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEditFocusGained", function(self) self.editing = true end)
    box:SetScript("OnEditFocusLost", function(self) self.editing = false end)
    return box
end

-- The game's gold / silver / copper input
local function makeMoneyInput(parent, name, x, y)
    local input = CreateFrame("Frame", name, parent, "MoneyInputFrameTemplate")
    input:SetPoint("TOPLEFT", x, y)
    return input
end

StaticPopupDialogs.GAMBLER_CONFIRM = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, onYes) onYes() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function confirm(question, onYes)
    StaticPopup_Show("GAMBLER_CONFIRM", question, nil, onYes)
end

-- Main window

local frame = CreateFrame("Frame", "GamblerFrame", UIParent, BACKDROP_TEMPLATE)
frame:SetSize(392, 490)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:SetBackdrop(DIALOG_BACKDROP)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()
tinsert(UISpecialFrames, "GamblerFrame") -- lets Escape close it

local header = frame:CreateTexture(nil, "ARTWORK")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetSize(300, 64)
header:SetPoint("TOP", 0, 12)

local title = makeText(frame, "GameFontNormal", "TOP", 0, -2)
title:SetText("Olympus Fight Club")

CreateFrame("Button", nil, frame, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -6, -6)

local statusText = makeText(frame, "GameFontHighlight", "TOP", 0, -30)
local bookieText = makeText(frame, "GameFontDisableSmall", "TOP", 0, -46)

local function makePanel()
    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", 16, -66)
    panel:SetPoint("TOPRIGHT", -16, -66)
    panel:SetHeight(270)
    return panel
end

local betPanel = makePanel()
local bookPanel = makePanel()

-- Activity feed

local feedBox = CreateFrame("Frame", nil, frame, BACKDROP_TEMPLATE)
feedBox:SetPoint("BOTTOMLEFT", 14, 14)
feedBox:SetPoint("BOTTOMRIGHT", -14, 14)
feedBox:SetHeight(120)
feedBox:SetBackdrop(TOOLTIP_BACKDROP)
feedBox:SetBackdropColor(0, 0, 0, 0.7)
feedBox:SetBackdropBorderColor(0.6, 0.6, 0.6)

local feed = CreateFrame("ScrollingMessageFrame", nil, feedBox)
feed:SetPoint("TOPLEFT", 8, -8)
feed:SetPoint("BOTTOMRIGHT", -8, 8)
feed:SetFontObject(GameFontHighlightSmall)
feed:SetJustifyH("LEFT")
feed:SetFading(false)
feed:SetMaxLines(cfg.feedLines)
feed:EnableMouseWheel(true)
feed:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then self:ScrollUp() else self:ScrollDown() end
end)

function ui.addToFeed(text)
    feed:AddMessage(date("|cff888888%H:%M|r  ") .. text)
end

-- Fighter icons: the round class icon from target frames, and a race badge

local ICON_SIZE = 22

local CLASS_TEXTURE = "Interface\\TargetingFrame\\UI-Classes-Circles"
local CLASS_COORDS = CLASS_ICON_TCOORDS or { -- the game's own table, or a copy for clients without it
    WARRIOR = { 0, 0.25, 0, 0.25 },
    MAGE = { 0.25, 0.49609375, 0, 0.25 },
    ROGUE = { 0.49609375, 0.7421875, 0, 0.25 },
    DRUID = { 0.7421875, 0.98828125, 0, 0.25 },
    HUNTER = { 0, 0.25, 0.25, 0.5 },
    SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
    PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 },
    WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
    PALADIN = { 0, 0.25, 0.5, 0.75 },
    DEATHKNIGHT = { 0.25, 0.5, 0.5, 0.75 },
}

-- Older clients keep race icons in one sheet; newer ones have an atlas per race
local RACE_TEXTURE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races"
local RACE_COORDS = {
    HUMAN_MALE = { 0, 0.125, 0, 0.25 },         HUMAN_FEMALE = { 0, 0.125, 0.5, 0.75 },
    DWARF_MALE = { 0.125, 0.25, 0, 0.25 },      DWARF_FEMALE = { 0.125, 0.25, 0.5, 0.75 },
    GNOME_MALE = { 0.25, 0.375, 0, 0.25 },      GNOME_FEMALE = { 0.25, 0.375, 0.5, 0.75 },
    NIGHTELF_MALE = { 0.375, 0.5, 0, 0.25 },    NIGHTELF_FEMALE = { 0.375, 0.5, 0.5, 0.75 },
    TAUREN_MALE = { 0, 0.125, 0.25, 0.5 },      TAUREN_FEMALE = { 0, 0.125, 0.75, 1 },
    SCOURGE_MALE = { 0.125, 0.25, 0.25, 0.5 },  SCOURGE_FEMALE = { 0.125, 0.25, 0.75, 1 },
    TROLL_MALE = { 0.25, 0.375, 0.25, 0.5 },    TROLL_FEMALE = { 0.25, 0.375, 0.75, 1 },
    ORC_MALE = { 0.375, 0.5, 0.25, 0.5 },       ORC_FEMALE = { 0.375, 0.5, 0.75, 1 },
    DRAENEI_MALE = { 0.5, 0.625, 0, 0.25 },     DRAENEI_FEMALE = { 0.5, 0.625, 0.5, 0.75 },
    BLOODELF_MALE = { 0.5, 0.625, 0.25, 0.5 },  BLOODELF_FEMALE = { 0.5, 0.625, 0.75, 1 },
}

local function atlasExists(name)
    return C_Texture ~= nil and C_Texture.GetAtlasInfo ~= nil and C_Texture.GetAtlasInfo(name) ~= nil
end

local function setClassIcon(icon, class)
    local coords = class and CLASS_COORDS[class]
    if not coords then return icon:Hide() end
    icon:SetTexture(CLASS_TEXTURE)
    icon:SetTexCoord(unpack(coords))
    icon:Show()
end

local function setRaceIcon(icon, look)
    if not look or not look.race then return icon:Hide() end
    local gender = look.sex == "f" and "female" or "male"

    -- Newer clients name undead "undead" in their atlas; the game's own race name is "Scourge"
    local race = look.race:lower():gsub("scourge", "undead")
    for _, atlas in ipairs({ ("raceicon128-%s-%s"):format(race, gender), ("raceicon-%s-%s"):format(race, gender) }) do
        if atlasExists(atlas) then
            icon:SetTexCoord(0, 1, 0, 1)
            icon:SetAtlas(atlas)
            return icon:Show()
        end
    end

    local coords = RACE_COORDS[look.race:upper() .. "_" .. gender:upper()]
    if not coords then return icon:Hide() end
    icon:SetTexture(RACE_TEXTURE)
    icon:SetTexCoord(unpack(coords))
    icon:Show()
end

-- Bet tab

local amountInput -- bet / deposit amount, created below

-- Red sits on the left edge, blue on the right; their width follows the window
local function makeCard(side, anchor)
    local r, g, b = unpack(SIDE_COLOR[side])

    local card = CreateFrame("Frame", nil, betPanel, BACKDROP_TEMPLATE)
    card:SetSize(150, 126)
    card:SetPoint(anchor, 0, 0)
    card:SetBackdrop(TOOLTIP_BACKDROP)
    card:SetBackdropColor(r * 0.3, g * 0.3, b * 0.3, 0.9)
    card:SetBackdropBorderColor(r, g, b)

    card.name = makeText(card, "GameFontNormalLarge", "TOP", 0, -12)
    card.name:SetTextColor(r, g, b)
    card.name:SetWidth(136)
    card.name:SetWordWrap(false) -- one line only, so it never spills onto the odds
    card.color = { r, g, b }

    -- Class icon top-left, race badge top-right, name between them
    card.classIcon = card:CreateTexture(nil, "ARTWORK")
    card.classIcon:SetSize(ICON_SIZE, ICON_SIZE)
    card.classIcon:SetPoint("TOPLEFT", 8, -8)
    card.classIcon:Hide()

    card.raceIcon = card:CreateTexture(nil, "ARTWORK")
    card.raceIcon:SetSize(ICON_SIZE, ICON_SIZE)
    card.raceIcon:SetPoint("TOPRIGHT", -8, -8)
    card.raceIcon:Hide()

    card.odds = makeText(card, "GameFontHighlightLarge", "TOP", 0, -34)
    card.pool = makeText(card, "GameFontHighlightSmall", "TOP", 0, -56)
    card.payout = makeText(card, "GameFontDisableSmall", "TOP", 0, -72)

    card.button = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    card.button:SetSize(130, 22)
    card.button:SetPoint("BOTTOM", 0, 10)
    card.button:SetScript("OnClick", function()
        MoneyInputFrame_ClearFocus(amountInput)
        bettor.placeBet(side, MoneyInputFrame_GetCopper(amountInput))
    end)

    return card
end

local cards = { red = makeCard("red", "TOPLEFT"), blue = makeCard("blue", "TOPRIGHT") }

local versus = makeText(betPanel, "GameFontNormalLarge", "TOP", 0, -52)
versus:SetText("VS")

-- Amount row
local amountLabel = makeText(betPanel, "GameFontNormal", "TOPLEFT", 2, -141)
amountLabel:SetText("Amount")

amountInput = makeMoneyInput(betPanel, "GamblerAmount", 66, -136)

-- Quick buttons: each adds to the amount. Spread evenly across the row by layout().
local quickButtons = {}

-- 50 -> "50c", 2500 -> "25s", 10000 -> "1g"
local function shortCoins(copper)
    if copper % COPPER_PER_GOLD == 0 then return (copper / COPPER_PER_GOLD) .. "g" end
    if copper % 100 == 0 then return (copper / 100) .. "s" end
    return copper .. "c"
end

local function addCopper(copper)
    MoneyInputFrame_SetCopper(amountInput, MoneyInputFrame_GetCopper(amountInput) + copper)
end

-- The most we can bet: our balance, capped by what's left of the fight's max bet
local function fillMax()
    local f, account = bettor.fight, bettor.account
    if not bettor.hasBookie() or not f then
        return util.log("There's no fight to bet on right now.")
    end
    if account.balance <= 0 then
        return util.log("Your balance is empty. Trade the bookie some gold first.")
    end

    local _, placed = bettor.myBet()
    local room = math.max(0, f.maxBet - (placed or 0))
    if room <= 0 then
        return util.log("You've already bet the most allowed on this fight.")
    end
    MoneyInputFrame_SetCopper(amountInput, math.min(account.balance, room))
end

for _, copper in ipairs(cfg.quickAmounts) do
    table.insert(quickButtons, makeButton(betPanel, "+" .. shortCoins(copper), 48, 0, -162, function() addCopper(copper) end))
end
table.insert(quickButtons, makeButton(betPanel, "Max", 48, 0, -162, fillMax))
table.insert(quickButtons, makeButton(betPanel, "Clear", 48, 0, -162, function()
    MoneyInputFrame_SetCopper(amountInput, 0)
end))

-- Your bet and balance
local yourBetText = makeText(betPanel, "GameFontHighlight", "TOPLEFT", 2, -192)
local balanceText = makeText(betPanel, "GameFontHighlight", "TOPLEFT", 2, -210)

local cashOutButton = makeButton(betPanel, "Cash Out", 328, 0, -230, function()
    local balance = bettor.account.balance
    confirm(("Cash out your %s? Trade the bookie to get it now, or they'll mail it to you."):format(money(balance)), bettor.cashOut)
end)
cashOutButton:SetPoint("TOPRIGHT", 0, -230) -- stretches across the panel

local hintText = makeText(betPanel, "GameFontDisableSmall", "TOPLEFT", 2, -258)
hintText:SetPoint("TOPRIGHT", 0, -258)
hintText:SetJustifyH("LEFT")

local function redrawCard(side, card, f, canBet, extra)
    local name = f and f[side] or "?"
    local pool = f and f.pool[side] or 0
    local count = f and f.count[side] or 0
    local odds = f and bettor.odds(side)

    card.name:SetText(name)
    local look = f and f.looks and f.looks[side]
    setClassIcon(card.classIcon, look and look.class)
    setRaceIcon(card.raceIcon, look)

    card.odds:SetText(odds and ("%.2fx"):format(odds) or "--")
    card.pool:SetText(("%s from %d bet%s"):format(money(pool), count, count == 1 and "" or "s"))
    card.payout:SetText(canBet and extra > 0 and ("%s would pay %s"):format(money(extra), money(bettor.previewPayout(side, extra))) or "")

    local mySide = bettor.myBet()
    card.button:SetText(mySide == side and "Add to Bet" or "Bet on " .. name)
    setEnabled(card.button, canBet and (not mySide or mySide == side))
end

local function redrawBetPanel()
    local live = bettor.hasBookie()
    local f = live and bettor.fight or nil
    local canBet = f ~= nil and f.status == "open" and not bettor.isBookie()
    local extra = MoneyInputFrame_GetCopper(amountInput)

    for side, card in pairs(cards) do
        redrawCard(side, card, f, canBet, extra)
    end

    local mySide, myAmount
    if f then
        mySide, myAmount = bettor.myBet()
    end
    if mySide then
        local payout = bettor.previewPayout(mySide, 0)
        yourBetText:SetText(("Your bet: |cffffffff%s|r on %s  (pays %s)"):format(money(myAmount), f[mySide], money(payout)))
    else
        yourBetText:SetText("|cff999999You haven't bet on this fight.|r")
    end

    local account = bettor.account
    local cashOut = account.cashOut > 0 and ("  |cff999999(%s cash-out waiting)|r"):format(money(account.cashOut)) or ""
    balanceText:SetText(("Balance: |cffffd100%s|r%s"):format(money(account.balance), cashOut))

    local canDeal = live and not bettor.isBookie()
    setEnabled(cashOutButton, canDeal and account.balance > 0)

    if bettor.isBookie() then
        hintText:SetText("You're running the book. Use the Bookie tab.")
    elseif live and not comms.channelConnected() then
        hintText:SetText("Not in the private channel, so updates come by whisper and may lag a little.")
    elseif live then
        hintText:SetText(("To deposit, trade gold to %s. It shows in your balance straight away."):format(bettor.bookie))
    else
        hintText:SetText("")
    end
end

-- Bookie tab

local function setFighterFromTarget(side)
    if not UnitIsPlayer("target") then
        return util.log("Target a player first.")
    end

    local _, class = UnitClass("target")
    local _, race = UnitRace("target")
    local look = { class = class, race = race, sex = UnitSex("target") == 3 and "f" or "m" }
    bookie.setFighter(side, util.unitName("target"), look)
end

local function confirmWinner(side)
    local f = bookie.fight()
    if f and f[side] then
        confirm(("Declare %s the winner and pay out?"):format(f[side]), function() bookie.declareWinner(side) end)
    end
end

makeHalfButton(bookPanel, "Red = Target", 1, 0, function() setFighterFromTarget("red") end)
makeHalfButton(bookPanel, "Blue = Target", 2, 0, function() setFighterFromTarget("blue") end)

local openButton = makeHalfButton(bookPanel, "Open Betting", 1, -26, function() bookie.open() end)
local closeButton = makeHalfButton(bookPanel, "Close Betting", 2, -26, function() bookie.close() end)

local redWinsButton = makeHalfButton(bookPanel, "Red Wins", 1, -52, function() confirmWinner("red") end)
local blueWinsButton = makeHalfButton(bookPanel, "Blue Wins", 2, -52, function() confirmWinner("blue") end)

makeHalfButton(bookPanel, "New Fight", 1, -78, function() bookie.newFight(nil, nil) end)
local cancelButton = makeHalfButton(bookPanel, "Call Off & Refund", 2, -78, function()
    confirm("Call off this fight and refund every bet?", bookie.cancel)
end)

-- Settings
local moneySettings = {}      -- key -> money input
local numberSettings = {}     -- key -> number box
local loadingSettings = false -- true while filling inputs, so saves are skipped

-- Fills the money inputs from saved values, except `skip`
local function refreshSettings(skip)
    loadingSettings = true
    for key, input in pairs(moneySettings) do
        if input ~= skip then
            MoneyInputFrame_SetCopper(input, ns.db[key])
        end
    end
    loadingSettings = false
end

local function addMoneySetting(key, label, y)
    makeText(bookPanel, "GameFontNormalSmall", "TOPLEFT", 2, y - 5):SetText(label)

    local input = makeMoneyInput(bookPanel, "Gambler" .. key, 60, y)
    MoneyInputFrame_SetOnValueChangedFunc(input, function()
        if loadingSettings then return end
        bookie.setSetting(key, MoneyInputFrame_GetCopper(input))
        refreshSettings(input) -- min/max may have nudged each other
    end)
    moneySettings[key] = input
end

-- Pinned to the right edge, clear of the money inputs on the left
local function addNumberSetting(key, label, y)
    makeText(bookPanel, "GameFontNormalSmall", "TOPRIGHT", -52, y - 5):SetText(label)

    local box = makeNumberBox(bookPanel, 40, 0, y)
    box:ClearAllPoints()
    box:SetPoint("TOPRIGHT", -2, y)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEditFocusLost", function(self)
        self.editing = false
        bookie.setSetting(key, self:GetNumber())
    end)
    numberSettings[key] = box
end

addMoneySetting("minBet", "Min bet", -106)
addMoneySetting("maxBet", "Max bet", -130)
addNumberSetting("cut", "Cut %", -106)
addNumberSetting("window", "Timer", -130)

bookPanel:SetScript("OnShow", function() refreshSettings() end)

local infoText = makeText(bookPanel, "GameFontHighlightSmall", "TOPLEFT", 2, -160)
infoText:SetPoint("TOPRIGHT", 0, -160)
infoText:SetJustifyH("LEFT")
infoText:SetSpacing(3)

local modeButton = makeHalfButton(bookPanel, "Start Booking", 1, -246, function() bookie.toggleMode() end)
local cashOutsButton = makeHalfButton(bookPanel, "Cash-outs", 2, -246, function() ui.toggleCashOuts() end)

local function redrawBookPanel()
    local db, f = ns.db, bookie.fight()
    local active = bookie.isActive()
    local redName = f and f.red or "Red"
    local blueName = f and f.blue or "Blue"
    -- Winner buttons stay locked while betting is open
    local canCallWinner = active and f and f.openedAt and not f.open and not f.settled

    redWinsButton:SetText(redName .. " Wins")
    blueWinsButton:SetText(blueName .. " Wins")
    openButton:SetText(("Open Betting (%ds)"):format(db.window))

    setEnabled(openButton, active and f and f.red and f.blue and not f.openedAt)
    setEnabled(closeButton, active and f and f.open)
    setEnabled(redWinsButton, canCallWinner)
    setEnabled(blueWinsButton, canCallWinner)
    setEnabled(cancelButton, active and f and not f.settled)

    for key, box in pairs(numberSettings) do
        if not box.editing then
            box:SetNumber(db[key])
        end
    end

    local pool, count = bookie.pools()
    infoText:SetText(table.concat({
        ("Bets this fight: |cffffffff%d|r   Pot: |cffffffff%s|r"):format(count.red + count.blue, money(pool.red + pool.blue)),
        ("Holding for players: |cffffffff%s|r"):format(money(bookie.heldForPlayers())),
        ("Your gold: |cffffffff%s|r"):format(money(GetMoney())),
        ("House profit: |cffffffff%s|r over %d fights"):format(money(db.profit), db.fights),
        ("Cash-outs waiting: |cffffffff%d|r (%s)"):format(#db.outbox, money(ns.mail.outboxTotal())),
        ("Messages queued: |cffffffff%d|r   Private channel: %s"):format(comms.backlog(),
            comms.channelConnected() and "|cff55ff55connected|r" or "|cffff5555not connected|r"),
    }, "\n"))

    modeButton:SetText(db.bookieMode and "Stop Booking" or "Start Booking")
    cashOutsButton:SetText(("Cash-outs (%d)"):format(#db.outbox))
end

-- Tabs

local tabs = {}

local function showTab(id)
    PanelTemplates_SetTab(frame, id)
    setShown(betPanel, id == 1)
    setShown(bookPanel, id == 2)
end

-- Tab template name depends on the client version
local TAB_TEMPLATES = { "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate" }

local function makeTab(name)
    for _, template in ipairs(TAB_TEMPLATES) do
        local ok, tab = pcall(CreateFrame, "Button", name, frame, template)
        if ok then return tab end
    end
end

for i, label in ipairs({ "Bet", "Bookie" }) do
    local tab = makeTab("GamblerFrameTab" .. i)
    tab:SetID(i)
    tab:SetText(label)
    tab:SetScript("OnClick", function() showTab(i) end)
    PanelTemplates_TabResize(tab, 0)
    tabs[i] = tab
end

tabs[1]:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 8)
tabs[2]:SetPoint("LEFT", tabs[1], "RIGHT", -16, 0)
frame.Tabs = tabs -- newer clients look for tabs here
PanelTemplates_SetNumTabs(frame, #tabs)
showTab(1)

-- Window width: grows so long names and messages always fit

local MIN_PANEL = 360 -- panel width at the window's smallest (leaves room beside the money inputs)
local MAX_PANEL = 640 -- widest the panel gets
local CARD_GAP = 28   -- room for "VS" between the cards
local CARD_PADDING = 24
local ICON_ROOM = ICON_SIZE + 8 -- space taken by each corner icon beside the name

local function layout()
    local card = 0
    for _, c in pairs(cards) do
        card = math.max(card,
            textWidth(GameFontNormalLarge, c.name:GetText()) + ICON_ROOM * 2,
            textWidth(GameFontHighlightSmall, c.pool:GetText()),
            textWidth(GameFontDisableSmall, c.payout:GetText()),
            textWidth(GameFontNormal, c.button:GetText()) + BUTTON_PADDING)
    end

    local half = 0
    for _, button in ipairs(halfButtons) do
        half = math.max(half, textWidth(GameFontNormal, button:GetText()) + BUTTON_PADDING)
    end

    local width = math.max(MIN_PANEL,
        (card + CARD_PADDING) * 2 + CARD_GAP,
        half * 2 + 8,
        textWidth(GameFontHighlight, statusText:GetText()),
        textWidth(GameFontHighlight, yourBetText:GetText()),
        textWidth(GameFontHighlight, balanceText:GetText()))
    width = math.min(math.ceil(width), MAX_PANEL)

    local cardWidth = (width - CARD_GAP) / 2
    for _, c in pairs(cards) do
        c:SetWidth(cardWidth)
        c.button:SetWidth(cardWidth - 20)

        -- A name too long even for the widest window drops to a smaller font instead of spilling over
        local nameWidth = cardWidth - 14 - ICON_ROOM * 2
        local fits = textWidth(GameFontNormalLarge, c.name:GetText()) <= nameWidth
        c.name:SetWidth(nameWidth)
        c.name:SetFontObject(fits and GameFontNormalLarge or GameFontNormal)
        c.name:SetTextColor(unpack(c.color)) -- changing the font resets the colour
    end
    for _, button in ipairs(halfButtons) do
        button:SetWidth((width - 8) / 2)
    end

    -- Quick amount buttons share the row evenly
    local gap = 4
    local quickWidth = (width - gap * (#quickButtons - 1)) / #quickButtons
    for i, button in ipairs(quickButtons) do
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", (i - 1) * (quickWidth + gap), -162)
        button:SetWidth(quickWidth)
    end

    frame:SetWidth(width + 32)
end

-- Redraw, four times a second while open

local function redraw()
    local isBookie = comms.canRunBook(util.me())
    setShown(tabs[2], isBookie)
    if not isBookie and frame.selectedTab == 2 then
        showTab(1)
    end

    statusText:SetText(bettor.statusText())
    if bettor.isBookie() then
        bookieText:SetText("You're running the book")
    elseif bettor.hasBookie() then
        bookieText:SetText("Bookie: " .. bettor.bookie)
    else
        bookieText:SetText("")
    end

    if frame.selectedTab == 2 then
        redrawBookPanel()
    else
        redrawBetPanel()
    end
    layout()
end

local sinceRedraw = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    sinceRedraw = sinceRedraw + elapsed
    if sinceRedraw >= 0.25 then
        sinceRedraw = 0
        redraw()
    end
end)

frame:SetScript("OnShow", function()
    bettor.sync()
    redraw()
end)

function ui.show()
    frame:Show()
end

function ui.toggle()
    setShown(frame, not frame:IsShown())
end

-- Cash-outs window (bookie): everyone waiting to be paid, one click fills in the mail

local CASH_ROWS = 10 -- rows per page

local cashFrame = CreateFrame("Frame", "GamblerCashOutFrame", UIParent, BACKDROP_TEMPLATE)
cashFrame:SetSize(300, 380)
cashFrame:SetPoint("CENTER", 360, 0)
cashFrame:SetFrameStrata("DIALOG")
cashFrame:SetBackdrop(DIALOG_BACKDROP)
cashFrame:SetMovable(true)
cashFrame:EnableMouse(true)
cashFrame:SetClampedToScreen(true)
cashFrame:RegisterForDrag("LeftButton")
cashFrame:SetScript("OnDragStart", cashFrame.StartMoving)
cashFrame:SetScript("OnDragStop", cashFrame.StopMovingOrSizing)
cashFrame:Hide()
tinsert(UISpecialFrames, "GamblerCashOutFrame")

local cashHeader = cashFrame:CreateTexture(nil, "ARTWORK")
cashHeader:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
cashHeader:SetSize(240, 64)
cashHeader:SetPoint("TOP", 0, 12)
makeText(cashFrame, "GameFontNormal", "TOP", 0, -2):SetText("Cash-outs")

CreateFrame("Button", nil, cashFrame, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -6, -6)

local cashSummary = makeText(cashFrame, "GameFontHighlight", "TOP", 0, -30)

local cashStatus = makeText(cashFrame, "GameFontNormalSmall", "TOPLEFT", 18, -50)
cashStatus:SetPoint("TOPRIGHT", -18, -50)
cashStatus:SetHeight(28)
cashStatus:SetJustifyV("TOP")

local cashRows = {}
for i = 1, CASH_ROWS do
    local row = CreateFrame("Frame", nil, cashFrame)
    row:SetHeight(22)
    row:SetPoint("TOPLEFT", 16, -84 - (i - 1) * 24)
    row:SetPoint("TOPRIGHT", -16, -84 - (i - 1) * 24)

    row.name = makeText(row, "GameFontHighlight", "LEFT", 4, 0)
    row.name:SetWidth(120)
    row.name:SetJustifyH("LEFT")

    row.amount = makeText(row, "GameFontNormal", "LEFT", 128, 0)

    row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.button:SetSize(70, 20)
    row.button:SetPoint("RIGHT")
    row.button:SetScript("OnClick", function()
        if row.item then ns.mail.startCashOut(row.item) end
    end)

    cashRows[i] = row
end

local cashPage = 1
local cashPageText = makeText(cashFrame, "GameFontHighlightSmall", "BOTTOM", 0, 24)
local prevPage = makeButton(cashFrame, "<", 30, 20, -340, function() cashPage = cashPage - 1 end)
local nextPage = makeButton(cashFrame, ">", 30, 250, -340, function() cashPage = cashPage + 1 end)
nextPage:ClearAllPoints()
nextPage:SetPoint("TOPRIGHT", -20, -340)

-- Grows the window to fit the longest name and amount on the page
local function layoutCashOuts()
    local nameWidth, amountWidth = 110, 60
    for _, row in ipairs(cashRows) do
        if row.item then
            nameWidth = math.max(nameWidth, textWidth(GameFontHighlight, row.name:GetText()))
            amountWidth = math.max(amountWidth, textWidth(GameFontNormal, row.amount:GetText()))
        end
    end

    for _, row in ipairs(cashRows) do
        row.name:SetWidth(nameWidth + 4)
        row.amount:ClearAllPoints()
        row.amount:SetPoint("LEFT", nameWidth + 16, 0)
    end

    local width = math.max(300,
        32 + nameWidth + 16 + amountWidth + 12 + 70,
        textWidth(GameFontHighlight, cashSummary:GetText()) + 40)
    cashFrame:SetWidth(math.min(math.ceil(width), 600))
end

local function redrawCashOuts()
    local outbox = ns.db.outbox
    local mailboxOpen = ns.mail.isOpen()
    local sendingItem = ns.mail.sendingItem()
    local pages = math.max(1, math.ceil(#outbox / CASH_ROWS))
    cashPage = math.max(1, math.min(cashPage, pages))

    cashSummary:SetText(("%d waiting  -  %s total"):format(#outbox, money(ns.mail.outboxTotal())))

    if #outbox == 0 then
        cashStatus:SetText("Nobody is waiting for a cash-out.")
    elseif not mailboxOpen then
        cashStatus:SetText("Open a mailbox to mail these. Players can also trade you for theirs.")
    else
        cashStatus:SetText(ns.mail.status())
    end

    for i, row in ipairs(cashRows) do
        local item = outbox[(cashPage - 1) * CASH_ROWS + i]
        row.item = item
        if item then
            row.name:SetText(item.name)
            row.amount:SetText(money(item.amount))
            row.button:SetText(item == sendingItem and "Filled in" or "Mail")
            setEnabled(row.button, mailboxOpen and item ~= sendingItem)
            row:Show()
        else
            row:Hide()
        end
    end

    cashPageText:SetText(pages > 1 and ("Page %d of %d"):format(cashPage, pages) or "")
    setShown(prevPage, pages > 1)
    setShown(nextPage, pages > 1)
    setEnabled(prevPage, cashPage > 1)
    setEnabled(nextPage, cashPage < pages)
    layoutCashOuts()
end

local sinceCashRedraw = 0
cashFrame:SetScript("OnUpdate", function(_, elapsed)
    sinceCashRedraw = sinceCashRedraw + elapsed
    if sinceCashRedraw >= 0.25 then
        sinceCashRedraw = 0
        redrawCashOuts()
    end
end)
cashFrame:SetScript("OnShow", redrawCashOuts)

function ui.showCashOuts()
    cashFrame:Show()
end

function ui.toggleCashOuts()
    setShown(cashFrame, not cashFrame:IsShown())
end

ui.addToFeed("Welcome! Trade the bookie some gold, pick a fighter, choose an amount and hit Bet.")

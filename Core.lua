local ADDON_NAME, ns = ...
local cfg, util, comms, bookie, mail = ns.config, ns.util, ns.comms, ns.bookie, ns.mail
local COPPER_PER_GOLD = util.COPPER_PER_GOLD

-- Saved data

local function fillDefaults(db)
    for key, value in pairs(ns.defaults) do
        if db[key] == nil then
            db[key] = type(value) == "table" and {} or value
        end
    end
end

-- Upgrades old saves; anything owed or still bet goes back into balances
local function upgrade(db)
    if db.version == 8 then return end

    if (db.version or 0) < 6 then
        for player, gold in pairs(db.owed or {}) do
            bookie.credit(player, gold * COPPER_PER_GOLD)
        end
        for _, entry in ipairs(db.cashout or {}) do
            mail.queueCashOut(entry.name, entry.amount)
        end

        -- v1/v2 already paid finished fights, so only refund unfinished ones
        local f = db.fight
        local alreadyPaid = f and f.winner and not db.version
        if f and not f.settled and not alreadyPaid then
            for player, bet in pairs(f.bets or {}) do
                bookie.credit(player, bet.amount or (bet.gold or 0) * COPPER_PER_GOLD)
            end
        end

        -- v1 stored profit in gold
        if not db.version and not db.copper then
            db.profit = db.profit * COPPER_PER_GOLD
        end

        -- Bet limits were in gold
        if db.min then db.minBet = db.min end
        if db.max then db.maxBet = db.max end
        db.minBet = db.minBet * COPPER_PER_GOLD
        db.maxBet = db.maxBet * COPPER_PER_GOLD

        for name, record in pairs(db.record) do
            if record.w then
                db.record[name] = { wins = record.w, losses = record.l }
            end
        end
        db.fight, db.owed, db.cashout, db.pending, db.copper, db.min, db.max, db.channel = nil
    end

    -- v7: cash-outs are mailed by hand from the Cash-outs window; failed ones go back in the queue
    for _, item in ipairs(db.failed or {}) do
        mail.queueCashOut(item.name, item.amount)
    end
    db.failed, db.autoMail, db.handSend = nil, nil, nil

    -- v8: new defaults (min 50c, max 10g, 5% cut), only where the old defaults were never changed
    if (db.version or 0) < 8 then
        if db.minBet == 1 then db.minBet = 50 end
        if db.maxBet == 100000000 then db.maxBet = 100000 end
        if db.cut == 10 then db.cut = 5 end
    end

    db.version = 8
end

-- Events

local handlers = {
    CHAT_MSG_ADDON = comms.onMessage,
    CHAT_MSG_CHANNEL = comms.onChannelMessage,
    GUILD_ROSTER_UPDATE = ns.guild.onRosterUpdate,
    CHAT_MSG_SYSTEM = bookie.onSystemMessage,
    MAIL_SHOW = mail.onShow,
    MAIL_CLOSED = mail.onClose,
    MAIL_SEND_SUCCESS = mail.onSendSuccess,
    MAIL_FAILED = mail.onSendFailed,
    TRADE_SHOW = bookie.onTradeShow,
    TRADE_MONEY_CHANGED = bookie.onTradeMoneyChanged,
    TRADE_ACCEPT_UPDATE = bookie.onTradeMoneyChanged,
    UI_INFO_MESSAGE = bookie.onInfoMessage,
}

-- Events handled even outside Olympus
local ALWAYS = { MAIL_CLOSED = true, GUILD_ROSTER_UPDATE = true }

local events = CreateFrame("Frame")

events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        if not GamblerDB then
            GamblerDB = { version = 8 } -- fresh install, nothing to upgrade
        end
        ns.db = GamblerDB
        fillDefaults(ns.db)
        upgrade(ns.db)
        ns.guild.prune() -- drop expired guild confirmations from the saved file
        ns.minimap.restore()
        return
    end

    if ALWAYS[event] or util.isOlympusMember() then
        handlers[event](...)
    end
end)

events:RegisterEvent("ADDON_LOADED")
for event in pairs(handlers) do
    events:RegisterEvent(event)
end

-- Heartbeat: messages, betting timer and mailbox

local sinceMessage, sinceTick = 0, 0

local heartbeat = CreateFrame("Frame")
heartbeat:SetScript("OnUpdate", function(_, elapsed)
    if not ns.db or not util.isOlympusMember() then return end

    sinceMessage = sinceMessage + elapsed
    if sinceMessage >= cfg.messageInterval then
        sinceMessage = 0
        comms.sendNext()
    end

    sinceTick = sinceTick + elapsed
    if sinceTick >= cfg.tickInterval then
        sinceTick = 0
        comms.joinChannel()
        ns.guild.tick()
        bookie.tick()
        ns.bettor.tick()
        mail.step()
    end
end)

-- Slash commands

SLASH_GAMBLER1, SLASH_GAMBLER2 = "/fc", "/fightclub"

-- Prints what the addon sees, and logs every message in the window's feed until turned off
local function toggleDebug()
    ns.debugMode = not ns.debugMode
    local name, second = UnitName("player")

    util.print("Debug is %s. Messages are logged in the window's feed.", ns.debugMode and "ON" or "OFF")
    util.print("Your name: \"%s\" (the game gives \"%s\" + \"%s\")", tostring(util.me()), tostring(name), tostring(second))
    util.print("Guild: \"%s\" - %s", tostring(GetGuildInfo("player")),
        util.isOlympusMember() and "counts as Olympus" or "does NOT count as Olympus")
    util.print("Private channel: %s", comms.channelConnected() and "connected" or "NOT connected")
    util.print("Trusted list: %s", comms.trustedListText())
    util.print("You can run the book: %s", comms.canRunBook(util.me()) and "yes" or "no")
    util.print("Following bookie: \"%s\" (last: \"%s\")", tostring(ns.bettor.bookie), tostring(ns.db.lastBookie))
end

SlashCmdList.GAMBLER = function(input)
    local command, player, amount = input:match("^(%S*)%s*(%S*)%s*(%S*)")
    command = command:lower()

    if command == "debug" then
        return toggleDebug()
    end

    if not util.isOlympusMember() then
        return util.print("This addon is only for members of the Olympus guild.")
    end

    -- Manual balance fix, e.g. "/fc credit Thrall 500" or "-500"
    if command == "credit" then
        if not bookie.isActive() then
            return util.print("You need to be running the book to change balances.")
        end
        local gold = tonumber(amount)
        if player == "" or not gold then
            return util.print("Usage: /fc credit <player> <gold>")
        end
        player = util.clean(player)
        bookie.credit(player, math.floor(gold * COPPER_PER_GOLD))
        return util.log("%s's balance is now %s.", player, util.money(bookie.balance(player)))
    end

    ns.ui.toggle()
end

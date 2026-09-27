local _, ns = ...
local cfg, util, comms = ns.config, ns.util, ns.comms
local money, log, otherSide = util.money, util.log, util.otherSide

-- The bookie holds every balance and bet
local bookie = {}
ns.bookie = bookie

local stateChanged = true -- fight state needs sending
local lastBroadcast = -math.huge
local lastRequest = {} -- player -> time of their last request
local notes = {}       -- player -> short note to include in their next update

function bookie.isActive()
    return ns.db ~= nil and ns.db.bookieMode and comms.canRunBook(util.me())
end

function bookie.fight()
    return ns.db and ns.db.fight
end

local function changed()
    stateChanged = true
end

-- Balances

function bookie.balance(player)
    return ns.db.balance[player] or 0
end

function bookie.credit(player, copper)
    local total = bookie.balance(player) + copper
    ns.db.balance[player] = total > 0 and total or nil
end

function bookie.pools()
    local gold = { red = 0, blue = 0 }
    local count = { red = 0, blue = 0 }

    local f = bookie.fight()
    if f then
        for _, bet in pairs(f.bets) do
            gold[bet.side] = gold[bet.side] + bet.amount
            count[bet.side] = count[bet.side] + 1
        end
    end
    return gold, count
end

-- All gold held for players: balances, open bets and queued cash-outs
function bookie.heldForPlayers()
    local total = 0
    for _, copper in pairs(ns.db.balance) do
        total = total + copper
    end

    local f = bookie.fight()
    if f and not f.settled then
        local pool = bookie.pools()
        total = total + pool.red + pool.blue
    end
    return total + ns.mail.outboxTotal()
end

-- Keeping bettors up to date

local function pendingCashOut(player)
    return ns.mail.owedTo(player)
end

-- Queues an account update for one player (built at send time)
local function updatePlayer(player, note, urgent)
    if note then
        notes[player] = note
    end

    comms.send("WHISPER", player, function()
        local f = bookie.fight()
        local bet = f and f.bets[player]
        local message = comms.encode("ACCOUNT",
            bookie.balance(player),
            f and f.id or 0,
            bet and bet.side,
            bet and bet.amount or 0,
            pendingCashOut(player),
            notes[player])
        notes[player] = nil
        return message
    end, "account:" .. player, urgent)
end

local function fightStatus(f)
    if not f then return "none" end
    if f.cancelled then return "cancelled" end
    if f.winner then return "won" end
    if f.open then return "open" end
    if f.openedAt then return "closed" end
    return "ready"
end

local function stateMessage()
    local f, db = bookie.fight(), ns.db
    local pool, count = bookie.pools()
    local closesIn = f and f.open and f.closesAt and math.max(1, f.closesAt - time()) or 0

    -- Class, race and gender for each fighter's card icons
    local red = f and f.redLook or {}
    local blue = f and f.blueLook or {}

    return comms.encode("STATE",
        f and f.id or 0, fightStatus(f),
        f and f.red, f and f.blue, closesIn,
        pool.red, pool.blue, count.red, count.blue,
        db.cut, db.minBet, db.maxBet,
        f and f.winner,
        red.class, red.race, red.sex, blue.class, blue.race, blue.sex)
end

-- Players whose private channel isn't working get fight updates by whisper instead
local DIRECT_FOR = 300 -- seconds a whisper subscription lasts without them checking in
local direct = {}      -- player -> when they last checked in

local function sendStateTo(player)
    comms.send("WHISPER", player, stateMessage, "state:" .. player)
end

local function sendStateToDirect()
    for player, since in pairs(direct) do
        if GetTime() - since > DIRECT_FOR then
            direct[player] = nil
        else
            sendStateTo(player)
        end
    end
end

-- Running a fight

function bookie.newFight(red, blue)
    local f, db = bookie.fight(), ns.db
    if f and not f.settled and (f.open or next(f.bets)) then
        log("Finish or cancel the current fight first.")
        return false
    end

    db.fight = { id = db.nextFightId, red = red, blue = blue, bets = {} }
    db.nextFightId = db.nextFightId + 1
    changed()
    return true
end

-- look (optional): { class = "WARRIOR", race = "Human", sex = "m" or "f" }, shown as card icons
function bookie.setFighter(side, name, look)
    local f = bookie.fight()
    if not f or f.openedAt then
        if not bookie.newFight(nil, nil) then return end
        f = bookie.fight()
    end

    local function tidy(value) -- letters only, so it can't break a message
        return value and (tostring(value):gsub("[^%a]", "")) or nil
    end

    f[side] = util.clean(name)
    f[side .. "Look"] = look and { class = tidy(look.class), race = tidy(look.race), sex = tidy(look.sex) } or nil
    changed()
end

function bookie.open(seconds)
    local f = bookie.fight()
    if not f or not f.red or not f.blue then
        return log("Pick both fighters first.")
    end
    if f.openedAt then
        return log("Betting already ran for this fight. Start a new one.")
    end

    seconds = seconds or ns.db.window
    f.open = true
    f.openedAt = time()
    f.closesAt = seconds > 0 and f.openedAt + seconds or nil
    log("Betting open: %s vs %s.", f.red, f.blue)
    changed()
end

function bookie.close()
    local f = bookie.fight()
    if not f or not f.open then return end

    f.open = false
    local _, count = bookie.pools()
    log("Betting closed with %d bets.", count.red + count.blue)
    changed()
end

local function addToRecord(name, key)
    local record = ns.db.record[name] or { wins = 0, losses = 0 }
    record[key] = record[key] + 1
    ns.db.record[name] = record
end

local function payOut(f)
    f.settled = true

    local pool = bookie.pools()
    local pot = pool.red + pool.blue
    local winPool = f.winner and pool[f.winner] or 0
    local losePool = f.winner and pool[otherSide(f.winner)] or 0
    local refundAll = f.cancelled or winPool == 0 or losePool == 0
    local paidOut = 0

    for player, bet in pairs(f.bets) do
        local payout = 0
        if refundAll then
            payout = bet.amount
        elseif bet.side == f.winner then
            payout = util.payout(bet.amount, winPool, losePool, ns.db.cut)
        end

        if payout > 0 then
            bookie.credit(player, payout)
            paidOut = paidOut + payout
        end
        updatePlayer(player)
    end

    local houseTake = pot - paidOut
    ns.db.profit = ns.db.profit + houseTake

    if refundAll then
        log("Every bet was refunded.")
    else
        log("Paid %s to the winners. House took %s.", money(paidOut), money(houseTake))
    end
    changed()
end

function bookie.declareWinner(side)
    local f = bookie.fight()
    if not f or not f.openedAt or f.settled or not f[side] then return end

    -- Betting still open means people could bet mid-fight, so refund everyone
    if f.open then
        f.open = false
        f.cancelled = true
        log("The fight ended while betting was still open, so it's been called off. Close betting before the duel!")
        return payOut(f)
    end

    f.winner = side
    ns.db.fights = ns.db.fights + 1
    addToRecord(f[side], "wins")
    addToRecord(f[otherSide(side)], "losses")
    log("%s beat %s.", f[side], f[otherSide(side)])
    payOut(f)
end

function bookie.cancel()
    local f = bookie.fight()
    if not f or f.settled then return end

    if not f.openedAt then
        ns.db.fight = nil
        return changed()
    end

    f.open = false
    f.cancelled = true
    log("Fight cancelled.")
    payOut(f)
end

-- Deposits (mail or trade)

function bookie.deposit(player, copper, how)
    bookie.credit(player, copper)
    log("%s deposited %s by %s.", player, money(copper), how)
    updatePlayer(player, "deposit:" .. copper, true)
    sendStateTo(player) -- so they know who their bookie is, even without the channel
end

-- A cash-out was mailed from the Cash-outs window
function bookie.cashOutPaid(player)
    updatePlayer(player, nil, true)
end

-- Trades: gold in is a deposit, gold out pays a waiting cash-out

local trade = {} -- current trade: partner, gold received and given

-- The game doesn't let addons touch the trade window's gold, so we tell the bookie what to put in
function bookie.onTradeShow()
    local partner = util.unitName("NPC")
    trade = { partner = partner, received = 0, given = 0 }

    local owed = partner and pendingCashOut(partner) or 0
    if bookie.isActive() and owed > 0 then
        log("|cffffcc00%s is owed %s. Put it in the trade and click Trade.|r", partner, money(owed))
    end
end

function bookie.onTradeMoneyChanged()
    if trade.partner then
        trade.received = GetTargetTradeMoney()
        trade.given = GetPlayerTradeMoney()
    end
end

function bookie.onInfoMessage(first, second)
    local completed = first == ERR_TRADE_COMPLETE or second == ERR_TRADE_COMPLETE
    if not completed then return end

    local partner = trade.partner
    if bookie.isActive() and partner then
        if trade.received > 0 then
            bookie.deposit(partner, trade.received, "trade")
        end
        if trade.given > 0 then
            ns.mail.paidOutside(partner, trade.given)
            log("Paid %s %s by trade.", partner, money(trade.given))
            updatePlayer(partner, nil, true)
        end
    end
    trade = {}
end

-- Requests from bettors

-- Rate-limited, never from ourselves
local function acceptRequest(player, channel)
    if not bookie.isActive() or channel ~= "WHISPER" then return false end
    if player == util.me() then return false end

    local now = GetTime()
    if lastRequest[player] and now - lastRequest[player] < cfg.requestCooldown then return false end
    lastRequest[player] = now
    return true
end

-- Returns a note code that the bettor turns into a message
local function placeBet(player, fightId, side, copper)
    local f, db = bookie.fight(), ns.db

    if not f or f.id ~= fightId or not f.open then return "closed" end
    if side ~= "red" and side ~= "blue" then return "invalid" end
    if not copper or copper ~= math.floor(copper) or copper <= 0 then return "invalid" end

    local bet = f.bets[player]
    if bet and bet.side ~= side then return "otherside" end

    local total = (bet and bet.amount or 0) + copper
    if total < db.minBet or total > db.maxBet then return "limits" end
    if bookie.balance(player) < copper then return "nofunds" end

    bookie.credit(player, -copper)
    f.bets[player] = { side = side, amount = total }
    changed()
    return "placed"
end

-- Only Olympus guild members can bet. Anyone can still cash out gold they sent us.
comms.on("BET", function(player, channel, parts)
    if not acceptRequest(player, channel) then return end

    ns.guild.verify(player, function(isOlympus)
        if not isOlympus then
            return updatePlayer(player, "guild", true)
        end
        updatePlayer(player, placeBet(player, tonumber(parts[1]), parts[2], tonumber(parts[3])), true)
    end)
end)

comms.on("CASHOUT", function(player, channel)
    if not acceptRequest(player, channel) then return end

    local amount = bookie.balance(player)
    if amount <= cfg.postage then
        return updatePlayer(player, "empty", true)
    end

    ns.db.balance[player] = nil
    ns.mail.queueCashOut(player, amount)
    log("%s cashed out %s.", player, money(amount))
    updatePlayer(player, "cashout", true)
end)

-- Also starts the guild check early, so their first bet goes through quickly.
-- "direct" means their private channel isn't working, so they want updates by whisper.
comms.on("SYNC", function(player, channel, parts)
    if not acceptRequest(player, channel) then return end

    updatePlayer(player, nil, true)
    ns.guild.verify(player, function() end)

    if parts[1] == "direct" then
        direct[player] = GetTime()
        sendStateTo(player)
    end
end)

-- Settings

local LIMITS = { -- setting -> { min, max }
    cut = { 0, 100 },
    minBet = { 1, 10000000000 },
    maxBet = { 1, 10000000000 },
    window = { 0, 3600 },
}

function bookie.setSetting(key, value)
    local limit = LIMITS[key]
    value = tonumber(value)
    if not limit or not value then return end

    ns.db[key] = math.max(limit[1], math.min(limit[2], math.floor(value)))
    if ns.db.minBet > ns.db.maxBet then
        ns.db.maxBet = ns.db.minBet
    end
    changed()
end

function bookie.toggleMode()
    if not comms.canRunBook(util.me()) then
        return log("Only bookies on the trusted list can run the book.")
    end

    if ns.db.bookieMode then
        local f = bookie.fight()
        if f and not f.settled and next(f.bets) then
            return log("Finish or call off the current fight before you stop.")
        end
        ns.db.bookieMode = false
        comms.broadcast("BYE")
        return log("You've stopped running the book.")
    end

    -- One book at a time
    local current = ns.bettor.bookie
    if ns.bettor.hasBookie() and current ~= util.me() then
        return log("%s is already running the book. They need to stop first.", current)
    end

    ns.db.bookieMode = true
    log("You're now running the book.")
    changed()
end

-- Duel detection

-- "%1$s has defeated %2$s" -> Lua pattern, plus which capture is which name
local function toLuaPattern(message)
    local order = {}
    message = message:gsub("%%(%d)%$s", function(i)
        order[#order + 1] = tonumber(i)
        return "\001"
    end)
    message = message:gsub("%%s", function()
        order[#order + 1] = #order + 1
        return "\001"
    end)
    message = message:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    return "^" .. message:gsub("\001", "(.+)") .. "$", order
end

local duelMessages = {}
for _, message in ipairs({ DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT }) do
    if message then
        local pattern, order = toLuaPattern(message)
        table.insert(duelMessages, { pattern = pattern, order = order })
    end
end

local function sideOf(name)
    local f = bookie.fight()
    if f.red == name then return "red" end
    if f.blue == name then return "blue" end
end

function bookie.onSystemMessage(text)
    local f = bookie.fight()
    if not bookie.isActive() or not f or not f.openedAt or f.settled then return end

    for _, duel in ipairs(duelMessages) do
        local captures = { text:match(duel.pattern) }
        if captures[1] then
            local names = {}
            for i, slot in ipairs(duel.order) do
                names[slot] = util.normalName(captures[i])
            end

            local winner, loser = sideOf(names[1]), sideOf(names[2])
            if winner and loser and winner ~= loser then
                bookie.declareWinner(winner)
            end
            return
        end
    end
end

-- Called twice a second

function bookie.tick()
    if not bookie.isActive() then return end

    local f = bookie.fight()
    if f and f.open and f.closesAt and time() >= f.closesAt then
        bookie.close()
    end

    local now = GetTime()
    local due = (stateChanged and now - lastBroadcast >= cfg.stateInterval) or now - lastBroadcast >= cfg.heartbeat
    if due then
        stateChanged = false
        lastBroadcast = now
        comms.broadcast(stateMessage, "state")
        sendStateToDirect()
    end
end

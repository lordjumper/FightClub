local _, ns = ...
local cfg, util, comms = ns.config, ns.util, ns.comms
local money, log, otherSide = util.money, util.log, util.otherSide

-- The bettor side: what the bookie tells us and the actions we send
local bettor = {}
ns.bettor = bettor

bettor.bookie = nil -- the bookie we follow
bettor.fight = nil  -- latest fight state from the bookie
bettor.account = { balance = 0, fightId = 0, side = nil, amount = 0, cashOut = 0 } -- ours, in copper

local lastHeard = -math.huge -- when the bookie last sent a state
local warnedAbout = {}       -- untrusted bookies we've already warned about
local seenStatus = {} -- fight id -> last status we reported

function bettor.hasBookie()
    return bettor.bookie ~= nil and GetTime() - lastHeard < cfg.bookieTimeout
end

function bettor.isBookie()
    return bettor.bookie == util.me()
end

-- Our bet on the current fight, if we have one.
function bettor.myBet()
    local f, account = bettor.fight, bettor.account
    if f and account.fightId == f.id and account.side and account.amount > 0 then
        return account.side, account.amount
    end
end

function bettor.odds(side)
    local f = bettor.fight
    if not f or f.pool[side] == 0 then return nil end
    return 1 + f.pool[otherSide(side)] * (100 - f.cut) / 100 / f.pool[side]
end

-- Payout if `side` wins, after adding `extra` copper to our bet
function bettor.previewPayout(side, extra)
    local f = bettor.fight
    local mySide, myAmount = bettor.myBet()
    local stake = (mySide == side and myAmount or 0) + extra
    return util.payout(stake, f.pool[side] + extra, f.pool[otherSide(side)], f.cut)
end

function bettor.statusText()
    if not bettor.hasBookie() then
        if comms.canRunBook(util.me()) and not ns.db.bookieMode then
            return "No bookie yet. Click Start Booking on the Bookie tab."
        end
        if bettor.untrusted then
            return bettor.untrusted .. " isn't on your trusted list (Config.lua)"
        end
        return "Waiting for a bookie to come online..."
    end

    local f = bettor.fight
    if f.status == "open" and f.closesAt then
        local left = math.max(0, math.floor(f.closesAt - GetTime()))
        return ("Betting open  -  %d:%02d left"):format(math.floor(left / 60), left % 60)
    end

    local texts = {
        open = "Betting open",
        ready = "The next fight is being set up",
        closed = "Betting closed  -  fight in progress",
        cancelled = "Fight called off  -  bets refunded",
        none = "No fight right now",
    }
    if f.status == "won" then
        return (f.winner and f[f.winner] or "?") .. " wins!"
    end
    return texts[f.status] or ""
end

-- Messages from the bookie

-- Event news in our own chat (only addon users see it)
local function tellChat(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[Olympus Fight Club]|r " .. fmt:format(...))
end

-- Reports each status change once
local function reportChange(f)
    local firstLook = seenStatus[f.id] == nil
    if seenStatus[f.id] == f.status then return end
    seenStatus[f.id] = f.status

    if f.status == "open" then
        log("|cff55ff55Betting is open: %s vs %s!|r", f.red, f.blue)
        tellChat("Betting is open: %s vs %s! Type /fc to bet.", f.red, f.blue)
        if cfg.autoOpen then ns.ui.show() end
    elseif f.status == "closed" then
        log("Betting closed. Fight!")
        tellChat("Betting is closed. Fight!")
    elseif f.status == "cancelled" and not firstLook then
        log("The fight was called off. Every bet has been refunded.")
        tellChat("The fight was called off. Every bet has been refunded.")
    elseif f.status == "won" and not firstLook then
        log("|cffffcc00%s wins!|r", f[f.winner])
        tellChat("%s wins!", f[f.winner])

        local side, amount = bettor.myBet()
        if side == f.winner then
            local winnings = util.payout(amount, f.pool[side], f.pool[otherSide(side)], f.cut)
            log("|cff55ff55You won %s!|r", money(winnings))
            tellChat("You won %s! It's in your balance.", money(winnings))
        elseif side then
            log("You lost your %s bet.", money(amount))
        end
    end
end

-- A fighter's class, race and gender from a STATE message, or nil (older bookies don't send them)
local function readLook(parts, first)
    local class, race, sex = parts[first], parts[first + 1], parts[first + 2]
    if not class or class == "" then return nil end
    return { class = class, race = race ~= "" and race or nil, sex = sex }
end

comms.on("STATE", function(sender, channel, parts)
    -- From the private channel, or whispered to us if our channel isn't working
    local viaChannel = channel == "CHANNEL" or channel == "WHISPER"
    if not viaChannel then return end
    if not comms.canRunBook(sender) then
        bettor.untrusted = sender
        if not warnedAbout[sender] then
            warnedAbout[sender] = true
            log("|cffff5555%s is running a book, but isn't on your trusted list, so it's ignored.|r", sender)
        end
        return
    end

    -- Stick with our bookie until they go quiet
    if bettor.hasBookie() and sender ~= bettor.bookie then
        return util.debug("Ignored fight update from \"%s\": you're following \"%s\".", sender, bettor.bookie)
    end

    -- New to us, or back after going quiet: check in (and ask for whispers if we need them)
    local isNewBookie = sender ~= bettor.bookie or not bettor.hasBookie()
    bettor.bookie = sender
    ns.db.lastBookie = sender
    lastHeard = GetTime()

    local closesIn = tonumber(parts[5]) or 0
    local f = {
        id = tonumber(parts[1]) or 0,
        status = parts[2],
        red = parts[3] ~= "" and parts[3] or nil,
        blue = parts[4] ~= "" and parts[4] or nil,
        closesAt = closesIn > 0 and GetTime() + closesIn or nil,
        pool = { red = tonumber(parts[6]) or 0, blue = tonumber(parts[7]) or 0 },
        count = { red = tonumber(parts[8]) or 0, blue = tonumber(parts[9]) or 0 },
        cut = tonumber(parts[10]) or 0,
        minBet = tonumber(parts[11]) or 0,
        maxBet = tonumber(parts[12]) or 0,
        winner = parts[13] ~= "" and parts[13] or nil,
        looks = { red = readLook(parts, 14), blue = readLook(parts, 17) },
    }
    bettor.fight = f

    if isNewBookie then
        log("%s is running the book.", sender)
        bettor.sync()
    end
    reportChange(f)
end)

-- Our bookie stopped, so follow the next one right away
comms.on("BYE", function(sender)
    if sender == bettor.bookie then
        log("%s has stopped running the book.", sender)
        bettor.bookie = nil
        bettor.fight = nil
    end
end)

local NOTES = { -- note code from the bookie -> message
    placed = "|cff55ff55Bet placed.|r",
    nofunds = "You don't have enough balance for that. Deposit some gold first.",
    closed = "Too late, betting has closed.",
    limits = "That's outside the bet limits.",
    otherside = "You've already bet on the other fighter.",
    invalid = "That bet didn't go through.",
    cashout = "Cash-out requested. Trade the bookie to get it now, or they'll mail it to you.",
    empty = "Your balance is too small to cash out.",
    guild = "Couldn't confirm you're in an Olympus guild. A trusted bookie from your guild needs to be online.",
}

comms.on("ACCOUNT", function(sender, channel, parts)
    if channel ~= "WHISPER" then return end
    if not comms.canRunBook(sender) then
        return util.debug("Ignored balance update from \"%s\": not on your trusted list.", sender)
    end

    -- Take updates from our bookie, or from any trusted bookie if we haven't heard ours yet
    if bettor.hasBookie() and sender ~= bettor.bookie then
        return util.debug("Ignored balance update from \"%s\": you're following \"%s\".", sender, bettor.bookie)
    end
    if sender ~= bettor.bookie then
        bettor.bookie = sender
        ns.db.lastBookie = sender
    end

    local account = bettor.account
    account.balance = tonumber(parts[1]) or 0
    account.fightId = tonumber(parts[2]) or 0
    account.side = (parts[3] == "red" or parts[3] == "blue") and parts[3] or nil
    account.amount = tonumber(parts[4]) or 0
    account.cashOut = tonumber(parts[5]) or 0

    local note = parts[6] or ""
    local deposit = tonumber(note:match("^deposit:(%d+)$"))
    if deposit then
        log("|cff55ff55Deposit of %s received.|r", money(deposit))
    elseif NOTES[note] then
        log("%s", NOTES[note])
    end
end)

-- Actions

local function toBookie(...)
    comms.send("WHISPER", bettor.bookie, comms.encode(...), nil, true)
end

local function readyToDeal()
    if not bettor.hasBookie() then
        log("There's no bookie online right now.")
        return false
    end
    if bettor.isBookie() then
        log("You're the bookie, so you can't bet on your own book.")
        return false
    end
    return true
end

-- Asks the bookie for our balance. Without the private channel we also ask for whispered fight updates.
local function checkIn(bookieName)
    local mode = comms.channelConnected() and "" or "direct"
    comms.send("WHISPER", bookieName, comms.encode("SYNC", mode), nil, true)
end

-- Returns true if we checked in with someone
function bettor.sync()
    local bookieName = bettor.bookie or ns.db.lastBookie
    if bookieName and bookieName ~= util.me() and comms.canRunBook(bookieName) then
        checkIn(bookieName)
        return true
    end
end

-- Without the private channel, keep checking in so whispered updates keep coming
local CHECK_IN_EVERY = 60 -- seconds
local lastCheckIn = -math.huge

function bettor.tick()
    if comms.channelConnected() or GetTime() - lastCheckIn < CHECK_IN_EVERY then return end
    if bettor.sync() then
        lastCheckIn = GetTime()
    end
end

-- Quick local checks; the bookie re-checks everything
function bettor.placeBet(side, copper)
    if not readyToDeal() then return end

    local f, account = bettor.fight, bettor.account
    if f.status ~= "open" then
        return log("Betting isn't open.")
    end

    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then
        return log("Enter how much you want to bet.")
    end
    if copper > account.balance then
        return log("You only have %s. Deposit more gold first.", money(account.balance))
    end

    local mySide = bettor.myBet()
    if mySide and mySide ~= side then
        return log("You've already bet on %s.", f[mySide])
    end

    toBookie("BET", f.id, side, copper)
    log("Betting %s on %s...", money(copper), f[side])
end

function bettor.cashOut()
    if not readyToDeal() then return end
    if bettor.account.balance <= 0 then
        return log("Your balance is empty.")
    end
    toBookie("CASHOUT")
end

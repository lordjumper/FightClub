local _, ns = ...
local cfg, util = ns.config, ns.util
local money, log = util.money, util.log

-- Cash-outs: a queue the bookie mails out by hand from the Cash-outs window
local mail = {}
ns.mail = mail

local NO_GOLD_WAIT = 3 -- seconds after "mail sent" to see our gold drop before calling it a dud

local mailboxOpen = false
local sending         -- the cash-out being mailed: { item, copper, moneyBefore, filled, answeredAt }
local lastSent        -- the last mail sent: { to, copper }, read as the bookie clicks Send
local lastMessage = "" -- latest note for the Cash-outs window

-- Notes who each mail goes to and how much gold is on it, so a cash-out is only crossed off
-- when a mail really went to that player (the Olympus addon checks mail the same way)
if hooksecurefunc then
    hooksecurefunc("SendMail", function(recipient)
        lastSent = {
            to = util.normalName(recipient),
            copper = GetSendMailMoney and tonumber(GetSendMailMoney()) or 0,
        }
    end)
end

function mail.isOpen()
    return mailboxOpen
end

-- The cash-out currently filled in, if any
function mail.sendingItem()
    return sending and sending.item
end

function mail.status()
    return lastMessage
end

local function say(fmt, ...)
    lastMessage = fmt:format(...)
end

local function removeFrom(list, value)
    for i, item in ipairs(list) do
        if item == value then
            return table.remove(list, i)
        end
    end
end

-- Queue

-- Adds a cash-out; the same player's cash-outs are merged
function mail.queueCashOut(name, copper)
    if copper <= 0 then return end

    for _, item in ipairs(ns.db.outbox) do
        if item.name == name then
            item.amount = item.amount + copper
            return
        end
    end
    table.insert(ns.db.outbox, { name = name, amount = copper, subject = "Fight Club cash-out" })
end

function mail.outboxTotal()
    local total = 0
    for _, item in ipairs(ns.db.outbox) do
        total = total + item.amount
    end
    return total
end

function mail.owedTo(player)
    local total = 0
    for _, item in ipairs(ns.db.outbox) do
        if item.name == player then
            total = total + item.amount
        end
    end
    return total
end

-- Takes gold paid another way (a trade) off a player's cash-out
function mail.paidOutside(player, copper)
    local outbox = ns.db.outbox
    for i = #outbox, 1, -1 do
        local item = outbox[i]
        if item.name == player and copper > 0 then
            local paid = math.min(item.amount, copper)
            item.amount = item.amount - paid
            copper = copper - paid
            if item.amount <= 0 then
                if sending and sending.item == item then sending = nil end
                table.remove(outbox, i)
            end
        end
    end
end

-- Filling in the game's Send Mail tab

local function fill(name, copper, subject)
    MailFrameTab2:Click()
    SendMailNameEditBox:SetText(name)
    SendMailSubjectEditBox:SetText(subject)
    if SendMailSendMoneyButton then
        SendMailSendMoneyButton:Click() -- "Send Money", not COD
    end
    MoneyInputFrame_SetCopper(SendMailMoney, copper)
end

-- Returns false if the game won't let addons fill it in
local function fillSendTab(name, copper, subject)
    if not (MailFrameTab2 and SendMailNameEditBox and SendMailSubjectEditBox and SendMailMoney) then
        return false
    end
    return (pcall(fill, name, copper, subject))
end

-- Called when the bookie clicks Mail on a cash-out
function mail.startCashOut(item)
    if not mailboxOpen then
        return say("Open a mailbox first.")
    end
    if GetMoney() < item.amount + cfg.postage then
        return say("You don't have enough gold to mail %s.", money(item.amount))
    end

    sending = { item = item, copper = item.amount, moneyBefore = GetMoney() }
    lastSent = nil
    sending.filled = fillSendTab(item.name, item.amount, item.subject)

    if sending.filled then
        say("%s to %s is filled in. Click Send in the mail window.", money(item.amount), item.name)
    else
        say("Your game won't let the addon fill it in. Mail %s to %s, then click Send.", money(item.amount), item.name)
    end
end

-- Runs twice a second. A mail counts when the game says it went out, it went to that player,
-- and the gold on it actually left our bags. Whatever it carried comes off their cash-out,
-- so a partial payment leaves the rest waiting.
function mail.step()
    if not sending or not sending.answeredAt then return end

    local item, sent = sending.item, lastSent
    local toThem = sent ~= nil and sent.to ~= nil and sent.to:lower() == item.name:lower()
    local attached = sent and sent.copper or 0
    local goldLeft = attached > 0 and GetMoney() <= sending.moneyBefore - attached

    if toThem and goldLeft then
        local paid = math.min(attached, item.amount)
        item.amount = item.amount - paid
        if item.amount <= 0 then
            removeFrom(ns.db.outbox, item)
            say("Mailed %s to %s. Paid in full.", money(paid), item.name)
        else
            say("Mailed %s to %s. %s is still owed.", money(paid), item.name, money(item.amount))
        end
        if attached > paid then
            say("Mailed %s to %s, %s more than they were owed.", money(attached), item.name, money(attached - paid))
        end
        log("Mailed %s to %s.", money(paid), item.name)
        sending = nil
        ns.bookie.cashOutPaid(item.name)
    elseif not toThem then
        say("That mail went to %s, not %s. Their cash-out is still waiting.", sent and sent.to or "someone else", item.name)
        sending = nil
    elseif GetTime() - sending.answeredAt > NO_GOLD_WAIT then
        say("That mail to %s went out without any gold. Their cash-out is still waiting.", item.name)
        sending = nil
    end
end

-- Mailbox events

function mail.onShow()
    mailboxOpen = true
    if ns.bookie.isActive() and #ns.db.outbox > 0 then
        say("Click Mail next to a name to fill in the mail.")
        ns.ui.showCashOuts()
    end
end

function mail.onClose()
    mailboxOpen = false
    sending = nil
end

function mail.onSendSuccess()
    if sending then
        sending.answeredAt = GetTime()
    end
end

function mail.onSendFailed()
    if sending then
        say("The server refused the mail to %s. Check the name and try again.", sending.item.name)
        sending = nil
    end
end

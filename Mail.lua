local _, ns = ...
local cfg, util = ns.config, ns.util
local money, log = util.money, util.log

-- Cash-outs: a queue the bookie mails out by hand from the Cash-outs window
local mail = {}
ns.mail = mail

local NO_GOLD_WAIT = 3 -- seconds after "mail sent" to see our gold drop before calling it a dud

local mailboxOpen = false
local sending         -- the cash-out being mailed: { item, copper, moneyBefore, filled, answeredAt }
local lastMessage = "" -- latest note for the Cash-outs window

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
    sending.filled = fillSendTab(item.name, item.amount, item.subject)

    if sending.filled then
        say("%s to %s is filled in. Click Send in the mail window.", money(item.amount), item.name)
    else
        say("Your game won't let the addon fill it in. Mail %s to %s, then click Send.", money(item.amount), item.name)
    end
end

-- Runs twice a second: a cash-out counts once our gold drops by its amount
function mail.step()
    if not sending then return end

    local item = sending.item
    if GetMoney() <= sending.moneyBefore - sending.copper then
        item.amount = item.amount - sending.copper
        if item.amount <= 0 then
            removeFrom(ns.db.outbox, item)
        end
        say("Mailed %s to %s.", money(sending.copper), item.name)
        log("Mailed %s to %s.", money(sending.copper), item.name)
        sending = nil
        ns.bookie.cashOutPaid(item.name)
    elseif sending.answeredAt and GetTime() - sending.answeredAt > NO_GOLD_WAIT then
        say("That mail to %s went out without the right gold. It's still waiting.", item.name)
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

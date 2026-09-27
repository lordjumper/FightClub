local _, ns = ...
local cfg, util = ns.config, ns.util

local comms = {}
ns.comms = comms

local SEPARATOR = "~" -- field separator in messages

-- Newer clients moved these into C_ tables.
local sendAddonMessage = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(cfg.prefix)
elseif RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(cfg.prefix)
end

-- Encoding, e.g. "BET~12~red~1000000"

function comms.encode(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        parts[i] = value == nil and "" or tostring(value)
    end
    return table.concat(parts, SEPARATOR)
end

local function decode(text)
    local parts = {}
    for part in (text .. SEPARATOR):gmatch("(.-)" .. SEPARATOR) do
        table.insert(parts, part)
    end
    return parts
end

-- Sending: one message per tick, urgent first. Keyed messages queue once and are built at send time.

local queues = {
    urgent = { first = 1, last = 0 },
    normal = { first = 1, last = 0 },
}
local queuedByKey = {} -- key -> the entry that will actually be sent

local function push(queue, entry)
    queue.last = queue.last + 1
    queue[queue.last] = entry
end

local function pop(queue)
    local entry = queue[queue.first]
    if entry then
        queue[queue.first] = nil
        queue.first = queue.first + 1
    end
    return entry
end

function comms.send(channel, target, message, key, urgent)
    local existing = key and queuedByKey[key]
    if existing and (existing.urgent or not urgent) then return end

    -- Safety net against floods. Per-player messages (with a key) are never dropped: each player
    -- only ever has one waiting, so balances and cash-outs always reach everyone.
    if not key and channel ~= "BROADCAST" and comms.backlog() >= cfg.maxQueue then
        return util.debug("Message queue full, dropped a message to \"%s\"", tostring(target))
    end

    local entry = { channel = channel, target = target, message = message, key = key, urgent = urgent }
    if key then
        queuedByKey[key] = entry -- an older copy gets skipped
    end
    push(urgent and queues.urgent or queues.normal, entry)
end

-- Hidden data to every branch via the private channel
function comms.broadcast(message, key)
    comms.send("BROADCAST", nil, message, key, true)
end

local function channelId()
    local id = GetChannelName(cfg.channelName)
    return id and id > 0 and id or nil
end

-- Old clients can't send addon data to a channel, so they send a chat line that gets filtered out
local canSendAddonToChannel = C_ChatInfo ~= nil and C_ChatInfo.SendAddonMessage ~= nil

-- Newer clients return a result code (0 = sent) and quietly drop messages over their
-- per-second limit. Older clients return nothing.
local function accepted(result)
    if type(result) == "number" then
        return result == 0
    end
    return result ~= false
end

local function sendToChannel(text)
    local id = channelId()
    if not id then return true end -- not in the channel, nothing to retry

    if canSendAddonToChannel then
        return accepted(sendAddonMessage(cfg.prefix, text, "CHANNEL", id))
    end
    SendChatMessage(cfg.prefix .. SEPARATOR .. text, "CHANNEL", nil, id)
    return true
end

local RETRY_AFTER = 1 -- seconds to back off when the client refuses a message
local pausedUntil = 0

-- Puts a refused message back at the front of its queue
local function requeue(entry, text)
    entry.message = text -- keep what we built, so its note isn't lost
    local queue = entry.urgent and queues.urgent or queues.normal
    queue.first = queue.first - 1
    queue[queue.first] = entry
    if entry.key then
        queuedByKey[entry.key] = entry
    end
    pausedUntil = GetTime() + RETRY_AFTER
end

function comms.sendNext()
    if GetTime() < pausedUntil then return end

    local entry
    repeat
        entry = pop(queues.urgent) or pop(queues.normal)
    until not entry or not entry.key or queuedByKey[entry.key] == entry

    if not entry then return end
    if entry.key then
        queuedByKey[entry.key] = nil
    end

    local text = entry.message
    if type(text) == "function" then
        text = text()
    end
    if not text then return end

    local command = text:match("^[^~]*")
    local sent
    if entry.channel == "BROADCAST" then
        sent = sendToChannel(text)
        if sent then
            -- Deliver to ourselves too, no need to wait for the echo
            comms.onMessage(cfg.prefix, text, "CHANNEL", util.me(), true)
        end
    else
        sent = accepted(sendAddonMessage(cfg.prefix, text, entry.channel, entry.target))
        util.debug("Sent %s to \"%s\"%s", command, tostring(entry.target), sent and "" or " - REFUSED, retrying")
    end

    if not sent then
        requeue(entry, text)
    end
end

function comms.backlog()
    local count = 0
    for _, queue in pairs(queues) do
        count = count + (queue.last - queue.first + 1)
    end
    return count
end

-- Trusted bookies, by full "first last" name and by first name (servers send one or the other)
local trustedFullNames, trustedFirstNames = {}, {}
local trustedDisplay = {} -- names as written, for /fc debug

for _, entry in ipairs(cfg.trustedBookies) do
    local first, last
    if type(entry) == "table" then
        first, last = entry.first, entry.last
    else
        first, last = tostring(entry):match("^(%S+)%s*(%S*)") -- plain "First Last" strings work too
    end

    if first and first ~= "" then
        first = first:lower()
        local full = (last and last ~= "") and (first .. " " .. last:lower()) or first
        trustedFullNames[full] = true
        trustedFirstNames[first] = true
        table.insert(trustedDisplay, "\"" .. full .. "\"")
    end
end

function comms.trustedListText()
    return #trustedDisplay > 0 and table.concat(trustedDisplay, ", ") or "(empty)"
end

-- Full names must match fully; a bare first name matches on first name
local function isTrusted(name)
    name = name:lower()
    if name:find(" ", 1, true) then
        return trustedFullNames[name] == true
    end
    return trustedFirstNames[name] == true
end

-- Only the trusted list can book. Sender names come from the server, so they can't be faked.
function comms.canRunBook(name)
    return name ~= nil and isTrusted(name)
end

-- Private channel: every addon user joins it, and it's kept out of chat

local lastJoinAttempt = -math.huge

local function isOurChannel(name)
    return name ~= nil and name:lower() == cfg.channelName:lower()
end

local function hideFromChatWindows()
    for i = 1, NUM_CHAT_WINDOWS do
        local chatFrame = _G["ChatFrame" .. i]
        if chatFrame then
            ChatFrame_RemoveChannel(chatFrame, cfg.channelName)
        end
    end
end

local JOIN_BY = 15    -- seconds after login we join at the latest
local firstTry        -- when we first wanted to join
local hidden = false  -- hidden from chat since we last joined

-- Joins if we're not in it yet (retries every 10s). Waits for the game's own channels
-- (General, Trade...) so they keep /1, /2. Hides it from chat once the join has gone through.
function comms.joinChannel()
    if channelId() then
        if not hidden then
            hideFromChatWindows()
            hidden = true
        end
        return
    end
    hidden = false

    firstTry = firstTry or GetTime()
    local _, firstChannel = GetChannelName(1)
    local gameChannelsIn = firstChannel ~= nil and firstChannel ~= ""
    if not gameChannelsIn and GetTime() - firstTry < JOIN_BY then return end
    if GetTime() - lastJoinAttempt < 10 then return end

    lastJoinAttempt = GetTime()
    JoinChannelByName(cfg.channelName, cfg.channelPassword)
end

-- Hides our channel's messages and join/leave notices
local function filterOurChannel(_, _, ...)
    local channelName = select(9, ...)
    return isOurChannel(channelName)
end

for _, event in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE", "CHAT_MSG_CHANNEL_NOTICE" }) do
    ChatFrame_AddMessageEventFilter(event, filterOurChannel)
end

-- Receiving

local handlers = {}

function comms.on(command, handler)
    handlers[command] = handler
end

function comms.onMessage(prefix, text, channel, sender, isLocal)
    if prefix ~= cfg.prefix or not sender then return end

    local rawSender = sender
    sender = util.normalName(sender)

    -- Skip the echo of our own broadcasts
    if channel == "CHANNEL" and sender == util.me() and not isLocal then return end

    local parts = decode(text)
    local command = table.remove(parts, 1)
    if not isLocal then
        util.debug("Got %s from \"%s\" by %s", tostring(command), tostring(rawSender), tostring(channel))
    end

    local handler = handlers[command]
    if handler then
        handler(sender, channel, parts)
    end
end

function comms.channelConnected()
    return channelId() ~= nil
end

-- Old-client channel lines look like "OlympusFC~STATE~..."
function comms.onChannelMessage(text, sender, _, _, _, _, _, _, channelName)
    if not isOurChannel(channelName) then return end

    local marker = cfg.prefix .. SEPARATOR
    if text:sub(1, #marker) == marker then
        comms.onMessage(cfg.prefix, text:sub(#marker + 1), "CHANNEL", sender)
    end
end

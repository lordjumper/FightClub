local _, ns = ...
local util, comms = ns.util, ns.comms

-- Confirms bettors are in an Olympus guild. WoW can't look up a stranger's guild by name,
-- so trusted characters vouch for members of their own guild.
local guild = {}
ns.guild = guild

local requestGuildRoster = C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster

local VERIFY_TIMEOUT = 15    -- seconds to wait for someone to vouch
local VERIFIED_FOR = 86400   -- seconds a confirmation lasts (1 day)
local MAX_MESSAGE = 230      -- room for names in one message

local members = {}            -- names in our own guild
local lastRosterRequest = -math.huge
local waiting = {}            -- player -> { since, asked, callbacks }

-- Our own roster

function guild.requestRoster()
    if IsInGuild() and GetTime() - lastRosterRequest > 60 then
        lastRosterRequest = GetTime()
        requestGuildRoster()
    end
end

function guild.onRosterUpdate()
    wipe(members)
    for i = 1, GetNumGuildMembers(true) do
        local name = GetGuildRosterInfo(i)
        if name then
            members[util.normalName(name)] = true
        end
    end
end

local function inOurOlympusGuild(player)
    return members[player] == true and util.isOlympusMember()
end

-- Bookie side: asking

local function finish(player, ok)
    local entry = waiting[player]
    waiting[player] = nil
    if ok then
        ns.db.verified[player] = time()
    end
    if entry then
        for _, callback in ipairs(entry.callbacks) do
            callback(ok)
        end
    end
end

-- Calls onDone(true) once the player is confirmed Olympus, or onDone(false) if nobody vouches.
function guild.verify(player, onDone)
    local confirmedAt = ns.db.verified[player]
    if confirmedAt and time() - confirmedAt < VERIFIED_FOR then
        return onDone(true)
    end
    if inOurOlympusGuild(player) then
        ns.db.verified[player] = time()
        return onDone(true)
    end

    local entry = waiting[player]
    if entry then
        table.insert(entry.callbacks, onDone)
    else
        waiting[player] = { since = GetTime(), asked = false, callbacks = { onDone } }
    end
end

-- Packs names into as few messages as possible
local function inBatches(names)
    local batches, batch, size = {}, {}, 0
    for _, name in ipairs(names) do
        if size + #name + 1 > MAX_MESSAGE then
            table.insert(batches, batch)
            batch, size = {}, 0
        end
        table.insert(batch, name)
        size = size + #name + 1
    end
    if #batch > 0 then
        table.insert(batches, batch)
    end
    return batches
end

-- Removes confirmations that have run out, so the saved file doesn't keep growing
local PRUNE_EVERY = 3600 -- seconds
local lastPrune = -math.huge

function guild.prune()
    local now = time()
    for player, confirmedAt in pairs(ns.db.verified) do
        if now - confirmedAt >= VERIFIED_FOR then
            ns.db.verified[player] = nil
        end
    end
    lastPrune = GetTime()
end

-- Runs twice a second: asks about new names and gives up on old ones
function guild.tick()
    guild.requestRoster()
    if GetTime() - lastPrune >= PRUNE_EVERY then
        guild.prune()
    end

    local toAsk = {}
    for player, entry in pairs(waiting) do
        if GetTime() - entry.since > VERIFY_TIMEOUT then
            finish(player, false)
        elseif not entry.asked then
            entry.asked = true
            table.insert(toAsk, player)
        end
    end

    for _, batch in ipairs(inBatches(toAsk)) do
        comms.broadcast(comms.encode("WHO", unpack(batch)))
    end
end

-- A trusted character vouches for their guildmates
comms.on("MEMBER", function(sender, channel, parts)
    if channel ~= "WHISPER" or not comms.canRunBook(sender) then return end
    for _, player in ipairs(parts) do
        if waiting[player] then
            finish(player, true)
        end
    end
end)

-- Trusted character side: answering

-- A bookie asks which of these names are in our guild
comms.on("WHO", function(sender, channel, parts)
    if channel ~= "CHANNEL" or sender == util.me() then return end
    if not comms.canRunBook(sender) or not comms.canRunBook(util.me()) then return end

    local ours = {}
    for _, player in ipairs(parts) do
        if inOurOlympusGuild(player) then
            table.insert(ours, player)
        end
    end

    for _, batch in ipairs(inBatches(ours)) do
        comms.send("WHISPER", sender, comms.encode("MEMBER", unpack(batch)))
    end
end)

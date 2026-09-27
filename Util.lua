local _, ns = ...
local cfg = ns.config

local util = {}
ns.util = util

util.COPPER_PER_GOLD = 10000 -- all amounts are stored in copper

-- Names
-- WoW: Forever names are "First Surname". Its unit functions return the surname where the
-- realm normally goes, and the server stamps messages "First Surname-Realm". The addon always
-- uses "First Surname": for balances, whispers, mail and the trusted list.

local function isRealm(text)
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then
        realm = (GetRealmName() or ""):gsub("[%s%-]", "")
    end
    return text == realm
end

local function unitNames(unit)
    if UnitFullName then
        local name, second = UnitFullName(unit)
        if name then return name, second end
    end
    return UnitName(unit)
end

-- True on servers where names have surnames (the second part isn't a realm)
local function namesHaveSurnames()
    local _, second = unitNames("player")
    return second ~= nil and second ~= "" and not isRealm(second)
end

-- A unit's full name, e.g. util.unitName("target") -> "Aaron Red"
function util.unitName(unit)
    local name, second = unitNames(unit)
    if not name or name == "" then return nil end
    if second and second ~= "" and not isRealm(second) then
        return name .. " " .. second
    end
    return name
end

function util.me()
    return util.unitName("player")
end

-- Any name from an event, the roster or the mailbox, as the server writes it without a realm.
-- "First Surname-Realm" -> "First Surname", "First-Surname" -> "First Surname", "Name-Realm" -> "Name"
function util.normalName(name)
    if type(name) ~= "string" or name == "" then return nil end

    local base, suffix = name:match("^(.-)%-([^%-]+)$")
    if not base or base == "" then return name end

    if base:find(" ", 1, true) or isRealm(suffix) or not namesHaveSurnames() then
        return base
    end
    return base .. " " .. suffix
end

-- "OLYMPUS" or "Olympus <anything>", any capitals. "Olympusfake" and "Not Olympus" don't count.
function util.isOlympusGuild(guildName)
    if not guildName then return false end
    local name, prefix = guildName:lower(), cfg.guildPrefix:lower()
    return name == prefix or name:sub(1, #prefix + 1) == prefix .. " "
end

function util.isOlympusMember()
    return util.isOlympusGuild(GetGuildInfo("player"))
end

-- Strips chat escape codes from typed text
function util.clean(text)
    return (tostring(text or ""):gsub("|", ""))
end

function util.otherSide(side)
    return side == "red" and "blue" or "red"
end

local function withCommas(number)
    local text, replaced = tostring(number), 1
    while replaced > 0 do
        text, replaced = text:gsub("^(%d+)(%d%d%d)", "%1,%2")
    end
    return text
end

-- The game's coin icons, sized to the text around them
local COIN = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:2:0|t"
local GOLD_ICON, SILVER_ICON, COPPER_ICON = COIN:format("Gold"), COIN:format("Silver"), COIN:format("Copper")

-- 12345678 -> "1,234[gold] 56[silver] 78[copper]", with coin icons
function util.money(copper)
    copper = math.floor(copper or 0)
    local gold = math.floor(copper / util.COPPER_PER_GOLD)
    local silver = math.floor(copper % util.COPPER_PER_GOLD / 100)
    local rest = copper % 100

    local parts = {}
    if gold > 0 then table.insert(parts, withCommas(gold) .. GOLD_ICON) end
    if silver > 0 then table.insert(parts, silver .. SILVER_ICON) end
    if rest > 0 or #parts == 0 then table.insert(parts, rest .. COPPER_ICON) end
    return table.concat(parts, " ")
end

-- Stake back plus a share of the losing pool, rounded down so the book never overpays
function util.payout(stake, winPool, losePool, cut)
    if winPool <= 0 or losePool <= 0 then
        return stake
    end
    local prize = losePool - math.floor(losePool * cut / 100)
    return stake + math.floor(prize * stake / winPool)
end

-- Adds a line to the window's activity feed
function util.log(fmt, ...)
    if ns.ui then
        ns.ui.addToFeed(fmt:format(...))
    end
end

-- Extra detail in the feed while /fc debug is on
function util.debug(fmt, ...)
    if ns.debugMode then
        util.log("|cff999999[debug] " .. fmt .. "|r", ...)
    end
end

-- Chat output, only for slash command replies
function util.print(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Fight Club:|r " .. fmt:format(...))
end

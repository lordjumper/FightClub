local _, ns = ...

-- Fixed settings
ns.config = {
    guildPrefix = "Olympus", -- guild names must start with this word, e.g. "OLYMPUS XII"

    -- The only characters allowed to run the book. Character names.

    trustedBookies = { -- DO NOT CHANGE THIS. CHANGING THIS MAY CAUSE LOSS OF FUNDS AND BREAK THE ADDON.
        { first = "Dook", last = "Pot" },
        { first = "Single", last = "Guy" },
    },

    channelName = "OlympusFightClub", -- hidden channel shared by every branch
    channelPassword = "olympus",      -- keeps randoms out

    -- Addon messages
    prefix = "OlympusFC",   -- tag on every message
    messageInterval = 0.15, -- seconds between sends
    stateInterval = 2,      -- min seconds between fight updates
    heartbeat = 10,         -- re-send fight state at least this often
    bookieTimeout = 30,     -- seconds of silence before the bookie counts as gone
    requestCooldown = 0.5,  -- min seconds between requests per player
    maxQueue = 5000,        -- flood limit for one-off messages; player balance updates are never limited

    tickInterval = 0.5, -- seconds between the addon's regular checks (timer, guild checks, mail)
    postage = 30,       -- copper per mail, so cash-outs must be bigger than this

    -- Window
    autoOpen = true,                  -- open the window when betting starts
    feedLines = 100,                  -- lines kept in the activity feed
    quickAmounts = { 50, 500, 2500, 5000, 10000 }, -- copper added by the quick buttons (50c, 5s, 25s, 50s, 1g)
}

-- Saved data and starting values (shared by all your characters)
ns.defaults = {
    bookieMode = false, -- running the book right now
    cut = 5,            -- house cut, % of the losing pool
    minBet = 50,        -- copper (50 copper)
    maxBet = 100000,    -- copper (10 gold)
    window = 120,       -- seconds betting stays open
    minimapAngle = 3.9, -- minimap button position (radians)
    lastBookie = false, -- the bookie we last dealt with, checked in with on login

    profit = 0,       -- house profit, copper
    fights = 0,       -- fights settled
    nextFightId = 1,  -- id for the next fight
    record = {},      -- fighter name -> { wins, losses }
    balance = {},     -- player name -> copper
    verified = {},    -- player name -> when they were confirmed Olympus
    outbox = {},      -- cash-outs waiting to be paid
}

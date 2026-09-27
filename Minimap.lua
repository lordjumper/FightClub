local _, ns = ...

-- Minimap button: click to open the window, drag to move it around the minimap
local minimap = {}
ns.minimap = minimap

local button = CreateFrame("Button", "GamblerMinimapButton", Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
button:RegisterForClicks("LeftButtonUp")
button:RegisterForDrag("LeftButton")

local background = button:CreateTexture(nil, "BACKGROUND")
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
background:SetSize(20, 20)
background:SetPoint("TOPLEFT", 7, -5)

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
icon:SetSize(17, 17)
icon:SetPoint("TOPLEFT", 7, -6)
icon:SetTexCoord(0.05, 0.95, 0.05, 0.95) -- trims the icon's edge

local border = button:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(53, 53)
border:SetPoint("TOPLEFT")

-- Puts the button on the minimap's edge at `angle` (radians)
local function place(angle)
    local radius = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- Angle from the minimap's centre to the cursor
local function cursorAngle()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    return math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)
end

button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        ns.db.minimapAngle = cursorAngle()
        place(ns.db.minimapAngle)
    end)
end)

button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

button:SetScript("OnClick", function()
    SlashCmdList.GAMBLER("") -- same as typing /fc
end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Olympus Fight Club")
    GameTooltip:AddLine(ns.bettor.statusText(), 1, 1, 1)
    GameTooltip:AddLine("Click to open, drag to move.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)

button:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- Called once saved data is loaded
function minimap.restore()
    place(ns.db.minimapAngle)
end

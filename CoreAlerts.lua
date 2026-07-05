local addonName, CA = ...

local WOW_FONT = select(1, GameFontNormal:GetFont())

CoreAlertsDB = CoreAlertsDB or {
    minimapPos = 45,
    _migrated  = false,
    anchorX    = 0,
    anchorY    = 100,
    rules      = {},
}

-- ==========================================
-- MIGRATION
-- ==========================================
local function MigrateDB()
    local db = CoreAlertsDB
    if db._migrated then return end

    db.rules = db.rules or {}

    if db.cooldownSpellID then
        table.insert(db.rules, {
            type      = "cooldown",
            spellID   = tonumber(db.cooldownSpellID) or 0,
            threshold = tonumber(db.cooldownThreshold) or 5,
            message   = db.cooldownText or "",
            fontSize  = 20,
        })
    end

    if db.chargeSpellID then
        table.insert(db.rules, {
            type     = "charges",
            spellID  = tonumber(db.chargeSpellID) or 0,
            message  = db.chargeText or "",
            fontSize = 20,
        })
    end

    db.cooldownSpellID   = nil
    db.cooldownThreshold = nil
    db.cooldownText      = nil
    db.debuffSpellID     = nil
    db.debuffThreshold   = nil
    db.debuffText        = nil
    db.chargeSpellID     = nil
    db.chargeText        = nil
    db._migrated         = true
end

-- ==========================================
-- TEXT PARSING
-- ==========================================
function CA.ParseCustomAlertText(rawString, fontSize)
    if not rawString then return "" end
    local iconSize = math.floor(fontSize or 20)
    return (rawString:gsub("{(spell):(%d+)}", function(_, id)
        local spellID = tonumber(id)
        if spellID then
            local info = C_Spell.GetSpellInfo(spellID)
            if info and info.iconID then
                return string.format("|T%d:%d:%d:0:0:64:64:4:60:4:60|t", info.iconID, iconSize, iconSize)
            end
        end
        return ""
    end))
end

-- ==========================================
-- FRAMES
-- ==========================================
-- mainEngine: OnUpdate only — always runs in tainted context, never calls game APIs
-- eventEngine: events only — clean context, all game API reads happen here
local mainEngine  = CreateFrame("Frame")
local eventEngine = CreateFrame("Frame")
CA.alertPool = {}

function CA.RebuildAlertPool()
    for _, fs in ipairs(CA.alertPool) do fs:Hide() end
    local rules = CoreAlertsDB.rules
    while #CA.alertPool < #rules do
        local fs = mainEngine:CreateFontString(nil, "OVERLAY")
        fs:Hide()
        table.insert(CA.alertPool, fs)
    end
    for i = 1, #rules do
        CA.alertPool[i]:SetFont(WOW_FONT, rules[i].fontSize or 20, "OUTLINE")
    end
end

-- ==========================================
-- STATE CACHE
-- ==========================================
-- All game API reads write into this table. ProcessGameTick reads only from here.
--
-- spellCache[spellID] = {
--   cdActive      = bool,
--   cdEndTime     = number,   GetTime()-based expiry timestamp
--   chargesActive = bool,     true = at least one charge recharging; false = all charges full
-- }
local spellCache = {}

-- Safe to call from any context. pcall guards the numeric arithmetic so a secret-number
-- taint error silently leaves the entry unchanged rather than spamming the error log.
local function CacheSpellCooldown(spellID)
    local cd = C_Spell.GetSpellCooldown(spellID)
    if not cd or not cd.isActive or cd.isOnGCD then return end
    -- pcall BEFORE any write to spellCache.
    -- If this throws (tainted execution context), we return without touching spellCache at all.
    -- Writing to spellCache in a tainted context would contaminate it and taint all future
    -- event callbacks that read it — causing the "execution tainted by CoreAlerts" cascade.
    local ok, endTime = pcall(function() return cd.startTime + cd.duration end)
    if not ok then return end
    local entry = spellCache[spellID] or {}
    spellCache[spellID] = entry
    entry.cdActive  = true
    entry.cdEndTime = endTime
end

-- Called on SPELL_UPDATE_COOLDOWN. Boolean-only — never reads numeric fields.
-- Handles the normal CD-expiry path (real cooldown finished while addon was running).
local function ScanCooldownEnds()
    local now = GetTime()
    for _, rule in ipairs(CoreAlertsDB.rules or {}) do
        if rule.type == "cooldown" then
            local cd = C_Spell.GetSpellCooldown(rule.spellID)
            if cd and not cd.isActive then
                local entry = spellCache[rule.spellID]
                if entry and (not entry.cdEndTime or now >= entry.cdEndTime) then
                    entry.cdActive  = false
                    entry.cdEndTime = nil
                end
            end
        end
    end
end

-- isActive is always a safe boolean. Never reads currentCharges (permanent secret number).
local function CacheCharges()
    for _, rule in ipairs(CoreAlertsDB.rules or {}) do
        if rule.type == "charges" then
            local c = C_Spell.GetSpellCharges(rule.spellID)
            local entry = spellCache[rule.spellID] or {}
            spellCache[rule.spellID] = entry
            -- isActive=false → no charge recharging → all charges full
            entry.chargesActive = c and c.isActive or false
        end
    end
end

function CA.RefreshCache()
    for _, rule in ipairs(CoreAlertsDB.rules or {}) do
        if rule.type == "cooldown" then CacheSpellCooldown(rule.spellID) end
    end
    CacheCharges()
end

-- ==========================================
-- GAME LOOP
-- ==========================================
local playerCastingSpellID = nil

local function ProcessGameTick()
    local rules = CoreAlertsDB and CoreAlertsDB.rules
    if not rules then return end

    local anchorX  = CoreAlertsDB.anchorX or 0
    local anchorY  = CoreAlertsDB.anchorY or 100
    local currentY = anchorY
    local now      = GetTime()

    for i, rule in ipairs(rules) do
        local fs = CA.alertPool[i]
        if not fs then break end

        local show  = false
        local extra = ""
        local cache = spellCache[rule.spellID]

        if rule.combatOnly and not UnitAffectingCombat("player") then
            -- leave show=false

        elseif rule.type == "cooldown" then
            if cache and cache.cdActive and cache.cdEndTime
                    and playerCastingSpellID ~= rule.spellID then
                local rem = cache.cdEndTime - now
                if rem > 0 and rem <= (rule.threshold or 5) then
                    show  = true
                    extra = string.format(" %.1fs", rem)
                end
            end

        elseif rule.type == "charges" then
            -- chargesActive=false → no charge recharging → spell is ready at full charges
            if cache and not cache.chargesActive then
                show = true
            end
        end

        if show then
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", UIParent, "CENTER", anchorX, currentY)
            fs:SetTextColor(rule.colorR or 1, rule.colorG or 1, rule.colorB or 1)
            fs:SetText(CA.ParseCustomAlertText(rule.message, rule.fontSize) .. extra)
            fs:Show()
            currentY = currentY - ((rule.fontSize or 20) + 6)
        else
            fs:Hide()
        end
    end

    for i = #rules + 1, #CA.alertPool do
        CA.alertPool[i]:Hide()
    end
end

-- ==========================================
-- MINIMAP BUTTON
-- ==========================================
local function BuildMinimapButton()
    local miniBtn = CreateFrame("Button", "CoreAlertsMinimapIcon", Minimap)
    miniBtn:SetSize(32, 32)
    miniBtn:SetFrameLevel(Minimap:GetFrameLevel() + 4)
    miniBtn:SetNormalTexture("Interface\\Icons\\Spell_Nature_Purge")
    miniBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local border = miniBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("CENTER", miniBtn, "CENTER", 1, -1)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local function PositionIcon()
        local angle = CoreAlertsDB.minimapPos or 45
        local x = 52 - (80 * math.cos(math.rad(angle)))
        local y = (80 * math.sin(math.rad(angle))) - 52
        miniBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", x, y)
    end

    miniBtn:RegisterForDrag("LeftButton")
    miniBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetLeft() + 70, Minimap:GetTop() - 70
            local px, py = GetCursorPosition()
            local scale  = Minimap:GetEffectiveScale()
            local angle  = math.deg(math.atan2((py / scale) - my, mx - (px / scale)))
            CoreAlertsDB.minimapPos = angle
            PositionIcon()
        end)
    end)
    miniBtn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    miniBtn:SetScript("OnClick", function()
        if CA.configWindow then
            if CA.configWindow:IsShown() then CA.configWindow:Hide()
            else CA.configWindow:Show() end
        end
    end)

    PositionIcon()
end

-- ==========================================
-- ADDON LOADED
-- ==========================================
mainEngine:RegisterEvent("ADDON_LOADED")
mainEngine:SetScript("OnEvent", function(self, event, arg1)
    if event ~= "ADDON_LOADED" or arg1 ~= addonName then return end

    MigrateDB()
    CoreAlertsDB.anchorX = CoreAlertsDB.anchorX or 0
    CoreAlertsDB.anchorY = CoreAlertsDB.anchorY or 100

    CA.RebuildAlertPool()
    if CA.BuildSettings then CA.BuildSettings() end
    BuildMinimapButton()

    -- All game-API event handling on a dedicated clean frame (no OnUpdate ever set on it).
    eventEngine:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventEngine:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    eventEngine:RegisterEvent("SPELL_UPDATE_CHARGES")
    eventEngine:RegisterUnitEvent("UNIT_SPELLCAST_START",         "player")
    eventEngine:RegisterUnitEvent("UNIT_SPELLCAST_STOP",          "player")
    eventEngine:RegisterUnitEvent("UNIT_SPELLCAST_FAILED",        "player")
    eventEngine:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED",   "player")
    eventEngine:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED",     "player")
    eventEngine:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    eventEngine:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP",  "player")

    eventEngine:SetScript("OnEvent", function(_, ev, _, _, spellID)
        if ev == "PLAYER_ENTERING_WORLD" then
            CA.RefreshCache()

        elseif ev == "SPELL_UPDATE_COOLDOWN" then
            ScanCooldownEnds()

        elseif ev == "SPELL_UPDATE_CHARGES" then
            CacheCharges()

        elseif ev == "UNIT_SPELLCAST_START" or ev == "UNIT_SPELLCAST_CHANNEL_START" then
            playerCastingSpellID = spellID

        elseif ev == "UNIT_SPELLCAST_STOP"       or ev == "UNIT_SPELLCAST_FAILED"
            or ev == "UNIT_SPELLCAST_INTERRUPTED" or ev == "UNIT_SPELLCAST_CHANNEL_STOP" then
            playerCastingSpellID = nil

        elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
            playerCastingSpellID = nil
            for _, rule in ipairs(CoreAlertsDB.rules or {}) do
                if rule.type == "cooldown" and rule.spellID == spellID then
                    -- Immediate read: usually clean context on first cast.
                    CacheSpellCooldown(spellID)
                    -- Deferred read one frame later in case the CD API lagged.
                    -- pcall discards any taint error silently.
                    C_Timer.After(0, function() pcall(CacheSpellCooldown, spellID) end)
                    break
                end
            end
        end

        ProcessGameTick()
    end)

    -- Throttled OnUpdate: reads only from spellCache, zero game API calls.
    local tickAccum = 0
    mainEngine:SetScript("OnUpdate", function(_, elapsed)
        tickAccum = tickAccum + elapsed
        if tickAccum >= 0.1 then
            tickAccum = 0
            ProcessGameTick()
        end
    end)

    SLASH_COREALERTS1 = "/ca"
    SlashCmdList["COREALERTS"] = function()
        if CA.configWindow then
            if CA.configWindow:IsShown() then CA.configWindow:Hide()
            else CA.configWindow:Show() end
        end
    end

    self:UnregisterEvent("ADDON_LOADED")
end)

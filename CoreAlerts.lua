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
    for _, entry in ipairs(CA.alertPool) do
        entry.frame:Hide()
        entry.frame:SetAlpha(1)
        entry.state = "idle"
    end
    local rules = CoreAlertsDB.rules
    while #CA.alertPool < #rules do
        local frame = CreateFrame("Frame", nil, mainEngine)
        frame:SetSize(1, 1)
        local fs = frame:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("LEFT", frame, "LEFT", 0, 0)
        fs:SetJustifyH("LEFT")
        frame:Hide()
        table.insert(CA.alertPool, {
            frame=frame, fs=fs, state="idle",
            animStart=0, activeStart=0, leaveBaseY=0, baseX=0, baseY=0,
        })
    end
    for i = 1, #rules do
        CA.alertPool[i].fs:SetFont(WOW_FONT, rules[i].fontSize or 20, "OUTLINE")
    end
end

-- ==========================================
-- STATE CACHE
-- ==========================================
-- All game API reads write into this table. ProcessGameTick reads only from here.
--
-- spellCache[spellID] = {
--   cdActive      = bool,
--   cdEndTime     = number,  GetTime()-based expiry timestamp
--   chargesActive = bool,    true = at least one charge recharging; false = all charges full
-- }
local spellCache      = {}
local spellCDDuration = {}  -- spellID → effective cooldown duration (seconds, plain number)
local playerClass     = nil -- classFile e.g. "MAGE", set on PLAYER_ENTERING_WORLD

-- Two-path cache for spell cooldowns:
--   Path 1 (isActive=true, clean): exact endTime from startTime+duration. Returns.
--   Path 1 (isActive=true, tainted): arithmetic throws, return without overwriting —
--     preserves the endTime written by the initial cast. NEVER fall through when isActive=true:
--     SPELL_UPDATE_COOLDOWN fires repeatedly and would reset cdEndTime to GetTime()+dur each
--     time, pushing the alert window forward indefinitely.
--   Path 2 (isActive=false or nil): UNIT_SPELLCAST_SUCCEEDED fires before the API reflects the
--     new cooldown, so isActive is still false. Use the pre-cached duration for the initial endTime.
local function CacheSpellCooldown(spellID)
    local cd = C_Spell.GetSpellCooldown(spellID)
    if cd and cd.isActive and not cd.isOnGCD then
        -- Path 1: clean context — compute exact endTime from startTime + duration.
        local ok, endTime = pcall(function() return cd.startTime + cd.duration end)
        if ok then
            local durOk, dur = pcall(function() return cd.duration end)
            if durOk and dur and dur > 0 then spellCDDuration[spellID] = dur end
            local entry = spellCache[spellID] or {}
            spellCache[spellID] = entry
            entry.cdActive  = true
            entry.cdEndTime = endTime
            return
        end
        -- Path 1 failed (tainted). Two cases:
        --   a) Cache already has a valid future endTime → skip. Overwriting would reset
        --      cdEndTime to GetTime()+dur on every SPELL_UPDATE_COOLDOWN, pushing the alert
        --      window forward indefinitely.
        --   b) Cache is empty or stale → this is first detection. Movement abilities often
        --      register isActive=true before UNIT_SPELLCAST_SUCCEEDED fires, so the
        --      isActive=false path below never runs for them. Write the initial endTime now.
        -- cdEndTime is always a plain number (GetTime()+dur), so the comparison is taint-safe.
        local existing = spellCache[spellID]
        if existing and existing.cdActive and existing.cdEndTime
                and existing.cdEndTime > GetTime() then
            return  -- valid cache present, preserve it
        end
        local dur = spellCDDuration[spellID]
        if dur and dur > 0 then
            local entry = spellCache[spellID] or {}
            spellCache[spellID] = entry
            entry.cdActive  = true
            entry.cdEndTime = GetTime() + dur
        end
        return
    end
    -- cd is nil or isActive=false: cooldown not yet registered at cast time.
    -- Use pre-cached duration for the initial endTime.
    local dur = spellCDDuration[spellID]
    if dur and dur > 0 then
        local entry = spellCache[spellID] or {}
        spellCache[spellID] = entry
        entry.cdActive  = true
        entry.cdEndTime = GetTime() + dur
    end
end

-- Called on SPELL_UPDATE_COOLDOWN. Tries to cache active CDs that UNIT_SPELLCAST_SUCCEEDED
-- may have missed due to API timing. NEVER writes for inactive CDs — SPELL_UPDATE_COOLDOWN
-- fires in a tainted context in WoW 12.x, and writing entry fields (even false/nil) from a
-- tainted context taints spellCache, which then contaminates all future eventEngine callbacks.
-- ProcessGameTick's `rem > 0` check already hides alerts for expired CDs naturally.
local function HandleCooldownUpdate()
    for _, rule in ipairs(CoreAlertsDB.rules or {}) do
        if rule.type == "cooldown" then
            local cd = C_Spell.GetSpellCooldown(rule.spellID)
            if cd and cd.isActive and not cd.isOnGCD then
                -- CacheSpellCooldown's pcall-before-write ensures no taint injection
                -- if this context is still tainted. Once taint clears it will succeed.
                CacheSpellCooldown(rule.spellID)
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
    -- Pre-populate spellCDDuration using GetSpellCooldownTime (safe in any execution context —
    -- it queries spell data, not player timing). This ensures the Path 3 fallback in
    -- CacheSpellCooldown always has a duration available, even when GetSpellCooldown returns nil.
    if C_Spell.GetSpellCooldownTime then
        for _, rule in ipairs(CoreAlertsDB.rules or {}) do
            if rule.type == "cooldown" then
                local dur = C_Spell.GetSpellCooldownTime(rule.spellID)
                if dur and dur > 0 then spellCDDuration[rule.spellID] = dur end
            end
        end
    end
    for _, rule in ipairs(CoreAlertsDB.rules or {}) do
        if rule.type == "cooldown" then
            -- Only cache spells actually on cooldown right now (e.g. after /reload mid-CD).
            -- Calling CacheSpellCooldown for idle spells writes a fake cdEndTime = now+dur,
            -- which poisons the validity check that prevents the timer-reset bug.
            local cd = C_Spell.GetSpellCooldown(rule.spellID)
            if cd and cd.isActive and not cd.isOnGCD then
                CacheSpellCooldown(rule.spellID)
            end
        end
    end
    CacheCharges()
end

-- ==========================================
-- GAME LOOP
-- ==========================================
local playerCastingSpellID = nil

local ENTER_DUR     = 0.35
local LEAVE_DUR     = 0.40
local ENTER_SLIDE_X = 200   -- px right of final position at animation start
local LEAVE_SLIDE_Y = -50   -- extra px downward during leave animation
local DRIFT_SPEED   = 10    -- px/second downward drift while active
local MAX_DRIFT     = 60    -- cap so alerts don't drift off-screen

local function UpdateAnimations()
    local now = GetTime()
    for _, entry in ipairs(CA.alertPool) do
        if entry.state == "entering" then
            local t    = math.min(1, (now - entry.animStart) / ENTER_DUR)
            local ease = 1 - (1 - t) * (1 - t)   -- ease-out quad
            entry.frame:ClearAllPoints()
            entry.frame:SetPoint("LEFT", UIParent, "CENTER",
                entry.baseX + ENTER_SLIDE_X * (1 - ease), entry.baseY)
            entry.frame:SetAlpha(ease)
            if t >= 1 then
                entry.state       = "active"
                entry.activeStart = now
            end

        elseif entry.state == "active" then
            local drift = math.min((now - entry.activeStart) * DRIFT_SPEED, MAX_DRIFT)
            entry.frame:ClearAllPoints()
            entry.frame:SetPoint("LEFT", UIParent, "CENTER",
                entry.baseX, entry.baseY - drift)

        elseif entry.state == "leaving" then
            local t    = math.min(1, (now - entry.animStart) / LEAVE_DUR)
            local ease = t * t                      -- ease-in quad
            entry.frame:ClearAllPoints()
            entry.frame:SetPoint("LEFT", UIParent, "CENTER",
                entry.baseX, entry.leaveBaseY + LEAVE_SLIDE_Y * ease)
            entry.frame:SetAlpha(1 - ease)
            if t >= 1 then
                entry.state = "idle"
                entry.frame:Hide()
                entry.frame:SetAlpha(1)
            end
        end
    end
end

local function PlayerClassMatches(rule)
    if not rule.classes or #rule.classes == 0 then return true end
    for _, c in ipairs(rule.classes) do
        if c == playerClass then return true end
    end
    return false
end

local function ProcessGameTick()
    local rules = CoreAlertsDB and CoreAlertsDB.rules
    if not rules then return end

    local anchorX  = CoreAlertsDB.anchorX or 0
    local anchorY  = CoreAlertsDB.anchorY or 100
    local currentY = anchorY
    local now      = GetTime()

    for i, rule in ipairs(rules) do
        local entry = CA.alertPool[i]
        if not entry then break end

        local show  = false
        local extra = ""
        local cache = spellCache[rule.spellID]

        if rule.combatOnly and not UnitAffectingCombat("player") then
            -- leave show=false

        elseif not PlayerClassMatches(rule) then
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

        local lineH = (rule.fontSize or 20) + 6

        if show then
            if entry.state == "idle" then
                entry.baseX     = anchorX
                entry.baseY     = currentY
                entry.animStart = now
                entry.state     = "entering"
                entry.fs:SetFont(WOW_FONT, rule.fontSize or 20, "OUTLINE")
                entry.fs:SetTextColor(rule.colorR or 1, rule.colorG or 1, rule.colorB or 1)
                entry.frame:ClearAllPoints()
                entry.frame:SetPoint("LEFT", UIParent, "CENTER",
                    entry.baseX + ENTER_SLIDE_X, entry.baseY)
                entry.frame:SetAlpha(0)
                entry.frame:Show()
            elseif entry.state == "leaving" then
                -- Re-triggered during leave — restart enter from the same Y slot
                entry.baseX     = anchorX
                entry.animStart = now
                entry.state     = "entering"
                entry.frame:Show()
            end
            if entry.state == "entering" or entry.state == "active" then
                entry.fs:SetText(CA.ParseCustomAlertText(rule.message, rule.fontSize) .. extra)
            end
            currentY = currentY - lineH
        else
            if entry.state == "entering" or entry.state == "active" then
                local drift = (entry.state == "active")
                    and math.min((now - entry.activeStart) * DRIFT_SPEED, MAX_DRIFT)
                    or  0
                entry.leaveBaseY = entry.baseY - drift
                entry.animStart  = now
                entry.state      = "leaving"
            end
        end
    end

    -- Trigger leave for pool entries beyond the current rule count
    for i = #rules + 1, #CA.alertPool do
        local entry = CA.alertPool[i]
        if entry.state == "entering" or entry.state == "active" then
            local drift = (entry.state == "active")
                and math.min((now - entry.activeStart) * DRIFT_SPEED, MAX_DRIFT)
                or  0
            entry.leaveBaseY = entry.baseY - drift
            entry.animStart  = now
            entry.state      = "leaving"
        end
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
            playerClass = select(2, UnitClass("player"))
            CA.RefreshCache()

        elseif ev == "SPELL_UPDATE_COOLDOWN" then
            HandleCooldownUpdate()

        elseif ev == "SPELL_UPDATE_CHARGES" then
            CacheCharges()

        elseif ev == "UNIT_SPELLCAST_START" or ev == "UNIT_SPELLCAST_CHANNEL_START" then
            playerCastingSpellID = spellID

        elseif ev == "UNIT_SPELLCAST_STOP"       or ev == "UNIT_SPELLCAST_FAILED"
            or ev == "UNIT_SPELLCAST_INTERRUPTED" or ev == "UNIT_SPELLCAST_CHANNEL_STOP" then
            playerCastingSpellID = nil

        elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
            playerCastingSpellID = nil
            -- SPELL_UPDATE_COOLDOWN fires after this and calls HandleCooldownUpdate,
            -- which is the reliable path for caching the CD. The immediate attempt here
            -- catches the common case where the API is already updated.
            for _, rule in ipairs(CoreAlertsDB.rules or {}) do
                if rule.type == "cooldown" and rule.spellID == spellID then
                    CacheSpellCooldown(spellID)
                    break
                end
            end
        end

        ProcessGameTick()
    end)

    -- OnUpdate: animations run every frame; game tick is throttled to 0.1s.
    local tickAccum = 0
    mainEngine:SetScript("OnUpdate", function(_, elapsed)
        UpdateAnimations()
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

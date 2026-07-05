-- ==========================================
-- COREALERTS SETTINGS UI
-- ==========================================
local addonName, CA = ...

local WOW_FONT = select(1, GameFontNormal:GetFont())

local TYPE_ORDER = { "cooldown", "charges" }

local TYPE_LABELS = {
    cooldown = "Cooldown",
    charges  = "Charges",
}

local TYPE_COLORS = {
    cooldown = { 1,    0.6,  0    },
    charges  = { 0.35, 1,    0.35 },
}

local THRESHOLD_LABELS = {
    cooldown = "Seconds before ready:",
}

-- ==========================================
-- BUILD SETTINGS (called from ADDON_LOADED)
-- ==========================================
function CA.BuildSettings()

    -- ----------------------------------------
    -- Anchor frame
    -- ----------------------------------------
    local anchorFrame = CreateFrame("Frame", "CoreAlertsAnchorFrame", UIParent)
    anchorFrame:SetSize(200, 26)
    anchorFrame:SetMovable(true)
    anchorFrame:EnableMouse(true)
    anchorFrame:RegisterForDrag("LeftButton")
    anchorFrame:SetFrameStrata("HIGH")
    anchorFrame:SetClampedToScreen(true)
    anchorFrame:Hide()
    CA.anchorFrame = anchorFrame

    local anchorBorder = anchorFrame:CreateTexture(nil, "BORDER")
    anchorBorder:SetAllPoints(anchorFrame)
    anchorBorder:SetColorTexture(0.3, 0.5, 1, 0.6)

    local anchorInner = anchorFrame:CreateTexture(nil, "ARTWORK")
    anchorInner:SetPoint("TOPLEFT",     anchorFrame, "TOPLEFT",     1, -1)
    anchorInner:SetPoint("BOTTOMRIGHT", anchorFrame, "BOTTOMRIGHT", -1, 1)
    anchorInner:SetColorTexture(0.05, 0.05, 0.25, 0.92)

    local anchorLabel = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    anchorLabel:SetAllPoints(anchorFrame)
    anchorLabel:SetText("=  CoreAlerts  -  drag to reposition")
    anchorLabel:SetTextColor(0.7, 0.85, 1)

    local function ApplyAnchorPosition()
        anchorFrame:ClearAllPoints()
        anchorFrame:SetPoint("CENTER", UIParent, "CENTER",
            CoreAlertsDB.anchorX or 0, CoreAlertsDB.anchorY or 100)
    end

    anchorFrame:SetScript("OnDragStart", anchorFrame.StartMoving)
    anchorFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        CoreAlertsDB.anchorX = math.floor(x - UIParent:GetWidth()  / 2 + 0.5)
        CoreAlertsDB.anchorY = math.floor(y - UIParent:GetHeight() / 2 + 0.5)
    end)

    ApplyAnchorPosition()

    -- ----------------------------------------
    -- Main window
    -- ----------------------------------------
    local win = CreateFrame("Frame", "CoreAlertsPanel", UIParent, "BasicFrameTemplate")
    win:SetSize(420, 500)
    win:SetPoint("CENTER", UIParent, "CENTER")
    win.TitleText:SetText("CoreAlerts Options")
    win:Hide()
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop",  win.StopMovingOrSizing)
    table.insert(UISpecialFrames, "CoreAlertsPanel")
    CA.configWindow = win

    -- ----------------------------------------
    -- Scroll frame (rule list)
    -- ----------------------------------------
    local scrollFrame = CreateFrame("ScrollFrame", nil, win)
    scrollFrame:SetSize(390, 340)
    scrollFrame:SetPoint("TOPLEFT", win, "TOPLEFT", 12, -36)
    scrollFrame:EnableMouseWheel(true)

    local listContent = CreateFrame("Frame", nil, scrollFrame)
    listContent:SetWidth(390)
    listContent:SetHeight(1)
    scrollFrame:SetScrollChild(listContent)

    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, listContent:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, self:GetVerticalScroll() - delta * 30)))
    end)

    -- ----------------------------------------
    -- Add Rule button
    -- ----------------------------------------
    local addBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    addBtn:SetSize(120, 26)
    addBtn:SetPoint("BOTTOM", win, "BOTTOM", 0, 16)
    addBtn:SetText("+ Add Rule")

    -- ----------------------------------------
    -- Editor overlay (modal)
    -- ----------------------------------------
    local overlay = CreateFrame("Frame", nil, win)
    overlay:SetAllPoints(win)
    overlay:EnableMouse(true)
    overlay:Hide()

    local overlayBg = overlay:CreateTexture(nil, "BACKGROUND")
    overlayBg:SetAllPoints(overlay)
    overlayBg:SetColorTexture(0, 0, 0, 0.65)

    local panel = CreateFrame("Frame", nil, overlay, "BasicFrameTemplate")
    panel:SetSize(390, 380)
    panel:SetPoint("CENTER", overlay, "CENTER", 0, 10)

    -- ----------------------------------------
    -- Editor widgets
    -- ----------------------------------------

    -- Type cycle
    local typeCycleBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    typeCycleBtn:SetSize(170, 24)
    typeCycleBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -36)

    -- Combat-only checkbox (same row as type cycle button)
    local combatOnlyCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    combatOnlyCheck:SetSize(24, 24)
    combatOnlyCheck:SetPoint("TOPLEFT", typeCycleBtn, "TOPRIGHT", 14, 2)

    local combatOnlyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    combatOnlyLabel:SetPoint("LEFT", combatOnlyCheck, "RIGHT", 2, 0)
    combatOnlyLabel:SetText("Only in combat")

    -- Spell ID
    local spellIDLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spellIDLabel:SetPoint("TOPLEFT", typeCycleBtn, "BOTTOMLEFT", 0, -10)
    spellIDLabel:SetText("Spell ID:")

    local spellIDBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    spellIDBox:SetSize(160, 24)
    spellIDBox:SetPoint("TOPLEFT", spellIDLabel, "BOTTOMLEFT", 0, -4)
    spellIDBox:SetAutoFocus(false)
    spellIDBox:SetNumeric(true)
    spellIDBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local spellIconTex = panel:CreateTexture(nil, "ARTWORK")
    spellIconTex:SetSize(28, 28)
    spellIconTex:SetPoint("LEFT", spellIDBox, "RIGHT", 8, 0)
    spellIconTex:Hide()

    -- Threshold
    local thresholdLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    thresholdLabel:SetPoint("TOPLEFT", spellIDBox, "BOTTOMLEFT", 0, -10)

    local thresholdBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    thresholdBox:SetSize(160, 24)
    thresholdBox:SetPoint("TOPLEFT", thresholdLabel, "BOTTOMLEFT", 0, -4)
    thresholdBox:SetAutoFocus(false)
    thresholdBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- ---- Font Size (left) + Font Color swatch (right) on the same row ----

    local fontSizeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontSizeLabel:SetPoint("TOPLEFT", thresholdBox, "BOTTOMLEFT", 0, -10)
    fontSizeLabel:SetText("Font Size:")

    local fontSizeBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    fontSizeBox:SetSize(80, 24)
    fontSizeBox:SetPoint("TOPLEFT", fontSizeLabel, "BOTTOMLEFT", 0, -4)
    fontSizeBox:SetAutoFocus(false)
    fontSizeBox:SetNumeric(true)
    fontSizeBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Color label (same top as fontSizeLabel, offset right)
    local colorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorLabel:SetPoint("TOPLEFT", fontSizeLabel, "TOPLEFT", 130, 0)
    colorLabel:SetText("Font Color:")

    -- Clickable color swatch
    local colorSwatch = CreateFrame("Button", nil, panel)
    colorSwatch:SetSize(30, 24)
    colorSwatch:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -4)

    local swatchBorder = colorSwatch:CreateTexture(nil, "BACKGROUND")
    swatchBorder:SetAllPoints(colorSwatch)
    swatchBorder:SetColorTexture(0.55, 0.55, 0.55, 1)

    local colorSwatchFill = colorSwatch:CreateTexture(nil, "ARTWORK")
    colorSwatchFill:SetPoint("TOPLEFT",     colorSwatch, "TOPLEFT",     1, -1)
    colorSwatchFill:SetPoint("BOTTOMRIGHT", colorSwatch, "BOTTOMRIGHT", -1,  1)
    colorSwatchFill:SetColorTexture(1, 1, 1)

    local swatchHighlight = colorSwatch:CreateTexture(nil, "HIGHLIGHT")
    swatchHighlight:SetAllPoints(colorSwatch)
    swatchHighlight:SetColorTexture(1, 1, 1, 0.15)

    -- ---- Message + Preview ----

    local messageLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    messageLabel:SetPoint("TOPLEFT", fontSizeBox, "BOTTOMLEFT", 0, -10)
    messageLabel:SetText("Message Template:")

    local messageBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    messageBox:SetSize(358, 24)
    messageBox:SetPoint("TOPLEFT", messageLabel, "BOTTOMLEFT", 0, -4)
    messageBox:SetAutoFocus(false)
    messageBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local previewLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    previewLabel:SetPoint("TOPLEFT", messageBox, "BOTTOMLEFT", 0, -10)
    previewLabel:SetText("Preview:")
    previewLabel:SetTextColor(0.65, 0.65, 0.65)

    local previewText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    previewText:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", 2, -4)
    previewText:SetWidth(358)
    previewText:SetJustifyH("LEFT")
    previewText:SetText("|cFF888888(no message)|r")

    -- Save / Cancel
    local saveBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    saveBtn:SetSize(80, 26)
    saveBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 12)
    saveBtn:SetText("Save")

    local cancelBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 26)
    cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)
    cancelBtn:SetText("Cancel")

    -- ----------------------------------------
    -- State
    -- ----------------------------------------
    local rowPool     = {}
    local editorState = {
        ruleIndex = nil,
        ruleType  = "cooldown",
        colorR    = 1,
        colorG    = 1,
        colorB    = 1,
    }

    local OpenEditor  -- forward declare

    -- ----------------------------------------
    -- Helpers
    -- ----------------------------------------
    local function UpdateColorSwatch()
        colorSwatchFill:SetColorTexture(editorState.colorR, editorState.colorG, editorState.colorB)
    end

    local function RefreshSpellIcon()
        local sid = tonumber(spellIDBox:GetText())
        if sid and sid > 0 then
            local info = C_Spell.GetSpellInfo(sid)
            if info and info.iconID then
                spellIconTex:SetTexture(info.iconID)
                spellIconTex:Show()
                return
            end
        end
        spellIconTex:Hide()
    end

    local function RefreshPreview()
        local msg  = messageBox:GetText()
        local size = tonumber(fontSizeBox:GetText()) or 20
        previewText:SetFont(WOW_FONT, size, "OUTLINE")
        previewText:SetTextColor(editorState.colorR, editorState.colorG, editorState.colorB)
        if msg and msg ~= "" then
            previewText:SetText(CA.ParseCustomAlertText(msg, size))
        else
            previewText:SetText("|cFF888888(no message)|r")
        end
    end

    local function UpdateTypeUI()
        typeCycleBtn:SetText("< " .. TYPE_LABELS[editorState.ruleType] .. " >")
        if editorState.ruleType == "charges" then
            thresholdLabel:Hide()
            thresholdBox:Hide()
        else
            thresholdLabel:Show()
            thresholdBox:Show()
            thresholdLabel:SetText(THRESHOLD_LABELS[editorState.ruleType])
        end
    end

    -- ----------------------------------------
    -- RefreshRuleList
    -- ----------------------------------------
    local function RefreshRuleList()
        for _, row in ipairs(rowPool) do
            row:Hide()
        end

        local rules = CoreAlertsDB.rules
        local ROW_H = 32

        for i, rule in ipairs(rules) do
            local row = rowPool[i]
            if not row then
                row = CreateFrame("Frame", nil, listContent)
                row:SetHeight(ROW_H)
                row:SetWidth(listContent:GetWidth())

                row.bg = row:CreateTexture(nil, "BACKGROUND")
                row.bg:SetAllPoints(row)
                row.bg:SetColorTexture(0.08, 0.08, 0.08, 0.55)

                row.badge = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.badge:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.badge:SetWidth(62)
                row.badge:SetJustifyH("LEFT")

                row.spellLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.spellLabel:SetPoint("LEFT", row.badge, "RIGHT", 6, 0)
                row.spellLabel:SetWidth(174)
                row.spellLabel:SetJustifyH("LEFT")

                row.colorDot = row:CreateTexture(nil, "ARTWORK")
                row.colorDot:SetSize(10, 10)
                row.colorDot:SetPoint("RIGHT", row, "RIGHT", -122, 0)

                row.editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.editBtn:SetSize(50, 20)
                row.editBtn:SetText("Edit")
                row.editBtn:SetPoint("RIGHT", row, "RIGHT", -62, 0)

                row.deleteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.deleteBtn:SetSize(54, 20)
                row.deleteBtn:SetText("Delete")
                row.deleteBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)

                rowPool[i] = row
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -(i - 1) * ROW_H)
            row:Show()

            local c = TYPE_COLORS[rule.type] or { 1, 1, 1 }
            row.badge:SetTextColor(c[1], c[2], c[3])
            row.badge:SetText(TYPE_LABELS[rule.type] or rule.type)

            local spellInfo = rule.spellID and C_Spell.GetSpellInfo(rule.spellID)
            if spellInfo and spellInfo.name then
                row.spellLabel:SetText(spellInfo.name .. " (" .. rule.spellID .. ")")
            else
                row.spellLabel:SetText(tostring(rule.spellID or "?"))
            end

            row.colorDot:SetColorTexture(rule.colorR or 1, rule.colorG or 1, rule.colorB or 1)

            local idx = i
            row.editBtn:SetScript("OnClick",   function() OpenEditor(idx) end)
            row.deleteBtn:SetScript("OnClick", function()
                table.remove(CoreAlertsDB.rules, idx)
                CA.RebuildAlertPool()
                CA.RefreshCache()
                RefreshRuleList()
            end)
        end

        listContent:SetHeight(math.max(1, #rules * ROW_H))
        scrollFrame:SetVerticalScroll(0)
    end

    -- ----------------------------------------
    -- Editor open / close / save
    -- ----------------------------------------
    local function CloseEditor()
        overlay:Hide()
        spellIDBox:ClearFocus()
        thresholdBox:ClearFocus()
        fontSizeBox:ClearFocus()
        messageBox:ClearFocus()
    end

    OpenEditor = function(ruleIndex)
        editorState.ruleIndex = ruleIndex
        local rule = ruleIndex and CoreAlertsDB.rules[ruleIndex]

        if rule then
            editorState.ruleType = rule.type or "cooldown"
            editorState.colorR   = rule.colorR or 1
            editorState.colorG   = rule.colorG or 1
            editorState.colorB   = rule.colorB or 1
            spellIDBox:SetText(tostring(rule.spellID or ""))
            thresholdBox:SetText(tostring(rule.threshold or ""))
            fontSizeBox:SetText(tostring(rule.fontSize or 20))
            messageBox:SetText(rule.message or "")
            combatOnlyCheck:SetChecked(rule.combatOnly or false)
            panel.TitleText:SetText("Edit Rule")
        else
            editorState.ruleType = "cooldown"
            editorState.colorR, editorState.colorG, editorState.colorB = 1, 1, 1
            spellIDBox:SetText("")
            thresholdBox:SetText("")
            fontSizeBox:SetText("20")
            messageBox:SetText("")
            combatOnlyCheck:SetChecked(false)
            panel.TitleText:SetText("New Rule")
        end

        UpdateTypeUI()
        UpdateColorSwatch()
        RefreshSpellIcon()
        RefreshPreview()
        overlay:Show()
        spellIDBox:SetFocus()
    end

    local function SaveEditor()
        local spellID   = tonumber(spellIDBox:GetText())
        local threshold = tonumber(thresholdBox:GetText())
        local fontSize  = tonumber(fontSizeBox:GetText()) or 20
        local message   = messageBox:GetText()

        if not spellID or spellID <= 0 then
            spellIDBox:SetTextColor(1, 0.2, 0.2)
            C_Timer.After(1, function() spellIDBox:SetTextColor(1, 1, 1) end)
            return
        end

        local newRule = {
            type       = editorState.ruleType,
            spellID    = spellID,
            threshold  = threshold or 0,
            fontSize   = math.max(8, math.min(72, fontSize)),
            colorR     = editorState.colorR,
            colorG     = editorState.colorG,
            colorB     = editorState.colorB,
            message    = message,
            combatOnly = combatOnlyCheck:GetChecked() and true or false,
        }

        if editorState.ruleIndex then
            CoreAlertsDB.rules[editorState.ruleIndex] = newRule
        else
            table.insert(CoreAlertsDB.rules, newRule)
        end

        CA.RebuildAlertPool()
        CA.RefreshCache()
        CloseEditor()
        RefreshRuleList()
    end

    -- ----------------------------------------
    -- Script wiring
    -- ----------------------------------------
    typeCycleBtn:SetScript("OnClick", function()
        local idx = 1
        for i, t in ipairs(TYPE_ORDER) do
            if t == editorState.ruleType then idx = i; break end
        end
        editorState.ruleType = TYPE_ORDER[(idx % #TYPE_ORDER) + 1]
        UpdateTypeUI()
    end)

    colorSwatch:SetScript("OnClick", function()
        local prevR, prevG, prevB = editorState.colorR, editorState.colorG, editorState.colorB
        ColorPickerFrame:SetupColorPickerAndShow({
            r          = editorState.colorR,
            g          = editorState.colorG,
            b          = editorState.colorB,
            hasOpacity = false,
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                editorState.colorR, editorState.colorG, editorState.colorB = r, g, b
                UpdateColorSwatch()
                RefreshPreview()
            end,
            cancelFunc = function()
                editorState.colorR, editorState.colorG, editorState.colorB = prevR, prevG, prevB
                UpdateColorSwatch()
                RefreshPreview()
            end,
        })
    end)

    spellIDBox:SetScript("OnTextChanged",  RefreshSpellIcon)
    fontSizeBox:SetScript("OnTextChanged", RefreshPreview)
    messageBox:SetScript("OnTextChanged",  RefreshPreview)

    saveBtn:SetScript("OnClick",   SaveEditor)
    cancelBtn:SetScript("OnClick", CloseEditor)
    panel.CloseButton:SetScript("OnClick", CloseEditor)
    addBtn:SetScript("OnClick", function() OpenEditor(nil) end)

    win:SetScript("OnShow", function()
        ApplyAnchorPosition()
        anchorFrame:Show()
        RefreshRuleList()
    end)
    win:SetScript("OnHide", function()
        anchorFrame:Hide()
    end)
end

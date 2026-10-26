-- Field Health: section of the game settings page (ESC > Settings > Game).
-- The rows are copies of a vanilla option row; only the admin can change them.
FHSettingsPage = {}

local function find(element, test)
    if element == nil then
        return nil
    end
    if test(element) then
        return element
    end
    for _, child in ipairs(element.elements or {}) do
        local found = find(child, test)
        if found ~= nil then
            return found
        end
    end
    return nil
end

local function isOption(element)
    return MultiTextOptionElement ~= nil and element.isa ~= nil and element:isa(MultiTextOptionElement)
end

-- Copies keep the focus data of their template; it is cleared so the focus
-- manager treats them as new elements.
local function clearFocus(element)
    element.focusId = nil
    element.focusChangeData = {}
    element.focusActive = false
    element.isAlwaysFocusedOnOpen = false
    for _, child in ipairs(element.elements or {}) do
        clearFocus(child)
    end
end

-- The description below an option is a text element inside the option.
local function setDescription(option, text)
    option.toolTipText = text
    for _, child in ipairs(option.elements or {}) do
        if child.typeName == "Text" and child ~= option.labelElement and child ~= option.textElement and child.setText ~= nil then
            child:setText(text)
            return
        end
    end
end

local function bind(option, name)
    option.onClickCallback = function(_, state)
        if type(state) ~= "number" then
            state = option:getState()
        end
        FHSettings.select(name, state)
    end
end

function FHSettingsPage:build()
    local page = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
    local layout = page ~= nil and page.gameSettingsLayout or nil
    if layout == nil then
        return false
    end

    -- the menu outlives a game session: rows made before are used again
    if layout.fieldHealthOptions ~= nil then
        self.options = layout.fieldHealthOptions
        for name, option in pairs(self.options) do
            bind(option, name)
        end
        return true
    end

    local headerTemplate, rowTemplate = nil, nil
    for _, element in ipairs(layout.elements) do
        if headerTemplate == nil and element.name == "sectionHeader" then
            headerTemplate = element
        end
        if rowTemplate == nil and element.typeName == "Bitmap" and find(element, isOption) ~= nil then
            rowTemplate = element
        end
    end
    if headerTemplate == nil or rowTemplate == nil then
        return false
    end

    local header = headerTemplate:clone(layout)
    header:setText(FHUtil.text("fh_settings_header"))
    clearFocus(header)

    local options = {}
    for _, setting in ipairs(FHSettings.OPTIONS) do
        local row = rowTemplate:clone(layout)
        clearFocus(row)
        row.id = nil
        local option = find(row, isOption)
        for _, element in ipairs(row.elements or {}) do
            element.id = nil
            if element ~= option and element.typeName == "Text" then
                element:setText(FHUtil.text("fh_setting_" .. setting.name))
            end
        end
        option.id = "fieldHealth_" .. setting.name
        setDescription(option, FHUtil.text("fh_setting_" .. setting.name .. "_desc"))
        bind(option, setting.name)
        options[setting.name] = option

        if FocusManager ~= nil and FocusManager.loadElementFromCustomValues ~= nil then
            FocusManager:loadElementFromCustomValues(row, nil, {}, false, false)
        end
    end

    layout:invalidateLayout()
    layout.fieldHealthOptions = options
    self.options = options
    return true
end

-- Texts, states and the admin lock of the rows.
function FHSettingsPage:refresh()
    if self.options == nil then
        return
    end
    local editable = FHSettings.canEdit()
    for _, setting in ipairs(FHSettings.OPTIONS) do
        local option = self.options[setting.name]
        if option ~= nil then
            option:setTexts(FHSettings.getLabels(setting))
            option:setState(FHSettings.getIndex(setting.name))
            if option.setDisabled ~= nil then
                option:setDisabled(not editable)
            end
        end
    end
end

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
    FHUtil.protect("settings page", function()
        if FHSettingsPage.options ~= nil or FHSettingsPage:build() then
            FHSettingsPage:refresh()
        end
    end)
end)

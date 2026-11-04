-- Field Health: a tab of its own in ESC > Settings, next to the tabs of the
-- game. Every player sees the settings; only the admin can change them (the
-- "Game" tab of the game is hidden from players without admin rights, which
-- hid the settings on dedicated servers before 1.3).
FHSettingsPage = {}

FHSettingsPage.GUI_FILE = "xml/settingsPage.xml"
FHSettingsPage.GUI_NAME = "FieldHealthSettings"
FHSettingsPage.SUB_CATEGORY = "FIELD_HEALTH"
FHSettingsPage.HEADER_ICON = "gui.icon_options_generalSettings2"
-- the header of the menu is looked up by the game, so the title is also
-- registered as a text of the game; without that the game's own title is used
FHSettingsPage.HEADER_TEXT = "fieldHealth_settingsTitle"

-- Receives the clicks of the loaded tab.
local Controller = {}
local Controller_mt = Class(Controller, FrameElement)

function Controller.new()
    return FrameElement.new(nil, Controller_mt)
end

function Controller:onClickTab()
    FHSettingsPage:select()
end

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

-- Copies keep the ids and focus data of their template; both are cleared so
-- the game treats them as new elements.
local function clearCopy(element)
    element.id = nil
    element.focusId = nil
    element.focusChangeData = {}
    element.focusActive = false
    element.isAlwaysFocusedOnOpen = false
    for _, child in ipairs(element.elements or {}) do
        clearCopy(child)
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

local function moveTo(element, parent)
    if element.parent ~= nil and element.parent.removeElement ~= nil then
        element.parent:removeElement(element)
    end
    table.insert(parent.elements, element)
    element.parent = parent
end

local function removeTemplate(element)
    if element ~= nil and element.parent ~= nil and element.parent.removeElement ~= nil then
        element.parent:removeElement(element)
    end
    if element ~= nil and element.delete ~= nil then
        element:delete()
    end
end

-- Registers a text in the game's own text table (the menu header reads it
-- there). Mods see a copy of the global table; the game's one is behind it.
local function setGameText(key, text)
    local meta = getmetatable(_G)
    local game = meta ~= nil and type(meta.__index) == "table" and meta.__index or nil
    local i18n = game ~= nil and game.g_i18n or nil
    if i18n == nil or i18n.setText == nil then
        return false
    end
    i18n:setText(key, text)
    return true
end

-- Puts the tab and its page into the settings menu, once per menu.
function FHSettingsPage:install()
    local frame = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
    if frame == nil or frame.subCategoryPages == nil or frame.subCategoryTabs == nil or frame.subCategoryBox == nil
        or frame.subCategoryPages[1] == nil or frame.subCategoryPages[1].parent == nil then
        return false
    end
    -- the menu can outlive a game session: a tab added before is used again
    -- (and a tab that failed half way is never added twice)
    local saved = frame.fieldHealthSettings
    if saved ~= nil then
        if saved.options == nil then
            return false
        end
        self.frame, self.options, self.adminNote, self.layout = frame, saved.options, saved.adminNote, saved.layout
        for name, option in pairs(self.options) do
            bind(option, name)
        end
        return true
    end
    -- a GUI file that could not be loaded is not tried again on every opening
    if self.loadFailed then
        return false
    end

    local controller = Controller.new()
    g_gui:loadGui(Utils.getFilename(FHSettingsPage.GUI_FILE, FHUtil.MOD_DIRECTORY), FHSettingsPage.GUI_NAME, controller)
    local loaded = g_gui.guis ~= nil and g_gui.guis[FHSettingsPage.GUI_NAME] or nil
    if loaded ~= nil and loaded.target ~= nil then
        controller = loaded.target
    end
    local tab, page, layout = controller.fieldHealthTab, controller.fieldHealthPage, controller.fieldHealthLayout
    if tab == nil or page == nil or layout == nil or controller.fieldHealthHeaderTemplate == nil or controller.fieldHealthRowTemplate == nil then
        self.loadFailed = true
        return false
    end
    frame.fieldHealthSettings = {}

    -- the new tab comes last, so the tabs of the game and other mods keep their numbers
    local position = #frame.subCategoryTabs + 1
    moveTo(page, frame.subCategoryPages[1].parent)
    moveTo(tab, frame.subCategoryBox)
    frame.subCategoryPages[position] = page
    frame.subCategoryTabs[position] = tab
    tab:setTarget(frame, controller)
    page:setTarget(frame, controller)

    InGameMenuSettingsFrame.SUB_CATEGORY[FHSettingsPage.SUB_CATEGORY] = position
    if InGameMenuSettingsFrame.HEADER_SLICES ~= nil then
        InGameMenuSettingsFrame.HEADER_SLICES[position] = FHSettingsPage.HEADER_ICON
    end
    if InGameMenuSettingsFrame.HEADER_TITLES ~= nil then
        -- without an own text the title of the game's first tab, a key that exists
        local own = setGameText(FHSettingsPage.HEADER_TEXT, FHUtil.text("fh_settings_tab"))
        InGameMenuSettingsFrame.HEADER_TITLES[position] = own and FHSettingsPage.HEADER_TEXT or InGameMenuSettingsFrame.HEADER_TITLES[1]
    end
    self:updatePaging(frame, position)

    self:fill(controller, layout)
    removeTemplate(controller.fieldHealthRowTemplate)
    removeTemplate(controller.fieldHealthHeaderTemplate)
    layout:invalidateLayout()
    frame.subCategoryBox:invalidateLayout()
    if frame.updateAbsolutePosition ~= nil then
        frame:updateAbsolutePosition()
    end
    self:registerFocus(frame, page, tab)

    self.frame, self.layout = frame, layout
    frame.fieldHealthSettings.options, frame.fieldHealthSettings.adminNote, frame.fieldHealthSettings.layout = self.options, self.adminNote, layout
    self:fitTabs(frame)
    return true
end

-- The row of tabs is centred and does not wrap: with the tabs of several mods
-- it grows past the menu. Then the texts of all tabs get smaller by the same
-- factor until the row fits; with room enough they keep their own size. Each
-- tab's background is made as wide as the tab again (its width is set once
-- when the tab is loaded).
FHSettingsPage.MIN_TAB_TEXT = 0.6

function FHSettingsPage:fitTabs(frame)
    local box = frame.subCategoryBox
    if box == nil or box.absSize == nil or box.invalidateLayout == nil then
        return
    end
    local tabs = {}
    for _, tab in ipairs(frame.subCategoryTabs) do
        if tab.setTextSize ~= nil and tab.textSize ~= nil then
            tab.fieldHealthTextSize = tab.fieldHealthTextSize or tab.textSize
            tabs[#tabs + 1] = tab
        end
    end
    -- the margins of the tabs do not shrink, so a few steps with a little room to spare
    local scale = 1
    for _ = 1, 8 do
        for _, tab in ipairs(tabs) do
            if tab.textSize ~= tab.fieldHealthTextSize * scale then
                tab:setTextSize(tab.fieldHealthTextSize * scale)
            end
        end
        box:invalidateLayout()
        local width, available = box.maxFlowSize or 0, box.absSize[1]
        if width <= available or scale <= FHSettingsPage.MIN_TAB_TEXT then
            break
        end
        scale = math.max(FHSettingsPage.MIN_TAB_TEXT, scale * available / width * 0.98)
    end
    for _, tab in ipairs(frame.subCategoryTabs) do
        local background = find(tab, function(element) return element ~= tab and element.name == "background" end)
        if background ~= nil and background.setSize ~= nil and tab.absSize ~= nil then
            background:setSize(tab.absSize[1])
        end
    end
    box:invalidateLayout()
    self.fittedTabs = #frame.subCategoryTabs
end

-- The page selector of the menu lists the numbers of the visible tabs; its
-- state is the place in that list, not the number of the tab (hidden tabs,
-- or tabs of other mods added in between, make them differ).
function FHSettingsPage.getPagingState(frame, position)
    local paging = frame ~= nil and frame.subCategoryPaging or nil
    for state, text in ipairs(paging ~= nil and paging.texts or {}) do
        if tonumber(text) == position then
            return state
        end
    end
    return nil
end

function FHSettingsPage:updatePaging(frame, position)
    if frame.updateSubCategoryPages ~= nil then
        frame:updateSubCategoryPages()
    end
    local paging = frame.subCategoryPaging
    if paging == nil or paging.texts == nil or FHSettingsPage.getPagingState(frame, position) ~= nil then
        return
    end
    local texts = paging.texts
    table.insert(texts, tostring(position))
    paging:setTexts(texts)
end

function FHSettingsPage:registerFocus(frame, page, tab)
    if FocusManager == nil or FocusManager.setGui == nil then
        return
    end
    local current = FocusManager.currentGui
    FocusManager:setGui(frame.name)
    for _, element in ipairs({page, tab}) do
        FocusManager:removeElement(element)
        FocusManager:loadElementFromCustomValues(element)
    end
    FocusManager:setGui(current)
end

-- One header per section and one row per setting.
function FHSettingsPage:fill(controller, layout)
    local headerTemplate, rowTemplate = controller.fieldHealthHeaderTemplate, controller.fieldHealthRowTemplate

    -- shown on top when the player may not change the settings
    self.adminNote = headerTemplate:clone(layout)
    clearCopy(self.adminNote)
    self.adminNote:setText(FHUtil.text("fh_settings_adminOnly"))

    self.options = {}
    for _, section in ipairs(FHSettings.SECTIONS) do
        local header = headerTemplate:clone(layout)
        clearCopy(header)
        header:setText(FHUtil.text("fh_settings_section_" .. section))
        for _, setting in ipairs(FHSettings.OPTIONS) do
            if setting.section == section then
                local row = rowTemplate:clone(layout)
                clearCopy(row)
                local option = find(row, isOption)
                local title = find(row, function(element) return element.name == "title" end)
                if option ~= nil and title ~= nil then
                    title:setText(FHUtil.text("fh_setting_" .. setting.name))
                    option.id = "fieldHealth_" .. setting.name
                    setDescription(option, FHUtil.text("fh_setting_" .. setting.name .. "_desc"))
                    bind(option, setting.name)
                    self.options[setting.name] = option
                end
            end
        end
    end
end

-- Shows the tab of the mod (click on it).
function FHSettingsPage:select()
    local frame = self.frame
    local position = InGameMenuSettingsFrame.SUB_CATEGORY[FHSettingsPage.SUB_CATEGORY]
    if frame == nil or position == nil or frame.subCategoryPaging == nil then
        return
    end
    -- the page list may have been rebuilt since: the entry of the tab is
    -- added again if it went missing
    local state = FHSettingsPage.getPagingState(frame, position)
    if state == nil then
        self:updatePaging(frame, position)
        state = FHSettingsPage.getPagingState(frame, position)
    end
    frame.subCategoryPaging:setState(state or position, true)
end

-- Texts, states, the admin lock and the row colours.
function FHSettingsPage:refresh()
    if self.options == nil then
        return
    end
    local editable = FHSettings.canEdit()
    self.editable = editable
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
    if self.adminNote ~= nil and self.adminNote.setVisible ~= nil then
        self.adminNote:setVisible(not editable)
    end
    self:colourRows()
end

-- Every second row darker, starting again after each header (as in the game).
function FHSettingsPage:colourRows()
    local colours = InGameMenuSettingsFrame.COLOR_ALTERNATING
    if self.layout == nil or colours == nil then
        return
    end
    local alternate = true
    for _, element in ipairs(self.layout.elements or {}) do
        if element.name == "sectionHeader" then
            alternate = true
        elseif element.setImageColor ~= nil and colours[alternate] ~= nil then
            element:setImageColor(nil, unpack(colours[alternate]))
            alternate = not alternate
        end
    end
    self.layout:invalidateLayout()
end

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
    FHUtil.protect("settings page", function()
        if FHSettingsPage.options ~= nil or FHSettingsPage:install() then
            FHSettingsPage:refresh()
            FHSettingsPage:fitTabs(FHSettingsPage.frame)
        end
    end)
end)

-- while the menu is open: other mods may add their tab later, and a player
-- may log in as admin (the rows are unlocked at once)
InGameMenuSettingsFrame.update = Utils.appendedFunction(InGameMenuSettingsFrame.update, function(frame)
    local own = FHSettingsPage.frame
    if own == nil or frame ~= own then
        return
    end
    if own.subCategoryTabs ~= nil and #own.subCategoryTabs ~= FHSettingsPage.fittedTabs then
        FHUtil.protect("settings page", FHSettingsPage.fitTabs, FHSettingsPage, own)
    end
    if FHSettingsPage.options ~= nil and FHSettings.canEdit() ~= FHSettingsPage.editable then
        FHUtil.protect("settings page", FHSettingsPage.refresh, FHSettingsPage)
    end
end)

-- Field Health: "Crop protection" page of the in-game map (ESC > Map). The
-- page has its own layer selector (a copy of the page selector with its own
-- page dots) above the legend; the five layers of FHMapLayers are its
-- sub-pages. Other mods (e.g. Precision Farming) also add pages and may
-- change the legend list, so the legend of the shown layer is set again
-- whenever the page or the layer is selected.
FHMapPage = {}

FHMapPage.REFRESH_INTERVAL = 1000
-- layout on our page (pixels): the layer selector and its dots below the
-- page selector, the legend moved down to make room, its button raised
FHMapPage.SELECTOR_SHIFT = 80
FHMapPage.DOTS_SHIFT = 75
FHMapPage.LEGEND_SHIFT = 60
FHMapPage.BUTTON_RAISE = 16

FHMapPage.overlay = FHMapLayers.newOverlay("fieldHealthMap")
FHMapPage.layerIndex = 1
FHMapPage.refreshTimer = 0

local function pixelsY(pixels)
    local _, y = getNormalizedScreenValues(0, pixels)
    return y
end

-- Parts created on the map frame; the menu outlives a game session.
local function ui(frame)
    return frame ~= nil and frame.fieldHealthUi or nil
end

function FHMapPage.isShown(frame)
    local parts = ui(frame)
    return parts ~= nil and frame.mapOverviewSelector:getState() == parts.page
end

function FHMapPage.getLayer()
    return FHMapLayers.LIST[FHMapPage.layerIndex]
end

---------------------------------------------------------------------------
-- Building the page
---------------------------------------------------------------------------

-- Page dots: one per entry, the selected one follows the selector.
local function setupDots(dots, count, selector)
    while #dots.elements < count do
        dots:addElement(dots.elements[1]:clone(dots))
    end
    while #dots.elements > count do
        dots.elements[#dots.elements]:delete()
    end
    for i, dot in ipairs(dots.elements) do
        dot.getIsSelected = function()
            return selector:getState() == i
        end
    end
    dots:invalidateLayout()
end

function FHMapPage.addPage(frame)
    if ui(frame) ~= nil or frame.mapSelectorTexts == nil then
        return
    end

    table.insert(frame.mapSelectorTexts, FHUtil.text("fh_map_page"))
    local page = #frame.mapSelectorTexts
    frame.mapOverviewSelector:setTexts(frame.mapSelectorTexts)
    frame.dataTables[page] = {}
    frame.filterStates[page] = {}
    frame.numSelectedFilters[page] = 0

    -- a dot for the new page under the page selector
    local pageDots = frame.subCategoryDotBox
    pageDots:addElement(pageDots.elements[1]:clone(pageDots))
    setupDots(pageDots, #pageDots.elements, frame.mapOverviewSelector)

    -- the layer selector: a copy of the page selector above the legend
    local titles = {}
    for i, layer in ipairs(FHMapLayers.LIST) do
        titles[i] = layer:getTitle()
    end
    local selector = frame.mapOverviewSelector:clone(frame.filterBox)
    selector:setTexts(titles)
    selector.onClickCallback = function(_, state)
        FHUtil.protect("map page", FHMapPage.selectLayer, frame, state)
    end
    selector:addDefaultElements()
    local layerDots = frame.subCategoryDotBox:clone(frame.filterBox)
    setupDots(layerDots, #titles, selector)

    -- the original layout of the legend, restored on other pages
    local slider = frame.filterListSlider
    local parts = {
        page = page,
        selector = selector,
        dots = layerDots,
        base = {
            selectorY = selector.position[2],
            dotsY = layerDots.position[2],
            legendY = frame.filterListContainer.position[2],
            legendHeight = frame.filterListContainer.size[2],
            listHeight = frame.filterList.size[2],
            sliderHeight = slider.size[2],
            sliderBarHeight = slider.elements[1].size[2],
            buttonY = frame.buttonDeselectAllContainer.position[2]
        },
        shifted = false
    }
    selector:setVisible(false)
    layerDots:setVisible(false)
    frame.fieldHealthUi = parts
    frame.filterList:reloadData()
end

-- The GUI keeps the functions it was given when it was loaded, before this
-- mod's hooks existed; they are handed over again.
function FHMapPage.bindCallbacks(frame)
    frame.mapOverviewSelector.onClickCallback = function(_, state)
        frame:onClickMapOverviewSelector(state)
    end
    frame.ingameMap.onDrawPostIngameMapCallback = InGameMenuMapFrame.onDrawPostIngameMap
    frame.ingameMap.onDrawPostIngameMapHotspotsCallback = InGameMenuMapFrame.onDrawPostIngameMapHotspots
    frame.ingameMap.onClickMapCallback = InGameMenuMapFrame.onClickMap
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

-- Places the layer selector and moves the legend down (kept every frame,
-- because the menu may reset positions).
function FHMapPage.shiftLayout(frame)
    local parts = ui(frame)
    local base = parts.base
    local legendShift = pixelsY(FHMapPage.LEGEND_SHIFT)
    parts.selector:setPosition(nil, base.selectorY - pixelsY(FHMapPage.SELECTOR_SHIFT))
    parts.dots:setPosition(nil, base.dotsY - pixelsY(FHMapPage.DOTS_SHIFT))
    frame.filterListContainer:setPosition(nil, base.legendY - legendShift)
    frame.filterListContainer:setSize(nil, base.legendHeight - legendShift, true)
    frame.filterList:setSize(nil, base.listHeight - legendShift, true)
    frame.filterListSlider:setSize(nil, base.sliderHeight - legendShift, true)
    frame.filterListSlider.elements[1]:setSize(nil, base.sliderBarHeight - legendShift, true)
    frame.buttonDeselectAllContainer:setPosition(nil, base.buttonY + pixelsY(FHMapPage.BUTTON_RAISE))
    parts.shifted = true
end

-- Puts the legend back; only our own change is undone, so pages of other
-- mods keep their layout.
function FHMapPage.restoreLayout(frame)
    local parts = ui(frame)
    if parts == nil or not parts.shifted then
        return
    end
    local base = parts.base
    frame.filterListContainer:setPosition(nil, base.legendY)
    frame.filterListContainer:setSize(nil, base.legendHeight, true)
    frame.filterList:setSize(nil, base.listHeight, true)
    frame.filterListSlider:setSize(nil, base.sliderHeight, true)
    frame.filterListSlider.elements[1]:setSize(nil, base.sliderBarHeight, true)
    frame.buttonDeselectAllContainer:setPosition(nil, base.buttonY)
    parts.shifted = false
end

---------------------------------------------------------------------------
-- Layers
---------------------------------------------------------------------------

-- Legend data of the shown layer for the menu's legend list.
function FHMapPage.setLegend(frame)
    local parts = ui(frame)
    local layer = FHMapPage.getLayer()
    local count = layer:countVisible()
    frame.dataTables[parts.page] = layer:getLegendRows()
    frame.filterStates[parts.page] = layer.filter
    frame.numSelectedFilters[parts.page] = count
    if frame.buttonDeselectAllText ~= nil and InGameMenuMapFrame.L10N_SYMBOL ~= nil then
        local symbol = count == 0 and InGameMenuMapFrame.L10N_SYMBOL.SELECT_ALL or InGameMenuMapFrame.L10N_SYMBOL.DESELECT_ALL
        frame.buttonDeselectAllText:setText(g_i18n:getText(symbol))
    end
end

function FHMapPage.selectLayer(frame, index)
    if FHMapLayers.LIST[index] ~= nil then
        FHMapPage.layerIndex = index
    end
    FHMapPage.setLegend(frame)
    frame.filterList:reloadData()
    FHMapPage.overlay:show(FHMapPage.getLayer())
    FHMapPage.refreshTimer = 0
end

-- Called when the map frame selects a page.
function FHMapPage.onPageSelected(frame, state)
    local parts = ui(frame)
    if parts == nil then
        return
    end
    local shown = state == parts.page
    parts.selector:setVisible(shown)
    parts.dots:setVisible(shown)
    if shown then
        frame.filterListContainer:setVisible(true)
        frame.buttonDeselectAllContainer:setVisible(true)
        FHMapPage.shiftLayout(frame)
        FHMapPage.selectLayer(frame, parts.selector:getState())
    else
        FHMapPage.restoreLayout(frame)
    end
end

-- The overlay covers the terrain, which is only a part of the map image.
function FHMapPage.drawOverlay(frame)
    local overlay = FHMapPage.overlay
    if not overlay:isReady() then
        return
    end
    local map = frame.ingameMapBase
    local width, height = map.fullScreenLayout:getMapSize()
    local x, y = map.fullScreenLayout:getMapPosition()
    local scale = map.mapExtensionScaleFactor or 0.5
    x = x + width * (map.mapExtensionOffsetX or 0.25)
    y = y + height * (map.mapExtensionOffsetZ or 0.25)
    setOverlayUVs(overlay.id, 0, 0, 0, 1, 1, 0, 1, 1)
    setOverlayColor(overlay.id, 1, 1, 1, FHMapLayers.ALPHA)
    renderOverlay(overlay.id, x, y, width * scale, height * scale)
end

function FHMapPage.unload()
    FHMapPage.overlay:delete()
end

---------------------------------------------------------------------------
-- Hooks of the map frame
---------------------------------------------------------------------------

InGameMenuMapFrame.onLoadMapFinished = Utils.appendedFunction(InGameMenuMapFrame.onLoadMapFinished, function(frame)
    FHUtil.protect("map page", function()
        FHMapPage.frame = frame
        FHMapPage.bindCallbacks(frame)
    end)
end)

InGameMenuMapFrame.setupMapOverview = Utils.appendedFunction(InGameMenuMapFrame.setupMapOverview, function(frame)
    FHUtil.protect("map page", function()
        if ui(frame) == nil then
            FHMapPage.addPage(frame)
            FHMapPage.bindCallbacks(frame)
        end
    end)
end)

InGameMenuMapFrame.onClickMapOverviewSelector = Utils.appendedFunction(InGameMenuMapFrame.onClickMapOverviewSelector, function(frame, state)
    FHUtil.protect("map page", FHMapPage.onPageSelected, frame, state)
end)

-- the legend of our page can be toggled
InGameMenuMapFrame.getHasChangeableFilterList = Utils.overwrittenFunction(InGameMenuMapFrame.getHasChangeableFilterList, function(frame, superFunc, ...)
    return superFunc(frame, ...) or FHMapPage.isShown(frame)
end)

-- after a legend entry was toggled
InGameMenuMapFrame.generateOverviewOverlay = Utils.appendedFunction(InGameMenuMapFrame.generateOverviewOverlay, function(frame)
    if FHMapPage.isShown(frame) then
        FHUtil.protect("map page", function()
            FHMapPage.setLegend(frame)
            FHMapPage.overlay:show(FHMapPage.getLayer())
        end)
    end
end)

-- On our page the map is drawn without the vanilla overview colours, then the layer.
InGameMenuMapFrame.onDrawPostIngameMap = Utils.overwrittenFunction(InGameMenuMapFrame.onDrawPostIngameMap, function(frame, superFunc, element, ingameMap, ...)
    if not FHMapPage.isShown(frame) then
        return superFunc(frame, element, ingameMap, ...)
    end
    local hidden = frame.hideContentOverlay
    frame.hideContentOverlay = true
    superFunc(frame, element, ingameMap, ...)
    frame.hideContentOverlay = hidden
    FHUtil.protect("map page", FHMapPage.drawOverlay, frame)
    if frame.dynamicMapImageLoadingBg ~= nil then
        frame.dynamicMapImageLoadingBg:setVisible(false)
    end
end)

InGameMenuMapFrame.update = Utils.appendedFunction(InGameMenuMapFrame.update, function(frame, dt)
    if not FHMapPage.isShown(frame) then
        return
    end
    FHUtil.protect("map page", FHMapPage.shiftLayout, frame)
    FHMapPage.refreshTimer = FHMapPage.refreshTimer + dt
    if FHMapPage.refreshTimer >= FHMapPage.REFRESH_INTERVAL then
        FHMapPage.refreshTimer = 0
        FHMapPage.overlay:refresh()
    end
end)

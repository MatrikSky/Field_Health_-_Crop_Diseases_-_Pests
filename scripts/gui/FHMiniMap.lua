-- Field Health: layer on the HUD minimap. The key (default Left Alt + \)
-- switches between off, protection, diseases and pests.
FHMiniMap = {}

FHMiniMap.ACTION = "FH_MINIMAP_LAYER"
FHMiniMap.REFRESH_INTERVAL = 1000

FHMiniMap.overlay = FHMapLayers.newOverlay("fieldHealthMiniMap")
FHMiniMap.layerIndex = 0
FHMiniMap.eventIds = {}
FHMiniMap.needsInput = true

function FHMiniMap:load()
    self.layerIndex = 0
    self.refreshTimer = 0
    self.lastContext = nil
    self.needsInput = true
    self.hudHooked = false
    self.drawnAt = -1
end

function FHMiniMap:unload()
    self:removeInput()
    self.overlay:delete()
end

function FHMiniMap:getLayer()
    return FHMapLayers.LIST[self.layerIndex]
end

function FHMiniMap:switchLayer()
    self.layerIndex = (self.layerIndex + 1) % (FHMapLayers.MINIMAP_COUNT + 1)
    local layer = self:getLayer()
    if layer ~= nil then
        self.overlay:show(layer)
    end
end

---------------------------------------------------------------------------
-- Input: the action is registered for walking and driving; it is lost when
-- the input context changes, so it is registered again then.
---------------------------------------------------------------------------

function FHMiniMap:removeInput()
    if g_inputBinding ~= nil then
        for _, eventId in ipairs(self.eventIds) do
            g_inputBinding:removeActionEvent(eventId)
        end
    end
    self.eventIds = {}
    self.needsInput = true
end

function FHMiniMap:addInput()
    self:removeInput()
    local label = FHUtil.text("input_" .. FHMiniMap.ACTION)
    for _, context in ipairs({PlayerInputComponent.INPUT_CONTEXT_NAME or "PLAYER", Vehicle.INPUT_CONTEXT_NAME or "VEHICLE"}) do
        g_inputBinding:beginActionEventsModification(context)
        local _, eventId = g_inputBinding:registerActionEvent(FHMiniMap.ACTION, self, self.switchLayer, false, true, false, true)
        g_inputBinding:endActionEventsModification(true)
        if eventId ~= nil then
            g_inputBinding:setActionEventTextVisibility(eventId, true)
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_VERY_LOW)
            g_inputBinding:setActionEventText(eventId, label)
            self.eventIds[#self.eventIds + 1] = eventId
        end
    end
    self.needsInput = #self.eventIds == 0
end

function FHMiniMap:update(dt)
    if g_dedicatedServer ~= nil or g_inputBinding == nil then
        return
    end
    self:hookHudMap()

    local context = g_inputBinding:getContextName()
    if context ~= self.lastContext then
        self.lastContext = context
        self.needsInput = true
    end
    if self.needsInput then
        self:addInput()
    end

    if self.layerIndex > 0 then
        self.refreshTimer = self.refreshTimer - dt
        if self.refreshTimer <= 0 then
            self.refreshTimer = FHMiniMap.REFRESH_INTERVAL
            self.overlay:refresh()
        end
    end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function hudMap()
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    return hud ~= nil and hud.ingameMap or nil
end

-- Only the small HUD map, not the full screen map or menus.
local function isMinimap(map)
    if map == nil or map ~= hudMap() or map.isFullscreen == true or map.layout == nil then
        return false
    end
    return not (g_gui:getIsGuiVisible() and not g_gui:getIsOverlayGuiVisible())
end

function FHMiniMap:drawOn(map)
    if self.layerIndex == 0 or not isMinimap(map) or not self.overlay:isReady() then
        return
    end
    -- several hooks may call this in one frame
    if self.drawnAt == g_time then
        return
    end
    self.drawnAt = g_time

    local layout = map.layout
    local id = self.overlay.id
    local width, height = layout:getMapSize()
    local x, y = layout:getMapPosition()
    local pivotX, pivotY = layout:getMapPivot()
    local left = x + width * map.mapExtensionOffsetX
    local bottom = y + height * map.mapExtensionOffsetZ
    local sizeX = width * map.mapExtensionScaleFactor
    local sizeY = height * map.mapExtensionScaleFactor
    local pivotOffsetX, pivotOffsetY = pivotX + x - left, pivotY + y - bottom

    local clipped = map.clipX1 ~= nil
    if clipped then
        local u1, v1, u2, v2, u3, v3, u4, v4
        left, bottom, sizeX, sizeY, u1, v1, u2, v2, u3, v3, u4, v4 = Overlay.getClippingUVs(Overlay.DEFAULT_UVS,
            left, bottom, sizeX, sizeY, map.clipX1, map.clipY1, map.clipX2, map.clipY2)
        if u1 == nil then
            return
        end
        setOverlayUVs(id, u1, v1, u2, v2, u3, v3, u4, v4)
    end

    setOverlayRotation(id, layout:getMapRotation(), pivotOffsetX, pivotOffsetY)
    setOverlayColor(id, 1, 1, 1, math.sqrt(layout:getMapAlpha() or 1) * FHMapLayers.ALPHA)
    renderOverlay(id, left, bottom, sizeX, sizeY)
    if clipped then
        setOverlayUVs(id, unpack(Overlay.DEFAULT_UVS))
    end
end

-- Name of the shown layer under the coordinates of the minimap.
function FHMiniMap:drawLabel(map)
    local layer = self:getLayer()
    local layout = map.layout
    if layer == nil or not isMinimap(map) or layout.drawCoordinates == nil then
        return
    end
    local offset = layout.coordOffsetY or 0
    layout.coordOffsetY = offset - (layout.coordinateFontSize or 0.012) * 2.5
    layout:drawCoordinates(layer:getTitle())
    layout.coordOffsetY = offset
end

-- The HUD map exists only during a game, and Courseplay (if installed)
-- replaces the minimap drawing with its own; both are hooked late.
function FHMiniMap:hookHudMap()
    local map = hudMap()
    if not self.hudHooked and map ~= nil and map.drawFields ~= nil then
        map.drawFields = Utils.appendedFunction(map.drawFields, function(m)
            FHMiniMap:drawOn(m)
        end)
        self.hudHooked = true
    end
    if Courseplay ~= nil and Courseplay.drawHudMap ~= nil and not Courseplay.fieldHealthHooked then
        Courseplay.drawHudMap = Utils.prependedFunction(Courseplay.drawHudMap, function(m)
            FHMiniMap:drawOn(m)
        end)
        Courseplay.fieldHealthHooked = true
    end
end

if IngameMap ~= nil then
    if IngameMap.drawFields ~= nil then
        IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, function(map)
            FHMiniMap:drawOn(map)
        end)
    end
    if IngameMap.drawPlayersCoordinates ~= nil then
        IngameMap.drawPlayersCoordinates = Utils.appendedFunction(IngameMap.drawPlayersCoordinates, function(map)
            if FHMiniMap.layerIndex > 0 then
                FHMiniMap:drawLabel(map)
            end
        end)
    end
end

-- action events are cleared when the player enters or leaves a vehicle
for _, class in ipairs({PlayerInputComponent, Vehicle}) do
    if class ~= nil and class.registerActionEvents ~= nil then
        class.registerActionEvents = Utils.appendedFunction(class.registerActionEvents, function()
            FHMiniMap.needsInput = true
        end)
    end
end

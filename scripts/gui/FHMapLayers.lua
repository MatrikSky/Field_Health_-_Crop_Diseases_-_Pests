-- Field Health: map layers. Each layer colours one part of FHDisplayMap and
-- has a legend; the in-game map shows all of them, the minimap the first three.
FHMapLayers = {}

FHMapLayers.RESOLUTION = 1024
FHMapLayers.ALPHA = 0.85
FHMapLayers.MINIMAP_COUNT = 3

FHMapLayers.COLORS = {
    notSprayed = {0.86, 0.17, 0.13, 1},
    oneProduct = {1.00, 0.68, 0.30, 1},
    bothProducts = {0.20, 0.68, 0.27, 1},
    healthy = {0.55, 0.76, 0.47, 1},
    low = {0.99, 0.86, 0.30, 1},
    medium = {0.97, 0.55, 0.16, 1},
    high = {0.84, 0.13, 0.11, 1}
}

local Layer = {}
Layer.__index = Layer

-- legend: list of {value, text, color}; value is the layer value in FHDisplayMap
local function newLayer(title, channel, legend)
    local layer = setmetatable({title = title, channel = FHDisplayMap.LAYERS[channel], legend = legend, filter = {}}, Layer)
    for i = 1, #legend do
        layer.filter[i] = true
    end
    return layer
end

function Layer:getTitle()
    return FHUtil.text(self.title)
end

-- Rows of the legend list in the map menu.
function Layer:getLegendRows()
    if self.rows == nil then
        self.rows = {}
        for i, item in ipairs(self.legend) do
            self.rows[i] = {colors = {[false] = {item.color}, [true] = {item.color}}, description = FHUtil.text(item.text)}
        end
    end
    return self.rows
end

function Layer:countVisible()
    local count = 0
    for i = 1, #self.legend do
        if self.filter[i] then
            count = count + 1
        end
    end
    return count
end

-- Sets the colours of a density map visualization overlay for this layer.
function Layer:paint(overlayId)
    if overlayId == nil or overlayId == 0 then
        return false
    end
    resetDensityMapVisualizationOverlay(overlayId)
    setOverlayColor(overlayId, 1, 1, 1, 1)
    local mapId = self.channel.typeMap and FHDisplayMap.typeMapId or FHDisplayMap.valueMapId
    if mapId == nil then
        return false
    end
    for i, item in ipairs(self.legend) do
        if self.filter[i] then
            setDensityMapVisualizationOverlayStateColor(overlayId, mapId, 0, 0, self.channel.first, self.channel.bits,
                item.value, item.color[1], item.color[2], item.color[3])
        end
    end
    return true
end

local function severityLegend()
    local c = FHMapLayers.COLORS
    return {
        {value = 1, text = "fh_map_healthy", color = c.healthy},
        {value = 2, text = "fh_map_low", color = c.low},
        {value = 3, text = "fh_map_medium", color = c.medium},
        {value = 4, text = "fh_map_high", color = c.high}
    }
end

local function typeLegend(category)
    local legend = {}
    for _, threat in ipairs(FHThreats.ofCategory(category)) do
        legend[#legend + 1] = {value = threat.id, text = threat.key .. "_short", color = threat.color}
    end
    return legend
end

-- The minimap cycles through the first MINIMAP_COUNT layers.
FHMapLayers.LIST = {
    newLayer("fh_map_layerProtection", "protection", {
        {value = 1, text = "fh_map_notSprayed", color = FHMapLayers.COLORS.notSprayed},
        {value = 2, text = "fh_map_oneProduct", color = FHMapLayers.COLORS.oneProduct},
        {value = 3, text = "fh_map_bothProducts", color = FHMapLayers.COLORS.bothProducts}
    }),
    newLayer("fh_map_layerDiseases", "disease", severityLegend()),
    newLayer("fh_map_layerPests", "pest", severityLegend()),
    newLayer("fh_map_layerDiseaseTypes", "threatType", typeLegend("disease")),
    newLayer("fh_map_layerPestTypes", "threatType", typeLegend("pest"))
}

-- An overlay drawn from the display map, regenerated when the map changes.
local Overlay = {}
Overlay.__index = Overlay

function FHMapLayers.newOverlay(name)
    return setmetatable({name = name, id = nil, layer = nil, ready = false, revision = -1}, Overlay)
end

function Overlay:show(layer)
    if self.id == nil then
        self.id = createDensityMapVisualizationOverlay(self.name, FHMapLayers.RESOLUTION, FHMapLayers.RESOLUTION)
    end
    self.layer = layer
    if layer ~= nil and layer:paint(self.id) then
        self:regenerate()
    end
end

function Overlay:regenerate()
    if self.id ~= nil and self.layer ~= nil then
        generateDensityMapVisualizationOverlay(self.id)
        self.ready = false
        self.revision = FHDisplayMap.revision
    end
end

-- Regenerates when the display map changed since the last time.
function Overlay:refresh()
    if self.layer ~= nil and FHDisplayMap.revision ~= self.revision then
        self:regenerate()
    end
end

function Overlay:isReady()
    if not self.ready and self.id ~= nil then
        local generated = getIsDensityMapVisualizationOverlayReady == nil or getIsDensityMapVisualizationOverlayReady(self.id)
        self.ready = generated and (getIsOverlayReady == nil or getIsOverlayReady(self.id))
    end
    return self.ready
end

function Overlay:delete()
    if self.id ~= nil then
        delete(self.id)
    end
    self.id, self.layer, self.ready = nil, nil, false
end

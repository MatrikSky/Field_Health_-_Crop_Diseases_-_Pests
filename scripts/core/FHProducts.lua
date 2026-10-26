-- Field Health: the two crop protection liquids. They become spray types,
-- get the spray effect of herbicide, and their rates and shop prices follow
-- the settings.
FHProducts = {}

-- fill type -> threat category it treats, and the setting of its rate
FHProducts.LIQUIDS = {
    FUNGICIDE = {category = "disease", rateSetting = "fungicideUsage"},
    INSECTICIDE = {category = "pest", rateSetting = "insecticideUsage"}
}

-- Containers in the shop and the spray mixture one of them makes. The price
-- per litre of mixture follows the 1 l bottle.
FHProducts.CONTAINERS = {
    {fillType = "FUNGICIDE", priceSetting = "fungicidePrice", litres = 290, litrePrice = true, file = "fungicideBottle"},
    {fillType = "INSECTICIDE", priceSetting = "insecticidePrice", litres = 1450, litrePrice = true, file = "insecticideBottle"},
    {fillType = "FUNGICIDE", priceSetting = "fungicideCanisterPrice", litres = 1450, file = "fungicideCanister"},
    {fillType = "INSECTICIDE", priceSetting = "insecticideCanisterPrice", litres = 7250, file = "insecticideCanister"},
    {fillType = "FUNGICIDE", priceSetting = "fungicideCanister20Price", litres = 5800, file = "fungicideCanister20"},
    {fillType = "INSECTICIDE", priceSetting = "insecticideCanister20Price", litres = 29000, file = "insecticideCanister20"}
}

-- Spray effects are borrowed from these vanilla liquids, in this order.
FHProducts.EFFECT_SOURCES = {"HERBICIDE", "LIQUIDFERTILIZER"}

function FHProducts:load()
    self.categoryOf = {}
    self.sprayTypes = {}
    for name, liquid in pairs(FHProducts.LIQUIDS) do
        local index = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
        if index ~= nil then
            self.categoryOf[index] = liquid.category
        end
    end
    FHUtil.protect("spray types", self.registerSprayTypes, self)
    FHUtil.protect("spray effects", self.borrowSprayEffects, self)
    self.listener = function()
        FHProducts:applySettings()
    end
    table.insert(FHSettings.listeners, self.listener)
    self:applySettings()
end

function FHProducts:unload()
    for i = #FHSettings.listeners, 1, -1 do
        if FHSettings.listeners[i] == self.listener then
            table.remove(FHSettings.listeners, i)
        end
    end
    self.listener = nil
    self.categoryOf = {}
    self.sprayTypes = {}
end

-- "disease", "pest" or nil for any other fill type.
function FHProducts:getCategory(fillTypeIndex)
    return fillTypeIndex ~= nil and self.categoryOf ~= nil and self.categoryOf[fillTypeIndex] or nil
end

function FHProducts:getVehicleCategory(vehicle)
    if vehicle == nil or vehicle.getSprayerFillUnitIndex == nil or vehicle.getFillUnitFillType == nil then
        return nil
    end
    local fillUnitIndex = vehicle:getSprayerFillUnitIndex()
    return fillUnitIndex ~= nil and self:getCategory(vehicle:getFillUnitFillType(fillUnitIndex)) or nil
end

-- The liquids are sprayed like herbicide (about 290 l/ha of ready mixture
-- at 100%) but neither kill weeds nor fertilize.
function FHProducts:registerSprayTypes()
    if g_sprayTypeManager == nil then
        return
    end
    local herbicide = g_sprayTypeManager:getSprayTypeByName("HERBICIDE")
    self.baseRate = herbicide ~= nil and herbicide.litersPerSecond or 0.0081

    for name in pairs(FHProducts.LIQUIDS) do
        local fillType = g_fillTypeManager:getFillTypeByName(name)
        if fillType ~= nil then
            local sprayType = g_sprayTypeManager:getSprayTypeByFillTypeIndex(fillType.index)
                or g_sprayTypeManager:addSprayType(name, self.baseRate, "HERBICIDE", herbicide ~= nil and herbicide.sprayGroundType or nil, false)
            if sprayType ~= nil then
                sprayType.isHerbicide = false
                sprayType.isFertilizer = false
                sprayType.isLime = false
                sprayType.sprayGroundType = 0
                self.sprayTypes[name] = sprayType
            end
        end
    end
end

-- Gives the liquids the spray effect materials of a vanilla liquid, unless
-- another mod already defined some for them.
function FHProducts:borrowSprayEffects()
    local manager = g_materialManager
    if manager == nil or manager.addMaterial == nil then
        return
    end

    for name in pairs(FHProducts.LIQUIDS) do
        local target = g_fillTypeManager:getFillTypeIndexByName(name)
        for _, sourceName in ipairs(FHProducts.EFFECT_SOURCES) do
            local source = g_fillTypeManager:getFillTypeIndexByName(sourceName)
            local materials = source ~= nil and manager.materials ~= nil and manager.materials[source] or nil
            for materialType, byIndex in pairs(materials or {}) do
                for materialIndex, materialId in pairs(byIndex) do
                    if target ~= nil and manager:getMaterial(target, materialType, materialIndex) == nil then
                        manager:addMaterial(target, materialType, materialIndex, materialId)
                    end
                end
            end
        end
    end
end

function FHProducts:applySettings()
    FHUtil.protect("spray rates", self.applyRates, self)
    FHUtil.protect("shop prices", self.applyPrices, self)
end

-- Sprayers read the rate while working, so a change applies at once.
function FHProducts:applyRates()
    if self.baseRate == nil then
        return
    end
    for name, sprayType in pairs(self.sprayTypes or {}) do
        sprayType.litersPerSecond = self.baseRate * FHSettings.get(FHProducts.LIQUIDS[name].rateSetting)
    end
end

-- Shop price of each container (also of each extra one bought at once) and
-- the matching price per litre of mixture, which the game uses e.g. when the
-- liquid is bought at a station.
function FHProducts:applyPrices()
    local items = g_storeManager ~= nil and g_storeManager.getItems ~= nil and g_storeManager:getItems() or {}
    for _, container in ipairs(FHProducts.CONTAINERS) do
        local price = FHSettings.get(container.priceSetting)
        local single = string.lower(container.file .. ".xml")
        local multi = string.lower("multiPurchase_" .. container.file .. ".xml")
        for _, item in ipairs(items) do
            local filename = string.lower(string.gsub(item.xmlFilename or "", "\\", "/"))
            local name = string.match(filename, "([^/]+)$")
            local ownItem = item.customEnvironment == nil or item.customEnvironment == FHUtil.MOD_NAME
            if ownItem and (name == single or name == multi) then
                item.price = price
                local amounts = item.configurations ~= nil and item.configurations.multipleItemPurchaseAmount or nil
                for amount, configuration in ipairs(amounts or {}) do
                    configuration.price = price * (amount - 1)
                end
            end
        end

        if container.litrePrice and g_fillTypeManager ~= nil then
            local fillType = g_fillTypeManager:getFillTypeByName(container.fillType)
            if fillType ~= nil then
                fillType.pricePerLiter = price / container.litres
            end
        end
    end
end

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

-- Spray effect materials are borrowed from these vanilla liquids; where both
-- have one, the first wins.
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

-- True for the fill type of one of the liquids, also while the mod is off.
function FHProducts:isLiquid(fillType)
    return type(fillType) == "table" and (FHProducts.LIQUIDS[fillType.name or ""] ~= nil or self:getCategory(fillType.index) ~= nil)
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

-- Sprayers show the spray with the material of the liquid in the tank. The
-- game registers the materials of herbicide and liquid fertilizer while the
-- map loads, after the mods have started, so the liquids borrow each one when
-- it is registered (hook in FHHooks).

-- What the liquids borrowed, per material table of the game (each game
-- session has its own): "fill type|material type|index" -> {rank, material}
local borrowed = setmetatable({}, {__mode = "k"})

-- Rank of a fill type among the effect sources (1 = first choice), or nil.
local function getSourceRank(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil then
        return nil
    end
    for rank, name in ipairs(FHProducts.EFFECT_SOURCES) do
        if g_fillTypeManager:getFillTypeIndexByName(name) == fillTypeIndex then
            return rank
        end
    end
    return nil
end

-- Gives the liquids one material of an effect source. A material of their
-- own (from another mod) is kept, and one borrowed from a source ranked
-- higher is not replaced.
function FHProducts:borrowMaterial(manager, rank, materialType, materialIndex, materialId)
    local materials = manager.materials
    if type(materials) ~= "table" or materialType == nil or materialIndex == nil or materialId == nil then
        return
    end
    local records = borrowed[materials]
    if records == nil then
        records = {}
        borrowed[materials] = records
    end

    for name in pairs(FHProducts.LIQUIDS) do
        local target = g_fillTypeManager:getFillTypeIndexByName(name)
        if target ~= nil then
            local byIndex = materials[target] ~= nil and materials[target][materialType] or nil
            local current = byIndex ~= nil and byIndex[materialIndex] or nil
            local key = string.format("%s|%s|%s", tostring(target), tostring(materialType), tostring(materialIndex))
            local record = records[key]
            if current == nil then
                manager:addMaterial(target, materialType, materialIndex, materialId)
                records[key] = {rank = rank, material = materialId}
            elseif record ~= nil and record.material == current and rank <= record.rank then
                -- replaced in place: registering it again makes the game warn
                -- about a material defined twice
                byIndex[materialIndex] = materialId
                record.rank, record.material = rank, materialId
            end
        end
    end
end

-- Called for every material the game registers.
function FHProducts:onMaterialAdded(manager, fillTypeIndex, materialType, materialIndex, materialId)
    local rank = getSourceRank(fillTypeIndex)
    if rank ~= nil then
        self:borrowMaterial(manager, rank, materialType, materialIndex, materialId)
    end
end

-- Borrows the materials the game has registered so far.
function FHProducts:borrowSprayEffects()
    local manager = g_materialManager
    if manager == nil or type(manager.materials) ~= "table" or g_fillTypeManager == nil then
        return
    end
    for rank, name in ipairs(FHProducts.EFFECT_SOURCES) do
        local source = g_fillTypeManager:getFillTypeIndexByName(name)
        for materialType, byIndex in pairs(source ~= nil and manager.materials[source] or {}) do
            for materialIndex, materialId in pairs(byIndex) do
                self:borrowMaterial(manager, rank, materialType, materialIndex, materialId)
            end
        end
    end
end

-- Once the game runs: borrows what got past the hook (e.g. through a hook of
-- another mod) and says in the log when the liquids still have no spray
-- effect although herbicide or liquid fertilizer have one.
function FHProducts:checkSprayEffects()
    self:borrowSprayEffects()
    local manager = g_materialManager
    if manager == nil or manager.getMaterial == nil or g_fillTypeManager == nil then
        return
    end
    local function hasSprayEffect(name)
        local index = g_fillTypeManager:getFillTypeIndexByName(name)
        return index ~= nil and manager:getMaterial(index, "sprayer", 1) ~= nil
    end

    local sourceHasEffect = false
    for _, name in ipairs(FHProducts.EFFECT_SOURCES) do
        sourceHasEffect = sourceHasEffect or hasSprayEffect(name)
    end
    local missing = {}
    if sourceHasEffect then
        for name in pairs(FHProducts.LIQUIDS) do
            if g_fillTypeManager:getFillTypeIndexByName(name) ~= nil and not hasSprayEffect(name) then
                missing[#missing + 1] = name
            end
        end
    end
    if #missing > 0 then
        table.sort(missing)
        FHUtil.log("Warning: %s got no spray effect from %s; sprayers apply them without a visible spray",
            table.concat(missing, ", "), table.concat(FHProducts.EFFECT_SOURCES, "/"))
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

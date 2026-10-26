-- Field Health: reads nitrogen, pH and soil type from the Precision Farming
-- maps. Precision Farming has no public API, so its maps are located at
-- runtime and its configuration file is read for the target values. Every
-- access is protected; when anything is missing the mod uses its own data.
FHPrecisionFarming = {}
FHPrecisionFarming.MOD_NAME = "FS25_precisionFarming"

-- Precision Farming replaces the vanilla fertilizing and lime levels with
-- its own nitrogen and pH maps.
function FHPrecisionFarming.isActive()
    return (g_modIsLoaded ~= nil and g_modIsLoaded[FHPrecisionFarming.MOD_NAME] == true) or _G.g_precisionFarming ~= nil
end
-- Map objects are searched under these names in the Precision Farming instance.
FHPrecisionFarming.MAP_NAMES = {
    nitrogen = {"nitrogenMap"},
    ph = {"pHMap", "phMap", "PHMap"},
    soil = {"soilMap"}
}
-- Field names that may hold the engine id of a map's bit vector map.
FHPrecisionFarming.MAP_ID_FIELDS = {"bitVectorMap", "bitVectorMapId", "mapId", "densityMap"}
-- Points sampled per field.
FHPrecisionFarming.SAMPLES = 3

local config = nil
local loggedFailure = false

-- Scripts of every mod run in their own environment, which looks up shared
-- globals through its metatable, so plain indexing is used (no rawget).
local function getInstance()
    local environment = _G[FHPrecisionFarming.MOD_NAME]
    local instance = type(environment) == "table" and environment.g_precisionFarming or nil
    if instance == nil then
        instance = _G.g_precisionFarming
    end
    return type(instance) == "table" and instance or nil
end

local function findMap(instance, kind)
    for _, name in ipairs(FHPrecisionFarming.MAP_NAMES[kind]) do
        local map = instance[name]
        if type(map) == "table" then
            return map, name
        end
    end
    return nil
end

local function getMapId(map)
    for _, field in ipairs(FHPrecisionFarming.MAP_ID_FIELDS) do
        local id = map[field]
        if type(id) == "number" and id ~= 0 then
            return id
        end
    end
    return nil
end

-- Target values from PrecisionFarming.xml.
local function loadConfig()
    local directory = g_modNameToDirectory ~= nil and g_modNameToDirectory[FHPrecisionFarming.MOD_NAME] or nil
    if directory == nil then
        return nil
    end

    local xmlFile = loadXMLFile("pfConfig", directory .. "PrecisionFarming.xml")
    if xmlFile == nil or xmlFile == 0 then
        return nil
    end

    local result = {nitrogenValues = {}, phValues = {}, optimalPh = {}, nitrogenTargets = {}}

    local function readValues(key, target)
        local i = 0
        while true do
            local entryKey = string.format("%s(%d)", key, i)
            local value = getXMLInt(xmlFile, entryKey .. "#value")
            if value == nil then
                break
            end
            target[value] = getXMLFloat(xmlFile, entryKey .. "#realValue")
            i = i + 1
        end
    end
    readValues("precisionFarming.nitrogenMap.nitrogenValues.nitrogenValue", result.nitrogenValues)
    readValues("precisionFarming.pHMap.pHValues.pHValue", result.phValues)

    local i = 0
    while true do
        local key = string.format("precisionFarming.pHMap.valueTransformations.valueTransformation(%d)", i)
        local soilTypeIndex = getXMLInt(xmlFile, key .. "#soilTypeIndex")
        if soilTypeIndex == nil then
            break
        end
        result.optimalPh[soilTypeIndex] = getXMLFloat(xmlFile, key .. ".optimalValue#value")
        i = i + 1
    end

    i = 0
    while true do
        local key = string.format("precisionFarming.nitrogenMap.fruitRequirements.fruitRequirement(%d)", i)
        local fruitName = getXMLString(xmlFile, key .. "#fruitTypeName")
        if fruitName == nil then
            break
        end
        local targets = {}
        local j = 0
        while true do
            local soilKey = string.format("%s.soil(%d)", key, j)
            local soilTypeIndex = getXMLInt(xmlFile, soilKey .. "#soilTypeIndex")
            if soilTypeIndex == nil then
                break
            end
            targets[soilTypeIndex] = getXMLFloat(xmlFile, soilKey .. "#targetLevel")
            j = j + 1
        end
        result.nitrogenTargets[string.upper(fruitName)] = targets
        i = i + 1
    end

    delete(xmlFile)
    return result
end

local function getConfig()
    if config == nil then
        local ok, result = pcall(loadConfig)
        if ok then
            config = result
        end
    end
    return config
end

local function readMapValue(map, x, z, numChannels)
    numChannels = type(map.numChannels) == "number" and map.numChannels or numChannels
    local id = getMapId(map)
    if id == nil then
        return nil
    end
    local width, height = getBitVectorMapSize(id)
    local terrainSize = g_currentMission.terrainSize
    local mapX = FHUtil.clamp(math.floor(width * (x + terrainSize * 0.5) / terrainSize), 0, width - 1)
    local mapZ = FHUtil.clamp(math.floor(height * (z + terrainSize * 0.5) / terrainSize), 0, height - 1)
    return getBitVectorMapPoint(id, mapX, mapZ, 0, numChannels)
end

-- Returns the field data, or nil and the reason.
local function readFieldData(field, fruitName)
    local instance = getInstance()
    if instance == nil then
        return nil, "Precision Farming instance not found"
    end
    local cfg = getConfig()
    if cfg == nil then
        return nil, "PrecisionFarming.xml could not be read"
    end

    local nitrogenMap = findMap(instance, "nitrogen")
    local phMap = findMap(instance, "ph")
    local soilMap = findMap(instance, "soil")
    if nitrogenMap == nil or phMap == nil or soilMap == nil then
        return nil, string.format("maps missing (nitrogen %s, pH %s, soil %s)", tostring(nitrogenMap ~= nil), tostring(phMap ~= nil), tostring(soilMap ~= nil))
    end

    local targets = cfg.nitrogenTargets[fruitName or ""]
    local result = {nitrogenOffset = 0, phOffset = 0, soilCounts = {0, 0, 0, 0}, samples = 0, hasNitrogenTarget = targets ~= nil}
    for _, point in ipairs(FHUtil.getSamplePoints(field, FHPrecisionFarming.SAMPLES)) do
        local soilValue = readMapValue(soilMap, point.x, point.z, 2)
        local nitrogenValue = readMapValue(nitrogenMap, point.x, point.z, 6)
        local phValue = readMapValue(phMap, point.x, point.z, 5)
        local soilTypeIndex = (soilValue or 0) + 1
        local nitrogen = cfg.nitrogenValues[nitrogenValue or -1]
        local ph = cfg.phValues[phValue or -1]
        if nitrogen == nil or ph == nil then
            return nil, string.format("no map values (raw nitrogen %s, pH %s, soil %s)", tostring(nitrogenValue), tostring(phValue), tostring(soilValue))
        end

        result.samples = result.samples + 1
        result.soilCounts[soilTypeIndex] = (result.soilCounts[soilTypeIndex] or 0) + 1
        if targets ~= nil and targets[soilTypeIndex] ~= nil then
            result.nitrogenOffset = result.nitrogenOffset + nitrogen - targets[soilTypeIndex]
        end
        result.phOffset = result.phOffset + ph - (cfg.optimalPh[soilTypeIndex] or 6.5)
    end

    if result.samples == 0 then
        return nil, "no sample point inside the field"
    end

    result.nitrogenOffset = result.nitrogenOffset / result.samples
    result.phOffset = result.phOffset / result.samples
    local bestCount = 0
    for soilTypeIndex, count in pairs(result.soilCounts) do
        if count > bestCount then
            result.soilTypeIndex, bestCount = soilTypeIndex, count
        end
    end
    return result
end

-- Returns {nitrogenOffset (kg N/ha, actual - target), phOffset (actual - optimal),
-- soilTypeIndex (1 = light ... 4 = heavy), hasNitrogenTarget} or nil.
function FHPrecisionFarming.getFieldData(field, fruitName)
    if not FHPrecisionFarming.isActive() or field == nil then
        return nil
    end

    local ok, result, reason = pcall(readFieldData, field, fruitName)
    if not ok or result == nil then
        if not loggedFailure then
            loggedFailure = true
            FHUtil.log("Precision Farming maps could not be read, using recorded fertilizing instead: %s", tostring(not ok and result or reason))
            local data = FHUtil.getOutline(field)
            local diagnostics = FHPrecisionFarming.getDiagnostics(data ~= nil and (data.minX + data.maxX) * 0.5 or nil, data ~= nil and (data.minZ + data.maxZ) * 0.5 or nil)
            for line in string.gmatch(diagnostics, "[^\n]+") do
                print(FHUtil.LOG_PREFIX .. line)
            end
        end
        return nil
    end
    return result
end

-- Console diagnostics: shows how the Precision Farming data was found.
function FHPrecisionFarming.getDiagnostics(x, z)
    local lines = {}
    local instance = getInstance()
    table.insert(lines, "Precision Farming active: " .. tostring(FHPrecisionFarming.isActive()))
    table.insert(lines, "instance found: " .. tostring(instance ~= nil))
    if instance ~= nil then
        local keys = {}
        for key, value in pairs(instance) do
            table.insert(keys, tostring(key) .. ":" .. type(value))
        end
        table.sort(keys)
        table.insert(lines, "instance fields: " .. table.concat(keys, " "))

        for kind in pairs(FHPrecisionFarming.MAP_NAMES) do
            local map, name = findMap(instance, kind)
            if map == nil then
                table.insert(lines, kind .. " map: not found")
            else
                local mapKeys = {}
                for key, value in pairs(map) do
                    if type(value) ~= "function" then
                        table.insert(mapKeys, tostring(key) .. "=" .. (type(value) == "number" and tostring(value) or type(value)))
                    end
                end
                table.sort(mapKeys)
                table.insert(lines, string.format("%s map (%s): id=%s fields: %s", kind, name, tostring(getMapId(map)), table.concat(mapKeys, " ")))
            end
        end
    end

    local cfg = getConfig()
    table.insert(lines, "config loaded: " .. tostring(cfg ~= nil))
    local field = x ~= nil and FHUtil.getFieldAt(x, z) or nil
    if field ~= nil then
        local entry = FHSimulation:getEntry(FHUtil.getFieldId(field))
        local ok, data, reason = pcall(readFieldData, field, entry ~= nil and entry.cropFruitName or nil)
        if ok and data ~= nil then
            table.insert(lines, string.format("field %s: nitrogen %+.0f kg/ha vs target (target known: %s), pH %+.2f vs optimal, soil type %s, %d samples",
                tostring(FHUtil.getFieldId(field)), data.nitrogenOffset, tostring(data.hasNitrogenTarget), data.phOffset, tostring(data.soilTypeIndex), data.samples))
        else
            table.insert(lines, "field data: " .. tostring(ok and reason or data))
        end
    end
    return table.concat(lines, "\n")
end

-- Field Health: savegame files. All data lives in files of this mod inside
-- the savegame folder (fieldHealth.xml and the field map); no game file is
-- changed, so removing the mod leaves the savegame intact.
FHSavegame = {}

FHSavegame.FILENAME = "fieldHealth.xml"
FHSavegame.ROOT = "fieldHealth"
-- 2: threat ids with 6 bits in the field map (version 1 had 5)
FHSavegame.VERSION = 2
-- bits per cell of the field map saved by version 1
FHSavegame.VERSION_1_MAP_BITS = 9

local function writeValue(xmlFile, path, valueType, value)
    if valueType == "bool" then
        setXMLBool(xmlFile, path, value)
    elseif valueType == "int" then
        setXMLInt(xmlFile, path, value)
    elseif valueType == "float" then
        setXMLFloat(xmlFile, path, value)
    else
        setXMLString(xmlFile, path, value)
    end
end

local function readValue(xmlFile, path, valueType)
    if valueType == "bool" then
        return getXMLBool(xmlFile, path)
    elseif valueType == "int" then
        return getXMLInt(xmlFile, path)
    elseif valueType == "float" then
        return getXMLFloat(xmlFile, path)
    end
    return getXMLString(xmlFile, path)
end

-- Written right after the game saved its own files, so quitting without
-- saving keeps both in step.
function FHSavegame.save()
    local directory = FHUtil.getSavegameDirectory(true)
    if g_server == nil or FHSimulation.fields == nil or directory == nil then
        return
    end

    local root = FHSavegame.ROOT
    local xmlFile = createXMLFile("fieldHealthXML", directory .. "/" .. FHSavegame.FILENAME, root)
    if xmlFile == nil or xmlFile == 0 then
        FHUtil.log("Could not write %s", FHSavegame.FILENAME)
        return
    end

    setXMLInt(xmlFile, root .. "#version", FHSavegame.VERSION)
    setXMLInt(xmlFile, root .. "#mapBits", FHFieldMap.BITS)
    FHSettings.save(xmlFile, root .. ".settings")

    local i = 0
    for fieldId, entry in pairs(FHSimulation.fields) do
        local key = string.format("%s.fields.field(%d)", root, i)
        setXMLInt(xmlFile, key .. "#id", fieldId)
        for _, def in ipairs(FHSimulation.ENTRY) do
            if def.save and entry[def.name] ~= nil then
                writeValue(xmlFile, key .. "#" .. def.name, def.type, entry[def.name])
            end
        end
        i = i + 1
    end

    i = 0
    for farmId, record in pairs(FHSimulation.farmThreats) do
        local key = string.format("%s.farms.farm(%d)", root, i)
        setXMLInt(xmlFile, key .. "#id", farmId)
        setXMLInt(xmlFile, key .. "#year", record.year)
        setXMLInt(xmlFile, key .. "#threats", record.count)
        i = i + 1
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
    FHFieldMap:save(directory)
end

-- Bits per cell of the field map saved in the directory, nil without data.
function FHSavegame.getMapBits(directory)
    local path = directory ~= nil and (directory .. "/" .. FHSavegame.FILENAME) or nil
    if path == nil or not fileExists(path) then
        return nil
    end
    local xmlFile = loadXMLFile("fieldHealthXML", path)
    if xmlFile == nil or xmlFile == 0 then
        return nil
    end
    local bits = getXMLInt(xmlFile, FHSavegame.ROOT .. "#mapBits") or FHSavegame.VERSION_1_MAP_BITS
    delete(xmlFile)
    return bits
end

-- Reads settings, fields and farm counters of the current savegame.
function FHSavegame.load()
    local directory = FHUtil.getSavegameDirectory(false)
    local path = directory ~= nil and (directory .. "/" .. FHSavegame.FILENAME) or nil
    if path == nil or not fileExists(path) then
        return
    end
    local xmlFile = loadXMLFile("fieldHealthXML", path)
    if xmlFile == nil or xmlFile == 0 then
        return
    end

    local root = FHSavegame.ROOT
    FHSettings.load(xmlFile, root .. ".settings")

    local i = 0
    while true do
        local key = string.format("%s.fields.field(%d)", root, i)
        local fieldId = getXMLInt(xmlFile, key .. "#id")
        if fieldId == nil then
            break
        end
        local entry = FHSimulation.newEntry()
        for _, def in ipairs(FHSimulation.ENTRY) do
            if def.save then
                local value = readValue(xmlFile, key .. "#" .. def.name, def.type)
                if value ~= nil then
                    entry[def.name] = value
                end
            end
        end
        -- threats a later version no longer knows are dropped
        for _, category in ipairs(FHThreats.CATEGORIES) do
            if FHSimulation:getActiveThreat(entry, category) == nil then
                FHSimulation:clearThreat(entry, category)
            end
        end
        FHSimulation.fields[fieldId] = entry
        i = i + 1
    end

    i = 0
    while true do
        local key = string.format("%s.farms.farm(%d)", root, i)
        local farmId = getXMLInt(xmlFile, key .. "#id")
        if farmId == nil then
            break
        end
        FHSimulation.farmThreats[farmId] = {year = getXMLInt(xmlFile, key .. "#year") or 0, count = getXMLInt(xmlFile, key .. "#threats") or 0}
        i = i + 1
    end

    delete(xmlFile)
end

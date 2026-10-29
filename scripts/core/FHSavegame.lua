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

-- Reads an int attribute of the root of the savegame file, nil without data.
local function readRootInt(directory, attribute)
    local path = directory ~= nil and (directory .. "/" .. FHSavegame.FILENAME) or nil
    if path == nil or not fileExists(path) then
        return nil, false
    end
    local xmlFile = loadXMLFile("fieldHealthXML", path)
    if xmlFile == nil or xmlFile == 0 then
        return nil, false
    end
    local value = getXMLInt(xmlFile, FHSavegame.ROOT .. "#" .. attribute)
    delete(xmlFile)
    return value, true
end

-- Bits per cell of the field map saved in the directory, nil without data.
function FHSavegame.getMapBits(directory)
    local bits, found = readRootInt(directory, "mapBits")
    if not found then
        return nil
    end
    return bits or FHSavegame.VERSION_1_MAP_BITS
end

-- Data saved by a newer version of the mod may use a format this version
-- does not know. It is neither read nor overwritten: the mod stays off
-- until it is updated (raises an error).
function FHSavegame.checkVersion(directory)
    local version = readRootInt(directory, "version")
    if version ~= nil and version > FHSavegame.VERSION then
        error(string.format("%s was saved by a newer version of Field Health (data format %d, this version knows up to %d). Please update the mod.",
            FHSavegame.FILENAME, version, FHSavegame.VERSION), 0)
    end
end

-- Reads settings, fields and farm counters of the current savegame.
function FHSavegame.load(directory)
    directory = directory or FHUtil.getSavegameDirectory(false)
    local path = directory ~= nil and (directory .. "/" .. FHSavegame.FILENAME) or nil
    if path == nil or not fileExists(path) then
        return
    end
    local xmlFile = loadXMLFile("fieldHealthXML", path)
    if xmlFile == nil or xmlFile == 0 then
        FHUtil.log("Could not read %s, the mod starts without its data", FHSavegame.FILENAME)
        return
    end

    local root = FHSavegame.ROOT
    FHSettings.load(xmlFile, root .. ".settings")

    -- entries without a valid id (e.g. edited by hand) are skipped
    local skipped = 0
    for i = 0, math.huge do
        local key = string.format("%s.fields.field(%d)", root, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local fieldId = getXMLInt(xmlFile, key .. "#id")
        if fieldId ~= nil then
            FHSimulation.fields[fieldId] = FHSavegame.readEntry(xmlFile, key)
        else
            skipped = skipped + 1
        end
    end

    for i = 0, math.huge do
        local key = string.format("%s.farms.farm(%d)", root, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#id")
        if farmId ~= nil then
            FHSimulation.farmThreats[farmId] = {year = getXMLInt(xmlFile, key .. "#year") or 0, count = getXMLInt(xmlFile, key .. "#threats") or 0}
        else
            skipped = skipped + 1
        end
    end

    delete(xmlFile)
    if skipped > 0 then
        FHUtil.log("%s: entries without a valid id skipped: %d", FHSavegame.FILENAME, skipped)
    end
end

-- One field entry; values that cannot be read keep their default.
function FHSavegame.readEntry(xmlFile, key)
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
    return entry
end

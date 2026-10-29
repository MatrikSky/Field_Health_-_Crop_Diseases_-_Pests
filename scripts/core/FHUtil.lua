-- Field Health: small helpers shared by all modules.
FHUtil = {}

FHUtil.MOD_NAME = g_currentModName or "FS25_FieldHealth"
FHUtil.MOD_DIRECTORY = g_currentModDirectory or ""
FHUtil.LOG_PREFIX = "[FieldHealth] "
FHUtil.verbose = false

---------------------------------------------------------------------------
-- Numbers, logging, texts
---------------------------------------------------------------------------

function FHUtil.clamp(value, low, high)
    if value < low then
        return low
    elseif value > high then
        return high
    end
    return value
end

function FHUtil.log(fmt, ...)
    print(FHUtil.LOG_PREFIX .. string.format(fmt, ...))
end

-- Messages that only matter while testing (console: fhDebugLog).
function FHUtil.trace(fmt, ...)
    if FHUtil.verbose then
        FHUtil.log(fmt, ...)
    end
end

-- The same error is written this often; a fault that repeats every frame
-- must not flood the log. Different errors are counted up to MAX_ERRORS.
FHUtil.ERROR_REPEATS = 3
FHUtil.MAX_ERRORS = 50
FHUtil.errorCounts = {}
FHUtil.errorKinds = 0

function FHUtil.reportError(context, message)
    local text = string.format("Error in %s: %s", tostring(context), tostring(message))
    local count = FHUtil.errorCounts[text]
    if count == nil then
        if FHUtil.errorKinds >= FHUtil.MAX_ERRORS then
            return
        end
        FHUtil.errorKinds = FHUtil.errorKinds + 1
        if FHUtil.errorKinds == FHUtil.MAX_ERRORS then
            FHUtil.log("%s (too many errors, further new ones are not written)", text)
            return
        end
        count = 0
    end
    count = count + 1
    FHUtil.errorCounts[text] = count
    if count < FHUtil.ERROR_REPEATS then
        FHUtil.log("%s", text)
    elseif count == FHUtil.ERROR_REPEATS then
        FHUtil.log("%s (repeats, not written again)", text)
    end
end

-- Runs func(...) and logs instead of raising errors, so a problem in this mod
-- never breaks the game function it is hooked into.
function FHUtil.protect(context, func, ...)
    local ok, result = pcall(func, ...)
    if not ok then
        FHUtil.reportError(context, result)
        return nil
    end
    return result
end

function FHUtil.text(key, fallback)
    if key ~= nil and g_i18n ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return fallback or key or ""
end

function FHUtil.percent(share)
    return string.format("%d%%", math.floor(share * 100 + 0.5))
end

---------------------------------------------------------------------------
-- Smooth noise for natural looking infection patches
---------------------------------------------------------------------------

local function hash01(ix, iz, seed)
    local h = math.sin(ix * 12.9898 + iz * 78.233 + seed * 37.719) * 43758.5453
    return h - math.floor(h)
end

local function smooth(t)
    return t * t * (3 - 2 * t)
end

-- Value noise 0..1: neighbouring points have similar values; one unit is
-- about the size of one blob.
function FHUtil.noise(x, z, seed)
    local x0, z0 = math.floor(x), math.floor(z)
    local tx, tz = smooth(x - x0), smooth(z - z0)
    local top = hash01(x0, z0, seed) * (1 - tx) + hash01(x0 + 1, z0, seed) * tx
    local bottom = hash01(x0, z0 + 1, seed) * (1 - tx) + hash01(x0 + 1, z0 + 1, seed) * tx
    return top * (1 - tz) + bottom * tz
end

-- Large shapes with finer detail on top.
function FHUtil.layeredNoise(x, z, seed)
    return 0.65 * FHUtil.noise(x, z, seed) + 0.35 * FHUtil.noise(x * 2.3 + 5.1, z * 2.3 + 1.7, seed + 17)
end

---------------------------------------------------------------------------
-- Game state
---------------------------------------------------------------------------

function FHUtil.isServer()
    return g_server ~= nil
end

function FHUtil.isMultiplayer()
    local mission = g_currentMission
    return mission ~= nil and mission.missionDynamicInfo ~= nil and mission.missionDynamicInfo.isMultiplayer == true
end

function FHUtil.getDaysPerPeriod()
    local mission = g_currentMission
    local days = mission ~= nil and ((mission.environment ~= nil and mission.environment.daysPerPeriod)
        or (mission.missionInfo ~= nil and mission.missionInfo.daysPerPeriod)) or 1
    return math.max(1, tonumber(days) or 1)
end

function FHUtil.getDay()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    if environment == nil then
        return 0
    end
    return environment.currentMonotonicDay or environment.currentDay or 0
end

function FHUtil.getYear()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    if environment ~= nil and environment.currentYear ~= nil then
        return environment.currentYear
    end
    return math.floor(FHUtil.getDay() / (FHUtil.getDaysPerPeriod() * 12))
end

-- Calendar month (1 = January). The game's year starts with period 1 in March.
function FHUtil.getMonth()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local period = environment ~= nil and tonumber(environment.currentPeriod) or nil
    if period == nil then
        period = math.floor(math.max(FHUtil.getDay() - 1, 0) / FHUtil.getDaysPerPeriod()) % 12 + 1
    end
    return (math.floor(period) + 1) % 12 + 1
end

-- Savegame directory; a new career has none yet when it is saved the first time.
function FHUtil.getSavegameDirectory(forSaving)
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil then
        return nil
    end
    if info.savegameDirectory ~= nil and info.savegameDirectory ~= "" then
        return info.savegameDirectory
    end
    if forSaving and info.savegameIndex ~= nil then
        return string.format("%ssavegame%d", getUserProfileAppPath(), info.savegameIndex)
    end
    return nil
end

-- Where the local player is: the vehicle, the player or else the camera.
function FHUtil.getPlayerPosition()
    local player = g_localPlayer
    if player ~= nil then
        local vehicle = player.getCurrentVehicle ~= nil and player:getCurrentVehicle() or nil
        local node = vehicle ~= nil and (vehicle.rootNode or (vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node)) or nil
        if node ~= nil then
            return getWorldTranslation(node)
        end
        if player.rootNode ~= nil then
            return getWorldTranslation(player.rootNode)
        end
    end

    local camera = g_cameraManager ~= nil and g_cameraManager.getActiveCamera ~= nil and g_cameraManager:getActiveCamera() or nil
    if type(camera) == "number" and camera ~= 0 then
        return getWorldTranslation(camera)
    end
    return nil
end

---------------------------------------------------------------------------
-- Fields: outline polygons and a coarse spatial index
---------------------------------------------------------------------------

local outlines = {}
local index = nil
local indexedFields = 0
local INDEX_CELL = 64 -- metres per bucket of the field index

function FHUtil.resetFieldCache()
    outlines = {}
    index = nil
end

local function buildOutline(field)
    local polygon = Polygon2D.new()
    local densityPolygon = field.getDensityMapPolygon ~= nil and field:getDensityMapPolygon() or nil
    local vertices = densityPolygon ~= nil and densityPolygon.getVerticesList ~= nil and densityPolygon:getVerticesList() or nil
    if vertices ~= nil and #vertices >= 6 then
        for i = 1, #vertices - 1, 2 do
            polygon:addPos(vertices[i], vertices[i + 1])
        end
    elseif field.getPolygonPoints ~= nil then
        for _, point in ipairs(field:getPolygonPoints() or {}) do
            local x, _, z = getWorldTranslation(point)
            polygon:addPos(x, z)
        end
    end

    if polygon:getNumVertices() < 3 then
        return false
    end
    local minX, maxX, minZ, maxZ = polygon:getBoundingBox()
    return {polygon = polygon, minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ}
end

-- {polygon, minX, maxX, minZ, maxZ} of a field, or nil without an outline.
function FHUtil.getOutline(field)
    if field == nil then
        return nil
    end
    local outline = outlines[field]
    if outline == nil then
        outline = buildOutline(field)
        outlines[field] = outline
    end
    return outline or nil
end

function FHUtil.contains(field, x, z)
    local o = FHUtil.getOutline(field)
    return o ~= nil and x >= o.minX and x <= o.maxX and z >= o.minZ and z <= o.maxZ and o.polygon:getIsPosInside(x, z)
end

local function bucketKey(bx, bz)
    return bx * 65536 + bz
end

local function buildIndex(fields)
    index = {}
    indexedFields = #fields
    for _, field in ipairs(fields) do
        local o = FHUtil.getOutline(field)
        if o ~= nil then
            for bx = math.floor(o.minX / INDEX_CELL), math.floor(o.maxX / INDEX_CELL) do
                for bz = math.floor(o.minZ / INDEX_CELL), math.floor(o.maxZ / INDEX_CELL) do
                    local key = bucketKey(bx, bz)
                    index[key] = index[key] or {}
                    table.insert(index[key], field)
                end
            end
        end
    end
end

function FHUtil.getFieldAt(x, z)
    if x == nil or z == nil or g_fieldManager == nil then
        return nil
    end
    -- built again when maps or mods add fields during the game
    local fields = g_fieldManager:getFields() or {}
    if index == nil or #fields ~= indexedFields then
        buildIndex(fields)
    end
    for _, field in ipairs(index[bucketKey(math.floor(x / INDEX_CELL), math.floor(z / INDEX_CELL))] or {}) do
        if FHUtil.contains(field, x, z) then
            return field
        end
    end
    return nil
end

function FHUtil.getFieldId(field)
    if field == nil then
        return nil
    end
    return (field.getId ~= nil and field:getId()) or field.fieldId
end

function FHUtil.getField(fieldId)
    if fieldId == nil or g_fieldManager == nil then
        return nil
    end
    local field = g_fieldManager.getFieldById ~= nil and g_fieldManager:getFieldById(fieldId) or nil
    if field ~= nil then
        return field
    end
    for _, candidate in ipairs(g_fieldManager:getFields() or {}) do
        if FHUtil.getFieldId(candidate) == fieldId then
            return candidate
        end
    end
    return nil
end

function FHUtil.getFieldAtPlayer()
    local x, _, z = FHUtil.getPlayerPosition()
    return x ~= nil and FHUtil.getFieldAt(x, z) or nil
end

-- Points of an n x n grid over the field's bounding box that lie inside it.
function FHUtil.getSamplePoints(field, n)
    local o = FHUtil.getOutline(field)
    local points = {}
    if o == nil then
        return points
    end
    for i = 1, n do
        for j = 1, n do
            local x = o.minX + (o.maxX - o.minX) * (i - 0.5) / n
            local z = o.minZ + (o.maxZ - o.minZ) * (j - 0.5) / n
            if o.polygon:getIsPosInside(x, z) then
                points[#points + 1] = {x = x, z = z}
            end
        end
    end
    return points
end

---------------------------------------------------------------------------
-- Farms
---------------------------------------------------------------------------

function FHUtil.getOwnerFarmId(field)
    if field == nil then
        return nil
    end
    if field.getOwnerFarmId ~= nil then
        return field:getOwnerFarmId()
    end
    local farmland = field.farmland
    if farmland ~= nil and g_farmlandManager ~= nil then
        return g_farmlandManager:getFarmlandOwner(farmland.id)
    end
    return nil
end

-- Farms of players: not the spectators and not "no owner" (NPC land).
function FHUtil.isPlayerFarm(farmId)
    if farmId == nil or farmId == FarmlandManager.NO_OWNER_FARM_ID or g_farmManager == nil then
        return false
    end
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and not farm.isSpectator
end

function FHUtil.isPlayerField(field)
    return FHUtil.isPlayerFarm(FHUtil.getOwnerFarmId(field))
end

function FHUtil.getLocalFarmId()
    local mission = g_currentMission
    return mission ~= nil and mission.getFarmId ~= nil and mission:getFarmId() or nil
end

---------------------------------------------------------------------------
-- Fill types and crops
---------------------------------------------------------------------------

function FHUtil.getFillTypeName(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil then
        return nil
    end
    if g_fillTypeManager.getFillTypeNameByIndex ~= nil then
        return g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    return fillType ~= nil and fillType.name or nil
end

-- Display name of a crop, e.g. "Wheat", from its fruit type name.
function FHUtil.getCropTitle(fruitName)
    local fruitManager = g_fruitTypeManager
    local desc = fruitName ~= nil and fruitManager ~= nil and fruitManager.getFruitTypeByName ~= nil and fruitManager:getFruitTypeByName(fruitName) or nil
    if desc ~= nil and fruitManager.getFillTypeByFruitTypeIndex ~= nil then
        local fillType = fruitManager:getFillTypeByFruitTypeIndex(desc.index)
        if type(fillType) == "table" and fillType.title ~= nil then
            return fillType.title
        elseif type(fillType) == "number" and g_fillTypeManager ~= nil then
            local title = g_fillTypeManager:getFillTypeTitleByIndex(fillType)
            if title ~= nil and title ~= "" then
                return title
            end
        end
    end
    return fruitName or "?"
end

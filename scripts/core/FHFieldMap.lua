-- Field Health: one bit vector map over the whole terrain with the state of
-- every cell (about 2 x 2 m on a 2 km map):
--   bits 0-1  severity of a threat (0 = healthy, 1..3)
--   bits 2-7  id of the threat (FHThreats)
--   bits 8-9  spray protection (1 = insecticide, 2 = fungicide)
FHFieldMap = {}

FHFieldMap.SIZE = 1024
FHFieldMap.FILENAME = "fieldHealthMap.grle"
FHFieldMap.SEVERITY = {first = 0, bits = 2}
FHFieldMap.THREAT = {first = 2, bits = FHThreats.ID_BITS}
FHFieldMap.PROTECTION = {first = 2 + FHThreats.ID_BITS, bits = 2}
FHFieldMap.BITS = 2 + FHThreats.ID_BITS + 2
FHFieldMap.PROTECTION_BIT = {pest = 1, disease = 2}
-- Earlier layouts by their number of bits: bits of the threat id (the
-- severity always comes first, the protection last).
FHFieldMap.OLD_LAYOUTS = {[9] = {threatBits = 5}}
-- Patch shape: how much noise frays the edge (share of the radius) and how
-- many healthy gaps stay inside, mostly towards the edge.
FHFieldMap.EDGE_NOISE = 0.35
FHFieldMap.GAP_SHARE = 0.3

local function terrainSize()
    return g_currentMission ~= nil and g_currentMission.terrainSize or 2048
end

local function hasBit(value, bit)
    return bit ~= nil and bit > 0 and value % (bit * 2) >= bit
end

---------------------------------------------------------------------------
-- Lifecycle and persistence
---------------------------------------------------------------------------

function FHFieldMap:load(directory)
    self.mapId = createBitVectorMap("FieldHealthMap")
    local loaded = false
    local path = directory ~= nil and (directory .. "/" .. FHFieldMap.FILENAME) or nil
    if path ~= nil and fileExists(path) then
        -- the savegame data names the layout the map was saved with
        local bits = FHSavegame.getMapBits(directory) or FHFieldMap.BITS
        local known = bits == FHFieldMap.BITS or FHFieldMap.OLD_LAYOUTS[bits] ~= nil
        loaded = known and loadBitVectorMapFromFile(self.mapId, path, bits) == true
        local width, height = getBitVectorMapSize(self.mapId)
        if not loaded or (width or 0) < 2 or width ~= height then
            FHUtil.log("Ignoring unreadable %s", FHFieldMap.FILENAME)
            delete(self.mapId)
            self.mapId = createBitVectorMap("FieldHealthMap")
            loaded = false
        elseif bits ~= FHFieldMap.BITS then
            self:convertLayout(bits, width)
        end
    end
    if not loaded then
        loadBitVectorMapNew(self.mapId, FHFieldMap.SIZE, FHFieldMap.SIZE, FHFieldMap.BITS, false)
    end

    self.size = getBitVectorMapSize(self.mapId)
    self.loadedFromFile = loaded
    self.revision = 0
    self.pending = {}
    return loaded
end

-- Moves every cell of a map saved with an earlier layout into the current one.
function FHFieldMap:convertLayout(oldBits, size)
    local threatBits = FHFieldMap.OLD_LAYOUTS[oldBits].threatBits
    local oldId = self.mapId
    self.mapId = createBitVectorMap("FieldHealthMap")
    loadBitVectorMapNew(self.mapId, size, size, FHFieldMap.BITS, false)
    local cells = 0
    for z = 0, size - 1 do
        for x = 0, size - 1 do
            local value = getBitVectorMapPoint(oldId, x, z, 0, oldBits) or 0
            if value ~= 0 then
                local severity = value % 4
                local threatId = math.floor(value / 4) % (2 ^ threatBits)
                local protection = math.floor(value / 2 ^ (2 + threatBits)) % 4
                local converted = severity + threatId * 2 ^ FHFieldMap.THREAT.first + protection * 2 ^ FHFieldMap.PROTECTION.first
                if setBitVectorMapPoint ~= nil then
                    setBitVectorMapPoint(self.mapId, x, z, 0, FHFieldMap.BITS, converted)
                else
                    setBitVectorMapParallelogram(self.mapId, x, z, 1, 0, 0, 1, 0, FHFieldMap.BITS, converted)
                end
                cells = cells + 1
            end
        end
    end
    delete(oldId)
    FHUtil.log("Converted %s to the new layout (%d cells)", FHFieldMap.FILENAME, cells)
end

function FHFieldMap:unload()
    if self.mapId ~= nil then
        delete(self.mapId)
    end
    self.mapId = nil
    self.pending = {}
end

function FHFieldMap:save(directory)
    if self.mapId ~= nil and directory ~= nil then
        saveBitVectorMapToFile(self.mapId, directory .. "/" .. FHFieldMap.FILENAME)
    end
end

---------------------------------------------------------------------------
-- Coordinates
---------------------------------------------------------------------------

function FHFieldMap:getCellSize()
    return terrainSize() / (self.size or FHFieldMap.SIZE)
end

function FHFieldMap:toCell(worldX, worldZ)
    local size, terrain = self.size, terrainSize()
    local x = math.floor((worldX / terrain + 0.5) * size)
    local z = math.floor((worldZ / terrain + 0.5) * size)
    return FHUtil.clamp(x, 0, size - 1), FHUtil.clamp(z, 0, size - 1)
end

function FHFieldMap:toWorld(x, z)
    local size, terrain = self.size, terrainSize()
    return ((x + 0.5) / size - 0.5) * terrain, ((z + 0.5) / size - 0.5) * terrain
end

---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

local function read(mapId, x, z, channel)
    return getBitVectorMapPoint(mapId, x, z, channel.first, channel.bits) or 0
end

function FHFieldMap:readRaw(x, z)
    return self.mapId ~= nil and (getBitVectorMapPoint(self.mapId, x, z, 0, FHFieldMap.BITS) or 0) or 0
end

-- Writes the whole cell value; network updates use this directly.
function FHFieldMap:writeRaw(x, z, value, isRemote)
    if self.mapId == nil or self:readRaw(x, z) == value then
        return false
    end
    if setBitVectorMapPoint ~= nil then
        setBitVectorMapPoint(self.mapId, x, z, 0, FHFieldMap.BITS, value)
    else
        setBitVectorMapParallelogram(self.mapId, x, z, 1, 0, 0, 1, 0, FHFieldMap.BITS, value)
    end
    self.revision = self.revision + 1
    if not isRemote and g_server ~= nil and FHUtil.isMultiplayer() then
        self.pending[z * self.size + x] = true
    end
    FHDisplayMap:onCellChanged(x, z)
    return true
end

-- severity, threat id (0 for healthy cells)
function FHFieldMap:getThreat(x, z)
    if self.mapId == nil then
        return 0, 0
    end
    local severity = read(self.mapId, x, z, FHFieldMap.SEVERITY)
    return severity, severity > 0 and read(self.mapId, x, z, FHFieldMap.THREAT) or 0
end

function FHFieldMap:getProtection(x, z)
    return self.mapId ~= nil and read(self.mapId, x, z, FHFieldMap.PROTECTION) or 0
end

function FHFieldMap:isProtected(x, z, category)
    return hasBit(self:getProtection(x, z), FHFieldMap.PROTECTION_BIT[category])
end

local function compose(severity, threatId, protection)
    local threatBits = 2 ^ FHFieldMap.THREAT.first
    return severity + (severity > 0 and threatId or 0) * threatBits + protection * 2 ^ FHFieldMap.PROTECTION.first
end

-- Sets the threat of a cell. Cells sprayed against the threat's category
-- never get infected. Returns true when the cell changed.
function FHFieldMap:setThreat(x, z, severity, threatId)
    severity = FHUtil.clamp(severity, 0, FHThreats.MAX_SEVERITY)
    if severity > 0 then
        local threat = FHThreats.getById(threatId)
        if threat == nil or self:isProtected(x, z, threat.category) then
            return false
        end
    end
    return self:writeRaw(x, z, compose(severity, threatId, self:getProtection(x, z)))
end

function FHFieldMap:setProtection(x, z, protection)
    local severity, threatId = self:getThreat(x, z)
    return self:writeRaw(x, z, compose(severity, threatId, protection))
end

-- A threat may cover healthy cells and its own cells of lower severity;
-- cells of another threat stay as they are.
function FHFieldMap:canInfect(x, z, severity, threatId)
    local current, currentId = self:getThreat(x, z)
    return current == 0 or (currentId == threatId and current < severity)
end

function FHFieldMap:clearAll()
    if self.mapId ~= nil then
        setBitVectorMapParallelogram(self.mapId, 0, 0, self.size, 0, 0, self.size, 0, FHFieldMap.BITS, 0)
        self.revision = self.revision + 1
        FHDisplayMap:reset()
    end
end

---------------------------------------------------------------------------
-- Iteration
---------------------------------------------------------------------------

-- Calls visit(x, z, worldX, worldZ) for every cell of the field; returns the cell count.
function FHFieldMap:eachFieldCell(field, visit)
    local outline = FHUtil.getOutline(field)
    if outline == nil or self.mapId == nil then
        return 0
    end
    local x0, z0 = self:toCell(outline.minX, outline.minZ)
    local x1, z1 = self:toCell(outline.maxX, outline.maxZ)
    local count = 0
    for z = z0, z1 do
        for x = x0, x1 do
            local wx, wz = self:toWorld(x, z)
            if outline.polygon:getIsPosInside(wx, wz) then
                count = count + 1
                visit(x, z, wx, wz)
            end
        end
    end
    return count
end

-- Cells whose centre lies in the parallelogram start, start->width, start->height.
function FHFieldMap:eachCellInArea(sx, sz, wx, wz, hx, hz, visit)
    local ux, uz = wx - sx, wz - sz
    local vx, vz = hx - sx, hz - sz
    local det = ux * vz - uz * vx
    if self.mapId == nil or math.abs(det) < 0.0001 then
        return
    end
    local fx, fz = wx + vx, wz + vz
    local x0, z0 = self:toCell(math.min(sx, wx, hx, fx), math.min(sz, wz, hz, fz))
    local x1, z1 = self:toCell(math.max(sx, wx, hx, fx), math.max(sz, wz, hz, fz))
    for z = z0, z1 do
        for x = x0, x1 do
            local cx, cz = self:toWorld(x, z)
            local dx, dz = cx - sx, cz - sz
            local a = (dx * vz - dz * vx) / det
            local b = (ux * dz - uz * dx) / det
            if a >= 0 and a <= 1 and b >= 0 and b <= 1 then
                visit(x, z)
            end
        end
    end
end

local function direction(x, z)
    local length = math.sqrt(x * x + z * z)
    if length < 0.0001 then
        return 0, 0
    end
    return x / length, z / length
end

-- Corner points of a vehicle work area, grown by a margin on every side so
-- that every touched cell is covered. Work areas without depth (some
-- implements of other mods) become a narrow strip.
function FHFieldMap:getWorkAreaCorners(workArea, margin)
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then
        return nil
    end
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)

    local ax, az = direction(wx - sx, wz - sz)
    if math.abs((wx - sx) * (hz - sz) - (wz - sz) * (hx - sx)) < 0.0001 then
        hx, hz = sx - az, sz + ax
    end
    local bx, bz = direction(hx - sx, hz - sz)
    return sx - (ax + bx) * margin, sz - (az + bz) * margin,
        wx + (ax - bx) * margin, wz + (az - bz) * margin,
        hx + (bx - ax) * margin, hz + (bz - az) * margin
end

function FHFieldMap:eachCellUnderWorkArea(workArea, margin, visit)
    local sx, sz, wx, wz, hx, hz = self:getWorkAreaCorners(workArea, margin)
    if sx ~= nil then
        self:eachCellInArea(sx, sz, wx, wz, hx, hz, visit)
    end
end

function FHFieldMap.getWorkAreaCenter(workArea)
    if workArea == nil or workArea.width == nil or workArea.height == nil then
        return nil
    end
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    return (wx + hx) * 0.5, (wz + hz) * 0.5
end

---------------------------------------------------------------------------
-- Spraying
---------------------------------------------------------------------------

local function threatCategory(threatId)
    local threat = FHThreats.getById(threatId)
    return threat ~= nil and threat.category or nil
end

-- Removes threats of the category under a work area and protects the cells
-- that lie on a field. Returns the number of cured cells.
function FHFieldMap:sprayWorkArea(workArea, margin, category)
    local bit = FHFieldMap.PROTECTION_BIT[category]
    local cured = 0
    self:eachCellUnderWorkArea(workArea, margin, function(x, z)
        local severity, threatId = self:getThreat(x, z)
        if severity > 0 and threatCategory(threatId) == category then
            self:setThreat(x, z, 0, 0)
            cured = cured + 1
        end
        local protection = self:getProtection(x, z)
        if not hasBit(protection, bit) and FHUtil.getFieldAt(self:toWorld(x, z)) ~= nil then
            self:setProtection(x, z, protection + bit)
        end
    end)
    return cured
end

-- Number of cells of the area with a threat of the category (AI helpers).
function FHFieldMap:countThreatsInArea(sx, sz, wx, wz, hx, hz, category)
    local found = 0
    self:eachCellInArea(sx, sz, wx, wz, hx, hz, function(x, z)
        local severity, threatId = self:getThreat(x, z)
        if severity > 0 and threatCategory(threatId) == category then
            found = found + 1
        end
    end)
    return found
end

---------------------------------------------------------------------------
-- Whole fields
---------------------------------------------------------------------------

-- Threat and/or protection data of a field are removed (new crop season).
function FHFieldMap:resetField(field, threats, protection)
    self:eachFieldCell(field, function(x, z)
        local value = self:readRaw(x, z)
        if value > 0 then
            local severity, threatId = self:getThreat(x, z)
            local bits = self:getProtection(x, z)
            if threats then
                severity, threatId = 0, 0
            end
            if protection then
                bits = 0
            end
            self:writeRaw(x, z, compose(severity, threatId, bits))
        end
    end)
end

function FHFieldMap:removeThreat(field, threatId)
    self:eachFieldCell(field, function(x, z)
        local severity, cellThreatId = self:getThreat(x, z)
        if severity > 0 and (threatId == nil or cellThreatId == threatId) then
            self:setThreat(x, z, 0, 0)
        end
    end)
end

function FHFieldMap:removeProtection(field, category)
    local bit = FHFieldMap.PROTECTION_BIT[category]
    self:eachFieldCell(field, function(x, z)
        local protection = self:getProtection(x, z)
        if hasBit(protection, bit) then
            self:setProtection(x, z, protection - bit)
        end
    end)
end

-- {cells, infected, maxSeverity} of a threat (any threat when nil).
function FHFieldMap:inspect(field, threatId)
    local result = {cells = 0, infected = 0, maxSeverity = 0}
    result.cells = self:eachFieldCell(field, function(x, z)
        local severity, cellThreatId = self:getThreat(x, z)
        if severity > 0 and (threatId == nil or cellThreatId == threatId) then
            result.infected = result.infected + 1
            result.maxSeverity = math.max(result.maxSeverity, severity)
        end
    end)
    return result
end

-- Sprayed share (0..1) of the field against diseases and against pests.
function FHFieldMap:getCoverage(field)
    local disease, pest = 0, 0
    local cells = self:eachFieldCell(field, function(x, z)
        local protection = self:getProtection(x, z)
        if hasBit(protection, FHFieldMap.PROTECTION_BIT.disease) then
            disease = disease + 1
        end
        if hasBit(protection, FHFieldMap.PROTECTION_BIT.pest) then
            pest = pest + 1
        end
    end)
    if cells == 0 then
        return 0, 0
    end
    return disease / cells, pest / cells
end

-- Raises the cells of a threat to a severity. With share < 1 only cells where
-- a smooth noise is below the share are raised, so a stronger stage first
-- shows up in patches; a growing share fills the rest.
function FHFieldMap:raiseSeverity(field, severity, threatId, share, seed)
    share = share or 1
    self:eachFieldCell(field, function(x, z)
        local current, cellThreatId = self:getThreat(x, z)
        if current > 0 and current < severity and cellThreatId == threatId
            and (share >= 1 or FHUtil.noise(x / 4, z / 4, seed or 0) < share) then
            self:setThreat(x, z, severity, threatId)
        end
    end)
end

-- Up to count random infected cells of a threat, in world coordinates.
function FHFieldMap:pickInfected(field, count, threatId, minSeverity)
    local picked, seen = {}, 0
    minSeverity = minSeverity or 1
    self:eachFieldCell(field, function(x, z, wx, wz)
        local severity, cellThreatId = self:getThreat(x, z)
        if severity >= minSeverity and cellThreatId == threatId then
            seen = seen + 1
            if #picked < count then
                picked[#picked + 1] = {x = wx, z = wz}
            else
                local slot = math.random(1, seen)
                if slot <= count then
                    picked[slot] = {x = wx, z = wz}
                end
            end
        end
    end)
    return picked
end

-- Random point of the field at least `margin` from its bounding box edge;
-- with a category, the point must not be sprayed against it.
function FHFieldMap:randomPoint(field, margin, category)
    local outline = FHUtil.getOutline(field)
    if outline == nil or outline.minX + margin >= outline.maxX - margin or outline.minZ + margin >= outline.maxZ - margin then
        return nil
    end
    for _ = 1, 24 do
        local x = MathUtil.randomFloat(outline.minX + margin, outline.maxX - margin)
        local z = MathUtil.randomFloat(outline.minZ + margin, outline.maxZ - margin)
        if outline.polygon:getIsPosInside(x, z) then
            local cx, cz = self:toCell(x, z)
            if category == nil or not self:isProtected(cx, cz, category) then
                return x, z
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Infection patches
---------------------------------------------------------------------------

-- Shape of a patch: a main ellipse with one to three smaller lobes around
-- it, all with random size, stretch and direction.
function FHFieldMap.newPatch(radius)
    local lobes = {}
    local function addLobe(offsetX, offsetZ, rx, rz)
        local angle = MathUtil.randomFloat(0, math.pi)
        lobes[#lobes + 1] = {x = offsetX, z = offsetZ, rx = rx, rz = rz, cos = math.cos(angle), sin = math.sin(angle)}
    end

    local main = radius * MathUtil.randomFloat(0.85, 1.15)
    addLobe(0, 0, main, main * MathUtil.randomFloat(0.55, 0.95))
    for _ = 1, math.random(1, 3) do
        local heading = MathUtil.randomFloat(0, math.pi * 2)
        local distance = radius * MathUtil.randomFloat(0.35, 0.85)
        local size = radius * MathUtil.randomFloat(0.35, 0.65)
        addLobe(math.cos(heading) * distance, math.sin(heading) * distance, size, size * MathUtil.randomFloat(0.6, 1.0))
    end

    local reach = 0
    for _, lobe in ipairs(lobes) do
        reach = math.max(reach, math.sqrt(lobe.x * lobe.x + lobe.z * lobe.z) + math.max(lobe.rx, lobe.rz))
    end
    return {lobes = lobes, radius = radius, reach = reach * (1 + FHFieldMap.EDGE_NOISE), seed = math.random(1, 100000)}
end

-- 1 = on the edge of the nearest lobe, below 1 = inside.
local function patchDistance(patch, dx, dz)
    local nearest = math.huge
    for _, lobe in ipairs(patch.lobes) do
        local ox, oz = dx - lobe.x, dz - lobe.z
        local along = (ox * lobe.cos + oz * lobe.sin) / lobe.rx
        local across = (oz * lobe.cos - ox * lobe.sin) / lobe.rz
        nearest = math.min(nearest, math.sqrt(along * along + across * across))
    end
    return nearest
end

-- Infects an irregular patch around a world position, limited to the field.
-- Noise frays the edge and leaves a few healthy gaps. Returns infected cells.
function FHFieldMap:paintPatch(field, worldX, worldZ, patch, severity, threatId)
    local outline = FHUtil.getOutline(field)
    if outline == nil or self.mapId == nil then
        return 0
    end

    local edgeScale = math.max(self:getCellSize() * 2, patch.radius * 0.5)
    local gapScale = self:getCellSize() * 1.5
    local x0, z0 = self:toCell(worldX - patch.reach, worldZ - patch.reach)
    local x1, z1 = self:toCell(worldX + patch.reach, worldZ + patch.reach)
    local infected = 0
    for z = z0, z1 do
        for x = x0, x1 do
            local cx, cz = self:toWorld(x, z)
            local distance = patchDistance(patch, cx - worldX, cz - worldZ)
            local edge = 1 + FHFieldMap.EDGE_NOISE * (FHUtil.layeredNoise(cx / edgeScale, cz / edgeScale, patch.seed) * 2 - 1)
            if distance <= edge and outline.polygon:getIsPosInside(cx, cz) then
                local gap = distance > 0.3 and FHUtil.noise(cx / gapScale, cz / gapScale, patch.seed + 31) < FHFieldMap.GAP_SHARE * distance / edge
                if not gap and self:canInfect(x, z, severity, threatId) and self:setThreat(x, z, severity, threatId) then
                    infected = infected + 1
                end
            end
        end
    end

    -- a patch smaller than a cell still infects the cell under its centre
    if infected == 0 and outline.polygon:getIsPosInside(worldX, worldZ) then
        local x, z = self:toCell(worldX, worldZ)
        if self:canInfect(x, z, severity, threatId) and self:setThreat(x, z, severity, threatId) then
            infected = 1
        end
    end
    return infected
end

-- Lets an infection creep outward: healthy neighbours of infected cells get
-- infected with a chance shaped by noise, so it grows unevenly in fingers.
-- Returns the number of new cells (at most maxNew).
function FHFieldMap:creep(field, threatId, severity, chance, maxNew)
    local outline = FHUtil.getOutline(field)
    if outline == nil or self.mapId == nil or maxNew <= 0 then
        return 0
    end

    local size = self.size
    local infected, border, queued = {}, {}, {}
    self:eachFieldCell(field, function(x, z)
        local current, cellThreatId = self:getThreat(x, z)
        if current > 0 and cellThreatId == threatId then
            infected[z * size + x] = true
        end
    end)
    for cell in pairs(infected) do
        local x, z = cell % size, math.floor(cell / size)
        for _, step in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            local nx, nz = x + step[1], z + step[2]
            local key = nz * size + nx
            if nx >= 0 and nz >= 0 and nx < size and nz < size and not infected[key] and not queued[key] then
                queued[key] = true
                border[#border + 1] = key
            end
        end
    end

    -- random order, so the limit does not favour one side
    for i = #border, 2, -1 do
        local j = math.random(1, i)
        border[i], border[j] = border[j], border[i]
    end

    local seed, grown = math.random(1, 100000), 0
    for _, key in ipairs(border) do
        local x, z = key % size, math.floor(key / size)
        if math.random() < chance * (0.2 + 1.6 * FHUtil.noise(x / 3, z / 3, seed))
            and outline.polygon:getIsPosInside(self:toWorld(x, z))
            and self:canInfect(x, z, severity, threatId) and self:setThreat(x, z, severity, threatId) then
            grown = grown + 1
            if grown >= maxNew then
                break
            end
        end
    end
    return grown
end

---------------------------------------------------------------------------
-- Maintenance and network
---------------------------------------------------------------------------

-- Removes threat cells that no infected field claims (e.g. after a field
-- changed owner). Runs a few rows per call; returns true when done.
function FHFieldMap:sweep(job, rows, isInfectedField)
    local last = math.min(self.size - 1, job.row + rows - 1)
    for z = job.row, last do
        for x = 0, self.size - 1 do
            if read(self.mapId, x, z, FHFieldMap.SEVERITY) > 0 then
                local field = FHUtil.getFieldAt(self:toWorld(x, z))
                if field == nil or not isInfectedField(field) then
                    self:setThreat(x, z, 0, 0)
                end
            end
        end
    end
    job.row = last + 1
    return job.row >= self.size
end

-- Cells changed since the last call: {x, z, value}, at most maxCount.
function FHFieldMap:takePending(maxCount)
    local cells = {}
    for key in pairs(self.pending) do
        self.pending[key] = nil
        local x, z = key % self.size, math.floor(key / self.size)
        cells[#cells + 1] = {x = x, z = z, value = self:readRaw(x, z)}
        if #cells >= maxCount then
            break
        end
    end
    return cells
end

-- Non-empty cells of some rows for a joining client; returns the next row.
function FHFieldMap:collectRows(firstRow, rows, cells)
    local last = math.min(self.size - 1, firstRow + rows - 1)
    for z = firstRow, last do
        for x = 0, self.size - 1 do
            local value = self:readRaw(x, z)
            if value > 0 then
                cells[#cells + 1] = {x = x, z = z, value = value}
            end
        end
    end
    return last + 1
end

function FHFieldMap:applyRemote(cells, clearFirst)
    if self.mapId == nil then
        return
    end
    if clearFirst then
        self:clearAll()
    end
    for _, cell in ipairs(cells) do
        self:writeRaw(cell.x, cell.z, cell.value, true)
    end
end

---------------------------------------------------------------------------
-- Debug view (console: fhDebug)
---------------------------------------------------------------------------

function FHFieldMap:toggleDebug(radius)
    self.debugRadius = not self.debugRadius and FHUtil.clamp(tonumber(radius) or 50, 10, 200) or nil
    return self.debugRadius ~= nil and ("Field Health cell view on, radius " .. self.debugRadius .. " m") or "Field Health cell view off"
end

local function drawCellFrame(cx, y, cz, half, r, g, b)
    drawDebugLine(cx - half, y, cz - half, r, g, b, cx + half, y, cz - half, r, g, b)
    drawDebugLine(cx + half, y, cz - half, r, g, b, cx + half, y, cz + half, r, g, b)
    drawDebugLine(cx + half, y, cz + half, r, g, b, cx - half, y, cz + half, r, g, b)
    drawDebugLine(cx - half, y, cz + half, r, g, b, cx - half, y, cz - half, r, g, b)
end

function FHFieldMap:drawDebug()
    if self.debugRadius == nil or self.mapId == nil then
        return
    end
    local px, _, pz = FHUtil.getPlayerPosition()
    if px == nil then
        return
    end

    local half = self:getCellSize() * 0.45
    local x0, z0 = self:toCell(px - self.debugRadius, pz - self.debugRadius)
    local x1, z1 = self:toCell(px + self.debugRadius, pz + self.debugRadius)
    for z = z0, z1 do
        for x = x0, x1 do
            local severity, threatId = self:getThreat(x, z)
            local protection = self:getProtection(x, z)
            if severity > 0 or protection > 0 then
                local cx, cz = self:toWorld(x, z)
                local y = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz) + 0.1
                if protection > 0 then
                    drawCellFrame(cx, y, cz, half, protection == 3 and 1 or 0.2, protection == 2 and 0.3 or 0.9, 1)
                end
                if severity > 0 then
                    drawCellFrame(cx, y + 0.05 * severity, cz, half * 0.8, 1, 1 - severity * 0.3, 0.1)
                    if math.abs(cx - px) <= half * 3 and math.abs(cz - pz) <= half * 3 then
                        local threat = FHThreats.getById(threatId)
                        Utils.renderTextAtWorldPosition(cx, y + 0.3, cz, string.format("%s %d", threat ~= nil and threat.name or "?", severity), 0.012, 0, 1, 1, 1, 1)
                    end
                end
            end
        end
    end
end

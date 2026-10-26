-- Field Health: what the in-game map and the minimap show. Only growing crops
-- on fields of the local farm are drawn. One bit vector map holds a value per
-- layer, a second one the threat id of each cell:
--   protection (bits 0-1): 1 = not sprayed, 2 = one product, 3 = both products
--   disease    (bits 2-4): 1 = healthy, 2..4 = severity low, medium, high
--   pest       (bits 5-7): same as disease
FHDisplayMap = {}

FHDisplayMap.BITS = 8
FHDisplayMap.LAYERS = {
    protection = {first = 0, bits = 2},
    disease = {first = 2, bits = 3},
    pest = {first = 5, bits = 3},
    threatType = {first = 0, bits = FHThreats.ID_BITS, typeMap = true}
}
-- Fields are checked this often for sowing, harvest and owner changes (ms).
FHDisplayMap.SCAN_INTERVAL = 1000
-- Rows of a field drawn per frame when a field appears or disappears.
FHDisplayMap.ROWS_PER_FRAME = 24

local function writePoint(mapId, x, z, bits, value)
    if setBitVectorMapPoint ~= nil then
        setBitVectorMapPoint(mapId, x, z, 0, bits, value)
    else
        setBitVectorMapParallelogram(mapId, x, z, 1, 0, 0, 1, 0, bits, value)
    end
end

function FHDisplayMap:load()
    self.revision = 0
    self.visible = {}
    self.jobs = {}
    self.scanTimer = 0
    self.valueMapId, self.typeMapId = nil, nil
    -- a dedicated server shows no map
    if g_dedicatedServer ~= nil then
        return
    end
    local size = FHFieldMap.size
    self.valueMapId = createBitVectorMap("FieldHealthDisplay")
    loadBitVectorMapNew(self.valueMapId, size, size, FHDisplayMap.BITS, false)
    self.typeMapId = createBitVectorMap("FieldHealthDisplayTypes")
    loadBitVectorMapNew(self.typeMapId, size, size, FHThreats.ID_BITS, false)
end

function FHDisplayMap:unload()
    if self.valueMapId ~= nil then
        delete(self.valueMapId)
        delete(self.typeMapId)
    end
    self.valueMapId, self.typeMapId = nil, nil
    self.jobs = {}
end

-- Display value of a field cell (see the layer table above).
function FHDisplayMap.getValue(x, z)
    local severity, threatId = FHFieldMap:getThreat(x, z)
    local threat = severity > 0 and FHThreats.getById(threatId) or nil
    local protection = FHFieldMap:getProtection(x, z)

    local protectionValue = protection == 0 and 1 or (protection == 3 and 3 or 2)
    local disease = (threat ~= nil and threat.category == "disease") and severity + 1 or 1
    local pest = (threat ~= nil and threat.category == "pest") and severity + 1 or 1
    return protectionValue + disease * 4 + pest * 32, threat ~= nil and threatId or 0
end

function FHDisplayMap:draw(x, z, shown)
    local value, threatId = 0, 0
    if shown then
        value, threatId = FHDisplayMap.getValue(x, z)
    end
    writePoint(self.valueMapId, x, z, FHDisplayMap.BITS, value)
    writePoint(self.typeMapId, x, z, FHThreats.ID_BITS, threatId)
end

function FHDisplayMap:isShown(field)
    local entry = FHSimulation:getEntry(FHUtil.getFieldId(field))
    return entry ~= nil and entry.cropActive == true and FHUtil.getOwnerFarmId(field) == FHUtil.getLocalFarmId()
end

-- A cell of the field map changed.
function FHDisplayMap:onCellChanged(x, z)
    if self.valueMapId == nil then
        return
    end
    local field = FHUtil.getFieldAt(FHFieldMap:toWorld(x, z))
    if field ~= nil and self.visible[FHUtil.getFieldId(field)] then
        self:draw(x, z, true)
        self.revision = self.revision + 1
    end
end

-- Everything is drawn again, e.g. after the field map was replaced.
function FHDisplayMap:reset()
    if self.valueMapId == nil then
        return
    end
    local size = FHFieldMap.size
    setBitVectorMapParallelogram(self.valueMapId, 0, 0, size, 0, 0, size, 0, FHDisplayMap.BITS, 0)
    setBitVectorMapParallelogram(self.typeMapId, 0, 0, size, 0, 0, size, 0, FHThreats.ID_BITS, 0)
    self.visible = {}
    self.jobs = {}
    self.scanTimer = 0
    self.revision = self.revision + 1
end

function FHDisplayMap:update(dt)
    if self.valueMapId == nil or FHSimulation.fields == nil then
        return
    end

    self.scanTimer = self.scanTimer - dt
    if self.scanTimer <= 0 then
        self.scanTimer = FHDisplayMap.SCAN_INTERVAL
        for _, field in ipairs(g_fieldManager:getFields() or {}) do
            local fieldId = FHUtil.getFieldId(field)
            local shown = self:isShown(field)
            if fieldId ~= nil and shown ~= (self.visible[fieldId] == true) then
                self.visible[fieldId] = shown or nil
                self:queueField(field, shown)
            end
        end
    end

    self:runJob()
end

function FHDisplayMap:queueField(field, shown)
    local outline = FHUtil.getOutline(field)
    if outline ~= nil then
        local x0, z0 = FHFieldMap:toCell(outline.minX, outline.minZ)
        local x1, z1 = FHFieldMap:toCell(outline.maxX, outline.maxZ)
        table.insert(self.jobs, {outline = outline, shown = shown, row = z0, lastRow = z1, x0 = x0, x1 = x1})
    end
end

function FHDisplayMap:runJob()
    local job = self.jobs[1]
    if job == nil then
        return
    end
    local last = math.min(job.lastRow, job.row + FHDisplayMap.ROWS_PER_FRAME - 1)
    for z = job.row, last do
        for x = job.x0, job.x1 do
            if job.outline.polygon:getIsPosInside(FHFieldMap:toWorld(x, z)) then
                self:draw(x, z, job.shown)
            end
        end
    end
    job.row = last + 1
    self.revision = self.revision + 1
    if job.row > job.lastRow then
        table.remove(self.jobs, 1)
    end
end

-- Field Health: what the in-game map and the minimap show. Only growing crops
-- that can get threats on fields of the local farm are drawn (on a field split
-- into crops only the cells of the season crop). One bit vector map holds a value per
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
-- Shown fields are checked this often for a second crop on a part (ms).
FHDisplayMap.MIXED_INTERVAL = 15000

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
    self.mixed = {}
    self.filters = {}
    self.fullProtection = {}
    self.jobs = {}
    self.scanTimer = 0
    self.mixedTimer = 0
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

-- fullProtection: the field's crop is in the protected growth stage and
-- shows as protected against both kinds of threats
function FHDisplayMap:draw(x, z, shown, fullProtection)
    local value, threatId = 0, 0
    if shown then
        value, threatId = FHDisplayMap.getValue(x, z)
        if fullProtection then
            value = value - value % 4 + 3
        end
    end
    writePoint(self.valueMapId, x, z, FHDisplayMap.BITS, value)
    writePoint(self.typeMapId, x, z, FHThreats.ID_BITS, threatId)
end

-- Season crop the field shows, nil = not drawn.
function FHDisplayMap:getShownCrop(field)
    local entry = FHSimulation:getEntry(FHUtil.getFieldId(field))
    if entry == nil or entry.cropActive ~= true or FHUtil.getOwnerFarmId(field) ~= FHUtil.getLocalFarmId()
        or not FHThreats.canGetThreats(entry.cropFruitName) then
        return nil
    end
    return entry.cropFruitName or "?"
end

function FHDisplayMap:isShown(field)
    return self:getShownCrop(field) ~= nil
end

-- What a field shows: the crop name, marked when only a part has the crop.
function FHDisplayMap:getFieldView(field, fieldId, checkMixed)
    local crop = self:getShownCrop(field)
    if crop == nil then
        self.mixed[fieldId] = nil
        return nil
    end
    if checkMixed or self.mixed[fieldId] == nil or string.sub(self.visible[fieldId] or "", 1, #crop + 1) ~= crop .. "|" then
        self.mixed[fieldId] = FHRisk.isMixedField(field, crop) == true
    end
    local entry = FHSimulation:getEntry(fieldId)
    local ripe = entry ~= nil and entry.stageProtected and "|ripe" or ""
    return crop .. "|" .. (self.mixed[fieldId] and "part" or "all") .. ripe
end

-- A cell of the field map changed.
function FHDisplayMap:onCellChanged(x, z)
    if self.valueMapId == nil then
        return
    end
    local field = FHUtil.getFieldAt(FHFieldMap:toWorld(x, z))
    local fieldId = field ~= nil and FHUtil.getFieldId(field) or nil
    if fieldId ~= nil and self.visible[fieldId] then
        local filter = self.filters[fieldId]
        self:draw(x, z, filter == nil or filter(FHFieldMap:toWorld(x, z)), self.fullProtection[fieldId])
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
    self.mixed = {}
    self.filters = {}
    self.fullProtection = {}
    self.jobs = {}
    self.scanTimer = 0
    self.revision = self.revision + 1
end

function FHDisplayMap:update(dt)
    if self.valueMapId == nil or FHSimulation.fields == nil then
        return
    end

    self.scanTimer = self.scanTimer - dt
    self.mixedTimer = self.mixedTimer - dt
    if self.scanTimer <= 0 then
        self.scanTimer = FHDisplayMap.SCAN_INTERVAL
        local checkMixed = self.mixedTimer <= 0
        if checkMixed then
            self.mixedTimer = FHDisplayMap.MIXED_INTERVAL
        end
        for _, field in ipairs(g_fieldManager:getFields() or {}) do
            local fieldId = FHUtil.getFieldId(field)
            if fieldId ~= nil then
                local view = self:getFieldView(field, fieldId, checkMixed)
                if view ~= self.visible[fieldId] then
                    self.visible[fieldId] = view
                    local filter = nil
                    if view ~= nil and self.mixed[fieldId] then
                        filter = FHSimulation:getCropFilter(FHSimulation:getEntry(fieldId))
                    end
                    self.filters[fieldId] = filter
                    local entry = FHSimulation:getEntry(fieldId)
                    self.fullProtection[fieldId] = view ~= nil and entry ~= nil and entry.stageProtected or nil
                    self:queueField(field, view ~= nil, filter, self.fullProtection[fieldId])
                end
            end
        end
    end

    self:runJob()
end

function FHDisplayMap:queueField(field, shown, filter, fullProtection)
    local outline = FHUtil.getOutline(field)
    if outline ~= nil then
        local x0, z0 = FHFieldMap:toCell(outline.minX, outline.minZ)
        local x1, z1 = FHFieldMap:toCell(outline.maxX, outline.maxZ)
        table.insert(self.jobs, {outline = outline, shown = shown, filter = filter, fullProtection = fullProtection,
            row = z0, lastRow = z1, x0 = x0, x1 = x1})
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
            local wx, wz = FHFieldMap:toWorld(x, z)
            if job.outline.polygon:getIsPosInside(wx, wz) then
                self:draw(x, z, job.shown and (job.filter == nil or job.filter(wx, wz)), job.fullProtection)
            end
        end
    end
    job.row = last + 1
    self.revision = self.revision + 1
    if job.row > job.lastRow then
        table.remove(self.jobs, 1)
    end
end

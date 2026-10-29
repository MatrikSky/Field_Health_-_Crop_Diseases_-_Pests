-- Field Health: the simulation. Crop seasons, the daily infection check, how
-- threats grow, spray treatment and protection. It runs on the server only;
-- clients receive the results (FHNetwork).
FHSimulation = {}

FHSimulation.TUNING = {
    -- field states are unreliable right after loading (ms)
    startupDelay = 5000,
    seasonWatchInterval = 250,
    seasonWatchFields = 4,
    dailyFieldsPerFrame = 2,
    -- fields are checked again this long after they were sprayed (ms)
    rescanDelay = 3000,
    sweepRowsPerFrame = 16,
    -- days a crop grows before a threat may appear
    minActiveDays = 2,
    -- Crops with many common threats get one more often: the sum of the
    -- prevalences of a crop's threats against this reference, within limits.
    prevalenceReference = 2.5,
    cropPressureMin = 0.5,
    cropPressureMax = 1.4,
    -- largest share of a field a threat covers per severity (times the "spread" setting)
    maxInfectedShare = {0.015, 0.03, 0.05},
    -- new infection: 1-2 patches; radius between min and max, small ones more common
    outbreakPatchesMin = 1,
    outbreakPatchesMax = 2,
    outbreakRadiusMin = 4.0,
    outbreakRadiusMax = 10.0,
    -- a patch never covers more than this share of a small field
    outbreakMaxFieldShare = 0.02,
    -- daily growth: chance per severity of a healthy neighbour cell, plus a
    -- few small new patches nearby, mostly in the direction of the wind
    creepChance = 0.12,
    satellitesPerDay = 2,
    satelliteDistanceMin = 4.0,
    satelliteDistanceMax = 12.0,
    satelliteRadiusMin = 2.0,
    satelliteRadiusMax = 5.0,
    -- days for a new stage to cover the whole infected area
    stageSpreadDays = 3,
    -- jump to a touching player field: daily chance at high severity and the
    -- largest distance between an infected cell and the other field (m)
    neighbourChance = {pest = 0.04, disease = 0.02},
    neighbourReach = 8.0,
    -- crop losses start at this severity, in small patches inside the infection
    damageSeverity = 3,
    damageRadiusMin = 1.0,
    damageRadiusMax = 2.0
}

-- Names of the per-category values of a field entry.
FHSimulation.SLOT = {
    disease = {
        key = "diseaseKey", state = "diseaseState", stageDays = "diseaseStageDays", used = "diseaseUsed",
        pressure = "diseasePressure", target = "diseasePressureTarget", protection = "diseaseProtection",
        sprayDay = "diseaseSprayDay", risk = "diseaseRisk", cause = "diseaseCause", chance = "diseaseChance"
    },
    pest = {
        key = "pestKey", state = "pestState", stageDays = "pestStageDays", used = "pestUsed",
        pressure = "pestPressure", target = "pestPressureTarget", protection = "pestProtection",
        sprayDay = "pestSprayDay", risk = "pestRisk", cause = "pestCause", chance = "pestChance"
    }
}

-- State of a field. "save": stored in the savegame, "net": sent to clients
-- (they need it for the HUD, the map and the console).
FHSimulation.ENTRY = {
    {name = "cropActive", type = "bool", default = false, save = true, net = true},
    {name = "cropFruitName", type = "string", save = true, net = true},
    {name = "lastMainCropName", type = "string", save = true},
    {name = "previousCropFruitName", type = "string", save = true, net = true},
    {name = "catchCropPending", type = "bool", default = false, save = true},
    {name = "catchCropBefore", type = "bool", default = false, save = true, net = true},
    {name = "fertilizerFlags", type = "int", default = 0, save = true, net = true},
    {name = "activeDays", type = "int", default = 0, save = true, net = true}
}
for _, category in ipairs(FHThreats.CATEGORIES) do
    local slot = FHSimulation.SLOT[category]
    for _, def in ipairs({
        {name = slot.key, type = "string", save = true, net = true},
        {name = slot.state, type = "int", default = 0, save = true, net = true},
        {name = slot.stageDays, type = "int", default = 0, save = true},
        {name = slot.used, type = "bool", default = false, save = true, net = true},
        {name = slot.pressure, type = "float", default = 0, save = true},
        {name = slot.target, type = "float", save = true},
        {name = slot.protection, type = "float", default = 0, save = true, net = true},
        {name = slot.sprayDay, type = "int", save = true},
        {name = slot.risk, type = "float", default = 1, save = true, net = true},
        {name = slot.cause, type = "string", save = true, net = true}
    }) do
        table.insert(FHSimulation.ENTRY, def)
    end
end

function FHSimulation.newEntry()
    local entry = {}
    for _, def in ipairs(FHSimulation.ENTRY) do
        entry[def.name] = def.default
    end
    return entry
end

-- Infection pressure a field can take this season before a threat appears.
-- With an exponential target the chance of a threat per season is
-- 1 - exp(-pressure of the whole season), see buildPressure.
local function rollPressureTarget()
    return -math.log(1 - math.random() * 0.999999)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function FHSimulation:load()
    FHWeather:reset()
    self.fields = {}
    self.farmThreats = {}
    self.dailyQueue = {}
    self.rescans = {}
    self.sweepJob = nil
    self.startupTimer = FHSimulation.TUNING.startupDelay
    self.watchTimer = 0
    self.watchIndex = 1
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

-- After the savegame data was read: fields with crops are checked soon.
function FHSimulation:onDataLoaded(mapLoadedFromFile)
    if mapLoadedFromFile then
        self.sweepJob = {row = 0}
    end
    local delay = FHSimulation.TUNING.rescanDelay
    for fieldId, entry in pairs(self.fields) do
        if entry.cropActive then
            self.rescans[fieldId] = delay
            delay = delay + 50
        end
    end
end

function FHSimulation:unload()
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
    self.fields = nil
    self.dailyQueue = {}
    self.rescans = {}
end

function FHSimulation:getEntry(fieldId)
    return self.fields ~= nil and fieldId ~= nil and self.fields[fieldId] or nil
end

function FHSimulation:getOrCreateEntry(fieldId)
    local entry = self.fields[fieldId]
    if entry == nil then
        entry = FHSimulation.newEntry()
        self.fields[fieldId] = entry
    end
    return entry
end

function FHSimulation:getProtection(entry, category)
    return entry[FHSimulation.SLOT[category].protection] or 0
end

function FHSimulation:getActiveThreat(entry, category)
    return FHThreats.get(entry[FHSimulation.SLOT[category].key])
end

function FHSimulation:clearThreat(entry, category)
    local slot = FHSimulation.SLOT[category]
    entry[slot.key] = nil
    entry[slot.state] = 0
    entry[slot.stageDays] = 0
end

function FHSimulation:update(dt)
    if g_server == nil or self.fields == nil then
        return
    end
    FHWeather:update()
    if self.startupTimer > 0 then
        self.startupTimer = self.startupTimer - dt
        return
    end
    self:watchSeasons(dt)
    self:runDailyQueue()
    self:runRescans(dt)
    self:runSweep()
end

---------------------------------------------------------------------------
-- Crop seasons
---------------------------------------------------------------------------

-- Detects sowing and harvest; returns the entry and the field snapshot.
function FHSimulation:checkSeason(field)
    local fieldId = FHUtil.getFieldId(field)
    local snapshot = fieldId ~= nil and FHRisk.getFieldSnapshot(field) or nil
    if snapshot == nil then
        return nil
    end

    local entry = self:getOrCreateEntry(fieldId)
    if snapshot.isActiveCrop then
        if not entry.cropActive or entry.cropFruitName ~= snapshot.fruitName then
            self:startSeason(field, entry, snapshot)
        end
    elseif entry.cropActive then
        self:endSeason(field, entry)
    end
    return entry, snapshot
end

function FHSimulation:startSeason(field, entry, snapshot)
    if snapshot.isCatchCrop then
        -- catch crops do not count for the rotation; they help the next main crop
        entry.catchCropPending = true
    else
        if entry.lastMainCropName ~= nil then
            entry.previousCropFruitName = entry.lastMainCropName
        end
        entry.lastMainCropName = snapshot.fruitName
        entry.catchCropBefore = entry.catchCropPending == true
        entry.catchCropPending = false
    end

    entry.cropFruitName = snapshot.fruitName
    entry.cropActive = true
    entry.activeDays = 0
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local slot = FHSimulation.SLOT[category]
        entry[slot.used] = false
        entry[slot.pressure] = 0
        entry[slot.target] = rollPressureTarget()
    end
    self:resetSeasonState(field, entry)
end

-- Fertilizer spread after the harvest belongs to the next crop.
function FHSimulation:endSeason(field, entry)
    entry.cropActive = false
    entry.activeDays = 0
    entry.fertilizerFlags = 0
    self:resetSeasonState(field, entry)
end

-- Threats and spray protection belong to one crop season.
function FHSimulation:resetSeasonState(field, entry)
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local slot = FHSimulation.SLOT[category]
        self:clearThreat(entry, category)
        entry[slot.protection] = 0
        entry[slot.sprayDay] = nil
        entry[slot.risk] = 1
        entry[slot.cause] = nil
    end
    FHFieldMap:resetField(field, true, true)
end

function FHSimulation:watchSeasons(dt)
    self.watchTimer = self.watchTimer - dt
    if self.watchTimer > 0 then
        return
    end
    self.watchTimer = FHSimulation.TUNING.seasonWatchInterval

    local fields = g_fieldManager:getFields() or {}
    for _ = 1, math.min(FHSimulation.TUNING.seasonWatchFields, #fields) do
        if self.watchIndex > #fields then
            self.watchIndex = 1
        end
        self:checkSeason(fields[self.watchIndex])
        self.watchIndex = self.watchIndex + 1
    end
end

-- Called whenever fertilizer, manure, slurry or digestate is spread.
function FHSimulation:recordFertilizer(x, z, sprayTypeName)
    if self.fields == nil or FHRisk.FERTILIZERS[sprayTypeName] == nil then
        return
    end
    local fieldId = FHUtil.getFieldId(FHUtil.getFieldAt(x, z))
    if fieldId ~= nil then
        local entry = self:getOrCreateEntry(fieldId)
        entry.fertilizerFlags = FHRisk.addFertilizerFlag(entry.fertilizerFlags or 0, sprayTypeName)
    end
end

---------------------------------------------------------------------------
-- Daily check
---------------------------------------------------------------------------

function FHSimulation:onDayChanged()
    if g_server ~= nil then
        FHWeather:closeDay()
        self:queueDay()
    end
end

function FHSimulation:queueDay()
    for _, field in ipairs(g_fieldManager:getFields() or {}) do
        table.insert(self.dailyQueue, field)
    end
end

function FHSimulation:runDailyQueue()
    for _ = 1, FHSimulation.TUNING.dailyFieldsPerFrame do
        local field = table.remove(self.dailyQueue, 1)
        if field == nil then
            return
        end
        self:processDay(field)
    end
end

function FHSimulation:updateRisk(entry, snapshot)
    local evaluations = {}
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local slot = FHSimulation.SLOT[category]
        local evaluation = FHRisk.evaluateCategory(snapshot, entry, category)
        entry[slot.risk] = evaluation.multiplier
        entry[slot.cause] = evaluation.mainCause
        evaluations[category] = evaluation
    end
    return evaluations
end

function FHSimulation:processDay(field)
    local entry, snapshot = self:checkSeason(field)
    if entry == nil or not entry.cropActive then
        return
    end

    entry.activeDays = entry.activeDays + 1
    local evaluations = self:updateRisk(entry, snapshot)
    self:expireProtection(field, entry)

    -- only fields of player farms get threats
    if not FHUtil.isPlayerField(field) then
        if entry.diseaseKey ~= nil or entry.pestKey ~= nil then
            FHFieldMap:removeThreat(field, nil)
            self:clearThreat(entry, "disease")
            self:clearThreat(entry, "pest")
        end
        return
    end
    if not FHSettings.isOn("enabled") then
        return
    end

    -- a threat the crop can no longer get (e.g. fodder crops switched off) ends
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local threat = self:getActiveThreat(entry, category)
        if threat ~= nil and not FHThreats.attacks(threat, snapshot.fruitName) then
            FHFieldMap:removeThreat(field, threat.id)
            self:clearThreat(entry, category)
        end
    end

    for _, category in ipairs(FHThreats.CATEGORIES) do
        if self:getActiveThreat(entry, category) ~= nil then
            self:advanceThreat(field, entry, category)
        else
            self:buildPressure(field, entry, snapshot, category, evaluations[category])
        end
    end
end

-- Share of the season pressure each threat of a crop gets: its prevalence
-- against the sum of the crop's threats, times how strongly the crop is
-- attacked overall (crops with many common threats more often).
function FHSimulation.getCropPressureScale(threats)
    local tuning = FHSimulation.TUNING
    local sum = 0
    for _, item in ipairs(threats) do
        sum = sum + item.threat.prevalence
    end
    if sum <= 0 then
        return 0
    end
    return FHUtil.clamp(sum / tuning.prevalenceReference, tuning.cropPressureMin, tuning.cropPressureMax) / sum
end

-- Today's infection pressure of each threat of the crop. A threat adds its
-- share of the season pressure spread over its months of activity, so on a
-- field that grows through all of them it reaches its full share; outside its
-- months and growth stages it adds nothing. Risk and weather scale it.
function FHSimulation:getDailyHazards(snapshot, category, evaluation)
    local chance = FHSettings.get(FHSimulation.SLOT[category].chance)
    local hazards, total = {}, 0
    if chance <= 0 then
        return hazards, total
    end
    local seasonPressure = -math.log(1 - math.min(chance, 0.99))
    local scale = FHSimulation.getCropPressureScale(evaluation.threats)
    local month, days = FHUtil.getMonth(), FHUtil.getDaysPerPeriod()
    for _, item in ipairs(evaluation.threats) do
        local threat = item.threat
        local timing = FHThreats.getTiming(threat, snapshot.stage, month)
        if timing > 0 then
            local hazard = seasonPressure * scale * threat.prevalence * item.multiplier * timing * FHWeather:getFactor(threat)
                / (threat.exposure * days)
            hazards[#hazards + 1] = {threat = threat, weight = hazard}
            total = total + hazard
        end
    end
    return hazards, total
end

-- Infection pressure grows during the season; when it reaches the field's
-- target, a threat active today appears unless the field is sprayed. The
-- threat is picked by today's pressure of each threat.
function FHSimulation:buildPressure(field, entry, snapshot, category, evaluation)
    local slot = FHSimulation.SLOT[category]
    if entry[slot.used] or not evaluation.hasThreats then
        return
    end

    local hazards, total = self:getDailyHazards(snapshot, category, evaluation)
    entry[slot.pressure] = (entry[slot.pressure] or 0) + total

    entry[slot.target] = entry[slot.target] or rollPressureTarget()
    if entry[slot.pressure] < entry[slot.target] or entry.activeDays < FHSimulation.TUNING.minActiveDays or #hazards == 0 then
        return
    end

    -- this season's infection happens now
    entry[slot.used] = true
    local fieldId = FHUtil.getFieldId(field)
    if self:getProtection(entry, category) >= FHSettings.get("protectionThreshold") then
        FHUtil.trace("field %s: %s infection stopped by spraying", tostring(fieldId), category)
        return
    end
    local farmId = FHUtil.getOwnerFarmId(field)
    if not self:farmMayGetThreat(farmId) then
        FHUtil.trace("field %s: %s infection skipped by the farm limit", tostring(fieldId), category)
        return
    end
    self:startThreat(field, entry, FHRisk.pickCandidate(hazards), farmId)
end

function FHSimulation:startThreat(field, entry, threat, farmId)
    if threat == nil or self:placeOutbreak(field, threat, 1) <= 0 then
        return false
    end
    local slot = FHSimulation.SLOT[threat.category]
    entry[slot.key] = threat.key
    entry[slot.state] = 1
    entry[slot.stageDays] = 0
    entry[slot.used] = true
    self:countFarmThreat(farmId)
    self:alert(field, entry, threat, "new")
    FHUtil.trace("field %s: new threat %s", tostring(FHUtil.getFieldId(field)), threat.key)
    return true
end

---------------------------------------------------------------------------
-- Infections
---------------------------------------------------------------------------

-- Random patch radius: small patches are more common, the "patch size"
-- setting scales them and small fields get small patches.
function FHSimulation:rollPatchRadius(field)
    local tuning = FHSimulation.TUNING
    local radius = tuning.outbreakRadiusMin + (tuning.outbreakRadiusMax - tuning.outbreakRadiusMin) * math.random() ^ 1.6
    radius = radius * FHSettings.get("patchSize")

    local cellSize = FHFieldMap:getCellSize()
    local fieldArea = FHFieldMap:countFieldCells(field) * cellSize * cellSize
    return math.max(cellSize, math.min(radius, math.sqrt(fieldArea * tuning.outbreakMaxFieldShare / math.pi)))
end

-- One or two irregular patches on parts of the field that are not sprayed
-- against the threat. Returns the number of infected cells.
function FHSimulation:placeOutbreak(field, threat, severity)
    local tuning = FHSimulation.TUNING
    local infected = 0
    for _ = 1, math.random(tuning.outbreakPatchesMin, tuning.outbreakPatchesMax) do
        for _ = 1, 6 do
            local patch = FHFieldMap.newPatch(self:rollPatchRadius(field))
            local x, z = FHFieldMap:randomPoint(field, patch.radius * 0.5, threat.category)
            local placed = x ~= nil and FHFieldMap:paintPatch(field, x, z, patch, severity, threat.id) or 0
            if placed > 0 then
                infected = infected + placed
                break
            end
        end
    end
    return infected
end

function FHSimulation:getStageDays()
    return math.max(1, math.ceil(FHUtil.getDaysPerPeriod() * FHSettings.get("progression")))
end

-- Daily course of a threat: it gets worse, grows a little up to a small share
-- of the field, may jump to a touching neighbour field and destroys crop
-- when severe.
function FHSimulation:advanceThreat(field, entry, category)
    local tuning = FHSimulation.TUNING
    local slot = FHSimulation.SLOT[category]
    local threat = self:getActiveThreat(entry, category)
    local state = FHFieldMap:inspect(field, threat.id)
    if state.infected == 0 then
        self:clearThreat(entry, category)
        return
    end

    local severity = state.maxSeverity
    entry[slot.stageDays] = entry[slot.stageDays] + 1
    if severity < FHThreats.MAX_SEVERITY and entry[slot.stageDays] >= self:getStageDays() then
        severity = severity + 1
        entry[slot.stageDays] = 0
        if severity == FHThreats.MAX_SEVERITY then
            self:alert(field, entry, threat, "severe")
        end
    end
    entry[slot.state] = severity

    -- a new stage covers the infected area in patches over a few days
    local share = math.min(1, (entry[slot.stageDays] + 1) / tuning.stageSpreadDays)
    FHFieldMap:raiseSeverity(field, severity, threat.id, share, (FHUtil.getFieldId(field) or 0) * 31 + threat.id)

    local limit = math.floor(state.cells * tuning.maxInfectedShare[severity] * FHSettings.get("spread"))
    if state.infected < limit then
        self:growThreat(field, threat, severity, limit - state.infected)
    end

    self:tryNeighbourJump(field, threat, severity)

    local patches = FHSettings.get("damage")
    if severity >= tuning.damageSeverity and patches > 0 then
        for _, spot in ipairs(FHFieldMap:pickInfected(field, patches, threat.id, tuning.damageSeverity)) do
            FHCropDamage.destroyAt(field, spot.x, spot.z, MathUtil.randomFloat(tuning.damageRadiusMin, tuning.damageRadiusMax))
        end
    end
end

-- Growth by at most maxNew cells: the edge creeps outward unevenly and now
-- and then a small new patch appears nearby, mostly downwind. New cells start
-- one stage lower.
function FHSimulation:growThreat(field, threat, severity, maxNew)
    local tuning = FHSimulation.TUNING
    local newSeverity = math.max(1, severity - 1)
    maxNew = maxNew - FHFieldMap:creep(field, threat.id, newSeverity, tuning.creepChance * severity, maxNew)

    local wind = MathUtil.randomFloat(0, math.pi * 2)
    for _, origin in ipairs(FHFieldMap:pickInfected(field, math.random(0, tuning.satellitesPerDay), threat.id)) do
        if maxNew <= 0 then
            break
        end
        local heading = wind + MathUtil.randomFloat(-1.0, 1.0)
        local distance = MathUtil.randomFloat(tuning.satelliteDistanceMin, tuning.satelliteDistanceMax)
        local patch = FHFieldMap.newPatch(MathUtil.randomFloat(tuning.satelliteRadiusMin, tuning.satelliteRadiusMax) * FHSettings.get("patchSize"))
        maxNew = maxNew - FHFieldMap:paintPatch(field, origin.x + math.cos(heading) * distance, origin.z + math.sin(heading) * distance,
            patch, newSeverity, threat.id)
    end
end

-- A threat near the edge of a field may jump to a player field that touches
-- it or lies across a narrow strip. Pests jump more often than diseases,
-- and only from the medium stage on.
function FHSimulation:tryNeighbourJump(field, threat, severity)
    local tuning = FHSimulation.TUNING
    local chance = (tuning.neighbourChance[threat.category] or 0) * FHSettings.get("neighbourSpread") * (severity - 1) / (FHThreats.MAX_SEVERITY - 1)
    if chance <= 0 or math.random() >= chance then
        return false
    end

    local step = FHFieldMap:getCellSize()
    for _, origin in ipairs(FHFieldMap:pickInfected(field, 24, threat.id)) do
        for side = 0, 7 do
            local heading = side * math.pi / 4 + MathUtil.randomFloat(-0.3, 0.3)
            local dx, dz = math.cos(heading), math.sin(heading)
            for distance = step, tuning.neighbourReach, step do
                local x, z = origin.x + dx * distance, origin.z + dz * distance
                local other = FHUtil.getFieldAt(x, z)
                if other ~= nil and other ~= field then
                    if self:infectNeighbour(other, threat, x, z) then
                        return true
                    end
                    break
                end
            end
        end
    end
    return false
end

-- Starts a threat that came from a neighbour field at (x, z): only player
-- fields with a crop the threat attacks in this growth stage and month, no
-- threat of the kind yet this season and no full spray protection.
function FHSimulation:infectNeighbour(field, threat, x, z)
    if not FHUtil.isPlayerField(field) or not FHSettings.isOn("enabled") then
        return false
    end
    local entry = self:getEntry(FHUtil.getFieldId(field))
    local slot = FHSimulation.SLOT[threat.category]
    if entry == nil or not entry.cropActive or entry[slot.used] or self:getActiveThreat(entry, threat.category) ~= nil
        or self:getProtection(entry, threat.category) >= FHSettings.get("protectionThreshold") then
        return false
    end

    local snapshot = FHRisk.getFieldSnapshot(field)
    if snapshot == nil or not snapshot.isActiveCrop or FHThreats.getTiming(threat, snapshot.stage, FHUtil.getMonth()) <= 0
        or not FHThreats.attacks(threat, snapshot.fruitName) then
        return false
    end
    local farmId = FHUtil.getOwnerFarmId(field)
    if not self:farmMayGetThreat(farmId) then
        return false
    end
    if FHFieldMap:paintPatch(field, x, z, FHFieldMap.newPatch(self:rollPatchRadius(field) * 0.5), 1, threat.id) <= 0 then
        return false
    end

    entry[slot.key] = threat.key
    entry[slot.state] = 1
    entry[slot.stageDays] = 0
    entry[slot.used] = true
    self:countFarmThreat(farmId)
    self:alert(field, entry, threat, "neighbour")
    FHUtil.trace("field %s: %s came from a neighbouring field", tostring(FHUtil.getFieldId(field)), threat.key)
    return true
end

-- With a limited spray duration, the protection of a category ends a fixed
-- time after the last spraying of the field.
function FHSimulation:expireProtection(field, entry)
    local periods = FHSettings.get("protectionDuration")
    if periods <= 0 then
        return
    end
    local days = math.max(1, math.floor(periods * FHUtil.getDaysPerPeriod() + 0.5))
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local slot = FHSimulation.SLOT[category]
        if entry[slot.sprayDay] ~= nil and FHUtil.getDay() - entry[slot.sprayDay] >= days then
            FHFieldMap:removeProtection(field, category)
            entry[slot.protection] = 0
            entry[slot.sprayDay] = nil
        end
    end
end

function FHSimulation:farmMayGetThreat(farmId)
    local limit = FHSettings.get("farmLimit")
    local record = farmId ~= nil and self.farmThreats[farmId] or nil
    return limit <= 0 or record == nil or record.year ~= FHUtil.getYear() or record.count < limit
end

function FHSimulation:countFarmThreat(farmId)
    if farmId == nil then
        return
    end
    local year = FHUtil.getYear()
    local record = self.farmThreats[farmId]
    if record == nil or record.year ~= year then
        record = {year = year, count = 0}
        self.farmThreats[farmId] = record
    end
    record.count = record.count + 1
end

---------------------------------------------------------------------------
-- Spraying
---------------------------------------------------------------------------

-- Cells touched at the edge of a work area count as sprayed, so treatment
-- leaves no thin stripes.
function FHSimulation:getSprayMargin()
    return math.max(0.75, FHFieldMap:getCellSize() * 0.75)
end

-- Every active sprayer section with insecticide or fungicide ends here.
function FHSimulation:onSprayed(workArea, category)
    if self.fields == nil then
        return
    end
    FHFieldMap:sprayWorkArea(workArea, self:getSprayMargin(), category)

    local x, z = FHFieldMap.getWorkAreaCenter(workArea)
    local fieldId = FHUtil.getFieldId(x ~= nil and FHUtil.getFieldAt(x, z) or nil)
    if fieldId ~= nil then
        self:getOrCreateEntry(fieldId)[FHSimulation.SLOT[category].sprayDay] = FHUtil.getDay()
        self.rescans[fieldId] = FHSimulation.TUNING.rescanDelay
    end
end

function FHSimulation:runRescans(dt)
    for fieldId, remaining in pairs(self.rescans) do
        remaining = remaining - dt
        if remaining <= 0 then
            self.rescans[fieldId] = nil
            self:rescan(fieldId)
        else
            self.rescans[fieldId] = remaining
        end
    end
end

-- Protection share, risk and threat states of a field from the field map.
function FHSimulation:rescan(fieldId)
    local field = FHUtil.getField(fieldId)
    local entry = self:getEntry(fieldId)
    if field == nil or entry == nil or not entry.cropActive then
        return
    end

    entry.diseaseProtection, entry.pestProtection = FHFieldMap:getCoverage(field)
    self:updateRisk(entry, FHRisk.getFieldSnapshot(field))
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local threat = self:getActiveThreat(entry, category)
        if threat ~= nil then
            local state = FHFieldMap:inspect(field, threat.id)
            if state.infected == 0 then
                self:clearThreat(entry, category)
            else
                entry[FHSimulation.SLOT[category].state] = state.maxSeverity
            end
        end
    end
end

function FHSimulation:runSweep()
    if self.sweepJob == nil then
        return
    end
    -- threat cells of fields without a known threat are leftovers
    local function isInfected(field)
        local entry = self:getEntry(FHUtil.getFieldId(field))
        return entry ~= nil and entry.cropActive and (entry.diseaseKey ~= nil or entry.pestKey ~= nil) and FHUtil.isPlayerField(field)
    end
    if FHFieldMap:sweep(self.sweepJob, FHSimulation.TUNING.sweepRowsPerFrame, isInfected) then
        self.sweepJob = nil
    end
end

-- AI helpers spray while the field is not protected yet (preventive) or
-- while threats of the category remain in the area.
function FHSimulation:isSprayNeeded(sx, sz, wx, wz, hx, hz, category)
    local field = FHUtil.getFieldAt((wx + hx) * 0.5, (wz + hz) * 0.5)
    local entry = self:getEntry(FHUtil.getFieldId(field))
    if field ~= nil and entry == nil then
        -- not looked at yet (right after loading): the game decides
        return nil
    end
    if entry == nil or not entry.cropActive then
        return false
    end
    if self:getProtection(entry, category) < FHSettings.get("protectionThreshold") then
        return true
    end
    return FHFieldMap:countThreatsInArea(sx, sz, wx, wz, hx, hz, category) > 0
end

-- Lowest protection of the growing fields of a farmland, nil without crops.
function FHSimulation:getFarmlandProtection(farmlandId)
    local disease, pest, found = 1, 1, false
    for _, field in ipairs(g_fieldManager:getFields() or {}) do
        if field.farmland ~= nil and field.farmland.id == farmlandId then
            local entry = self:getEntry(FHUtil.getFieldId(field))
            if entry ~= nil and entry.cropActive then
                found = true
                disease = math.min(disease, entry.diseaseProtection or 0)
                pest = math.min(pest, entry.pestProtection or 0)
            end
        end
    end
    if found then
        return disease, pest
    end
    return nil
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------

function FHSimulation:alert(field, entry, threat, kind)
    if not FHSettings.isOn("notifications") then
        return
    end
    local message = {
        kind = kind,
        fieldId = FHUtil.getFieldId(field),
        threatKey = threat.key,
        fruitName = entry.cropFruitName,
        farmId = FHUtil.getOwnerFarmId(field)
    }
    if FHUtil.isMultiplayer() then
        FHSyncEvent.broadcastAlert(message)
    end
    self:showAlert(message)
end

-- Every player builds the text in their own language.
function FHSimulation:showAlert(message)
    if g_currentMission == nil or (message.farmId ~= nil and FHUtil.getLocalFarmId() ~= message.farmId) then
        return
    end
    local threat = FHThreats.get(message.threatKey)
    if threat == nil then
        return
    end
    local textKey = ({severe = "fh_alert_severe", neighbour = "fh_alert_neighbour"})[message.kind] or "fh_alert_new"
    local product = threat.category == "pest" and "fh_fillType_insecticide" or "fh_fillType_fungicide"
    local text = string.format(FHUtil.text(textKey), tostring(message.fieldId), FHUtil.getCropTitle(message.fruitName),
        FHUtil.text(threat.key), FHUtil.text(product))
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
end

---------------------------------------------------------------------------
-- Admin tools (console)
---------------------------------------------------------------------------

function FHSimulation:forceThreat(fieldId, threatKey, severity)
    local field = FHUtil.getField(fieldId)
    local entry = self:getEntry(fieldId)
    local threat = FHThreats.get(threatKey)
    if field == nil then
        return "Unknown field: " .. tostring(fieldId)
    elseif entry == nil or not entry.cropActive then
        return "Field " .. tostring(fieldId) .. " has no growing crop"
    elseif threat == nil then
        return "Unknown threat: " .. tostring(threatKey) .. " (see fhList)"
    end

    local slot = FHSimulation.SLOT[threat.category]
    local previous = self:getActiveThreat(entry, threat.category)
    if previous ~= nil then
        FHFieldMap:removeThreat(field, previous.id)
    end
    severity = FHUtil.clamp(tonumber(severity) or 1, 1, FHThreats.MAX_SEVERITY)
    local placed = self:placeOutbreak(field, threat, severity)
    if placed <= 0 then
        self:clearThreat(entry, threat.category)
        return "Could not place the threat (is the field sprayed against it?)"
    end

    entry[slot.key] = threat.key
    entry[slot.state] = severity
    entry[slot.stageDays] = 0
    entry[slot.used] = true
    return string.format("Field %d: %s, severity %d, %d cells", fieldId, threat.key, severity, placed)
end

function FHSimulation:clearFieldThreats(fieldId)
    local field = FHUtil.getField(fieldId)
    local entry = self:getEntry(fieldId)
    if field == nil or entry == nil then
        return "Unknown field: " .. tostring(fieldId)
    end
    FHFieldMap:removeThreat(field, nil)
    self:clearThreat(entry, "disease")
    self:clearThreat(entry, "pest")
    return "Field " .. tostring(fieldId) .. ": threats removed"
end

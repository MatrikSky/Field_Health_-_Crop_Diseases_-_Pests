-- Field Health: risk model. Turns the state of a field and the farming work
-- of the player (fertilizing, soil work, rotation, catch crops, Precision
-- Farming data) into a risk multiplier per threat; 1.0 is a field farmed in
-- the normal way.
FHRisk = {}

-- Limits of the combined multiplier of a field.
FHRisk.MIN_MULTIPLIER = 0.3
FHRisk.MAX_MULTIPLIER = 5.0

-- Fertilizer kinds remembered per field since the last harvest (bit flags).
FHRisk.FERTILIZERS = {
    MANURE = 1,
    LIQUIDMANURE = 2,
    DIGESTATE = 4,
    FERTILIZER = 8,
    LIQUIDFERTILIZER = 16
}

local function hasFlag(flags, flag)
    return flags % (flag * 2) >= flag
end

function FHRisk.addFertilizerFlag(flags, sprayTypeName)
    local flag = FHRisk.FERTILIZERS[sprayTypeName]
    if flag == nil or hasFlag(flags, flag) then
        return flags
    end
    return flags + flag
end

function FHRisk.hasFertilizer(flags, sprayTypeName)
    return hasFlag(flags or 0, FHRisk.FERTILIZERS[sprayTypeName])
end

-- Share of the growing states up to which a stage lasts (FHThreats.STAGES).
FHRisk.STAGE_LIMITS = {{"seedling", 0.2}, {"leaves", 0.45}, {"stem", 0.7}}

-- Maps a growth state to a growth stage of FHThreats.STAGES. Withered, cut
-- or prepared crops are not active, so they cannot get threats.
local function classifyStage(desc, growthState)
    if desc == nil or growthState == nil or growthState < 0 then
        return nil, false
    end

    if desc.getIsWithered ~= nil and desc:getIsWithered(growthState) then
        return nil, false
    end

    if desc.getIsCut ~= nil and desc:getIsCut(growthState) then
        return nil, false
    end

    if desc.getIsPreparable ~= nil and desc:getIsPreparable(growthState) then
        return "ripe", true
    end

    if desc.preparedGrowthState ~= nil and desc.preparedGrowthState >= 0 and desc.preparedGrowthState == growthState then
        return nil, false
    end

    if desc.getIsGrowing ~= nil and desc:getIsGrowing(growthState) then
        local lastGrowingState = math.max(1, (desc.minHarvestingGrowthState or 2) - 1)
        local ratio = FHUtil.clamp(math.max(growthState - 1, 0) / math.max(lastGrowingState - 1, 1), 0, 1)
        for _, limit in ipairs(FHRisk.STAGE_LIMITS) do
            if ratio < limit[2] then
                return limit[1], true
            end
        end
        return "flowering", true
    end

    local minHarvest = desc.minHarvestingGrowthState or 0
    if minHarvest > 0 and growthState >= minHarvest and growthState <= (desc.maxHarvestingGrowthState or minHarvest) then
        return "ripe", true
    end

    return nil, false
end

-- A field can be split into parts with different crops; the game still sees
-- one field. The mod follows one crop per field: the crop of the season stays
-- while it grows anywhere on the grid, otherwise the crop of most points wins.
FHRisk.CROP_SAMPLES = 6

local function getFruitDesc(fruitIndex)
    if fruitIndex == nil or fruitIndex == FruitType.UNKNOWN or g_fruitTypeManager == nil then
        return nil
    end
    return g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
end

-- Fruit index and growth state at a world point, nil when it cannot be read.
-- The density map lookup is cheap; FieldState is the fallback.
function FHRisk.readCropAt(x, z)
    local ok, fruitIndex, growthState = pcall(function()
        if FSDensityMapUtil ~= nil and FSDensityMapUtil.getFruitTypeIndexAtWorldPos ~= nil then
            return FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
        end
        if FieldState ~= nil and FieldState.new ~= nil then
            local state = FieldState.new()
            state:update(x, z)
            return state.fruitTypeIndex, state.growthState
        end
        return nil
    end)
    if not ok then
        return nil
    end
    return fruitIndex, growthState
end

-- True when the crop grows at the point, false when something else is there,
-- nil when the point cannot be read (then nothing is filtered out).
function FHRisk.isCropAt(x, z, fruitIndex)
    local index, growthState = FHRisk.readCropAt(x, z)
    if index == nil then
        return nil
    end
    if index ~= fruitIndex then
        return false
    end
    local _, isActiveCrop = classifyStage(getFruitDesc(index), growthState or 0)
    return isActiveCrop == true
end

-- Growing crops on a grid of the field: {[fruitIndex] = {count, desc,
-- stages = {[stage] = count}}}, the number of points inside the field and of
-- points with a growing crop.
function FHRisk.surveyCrops(field)
    local crops, points, cropPoints = {}, 0, 0
    for _, point in ipairs(FHUtil.getSamplePoints(field, FHRisk.CROP_SAMPLES)) do
        points = points + 1
        local fruitIndex, growthState = FHRisk.readCropAt(point.x, point.z)
        local desc = getFruitDesc(fruitIndex)
        local stage, isActiveCrop = classifyStage(desc, growthState or 0)
        if isActiveCrop and fruitIndex ~= nil then
            cropPoints = cropPoints + 1
            local crop = crops[fruitIndex]
            if crop == nil then
                crop = {count = 0, desc = desc, stages = {}}
                crops[fruitIndex] = crop
            end
            crop.count = crop.count + 1
            if stage ~= nil then
                crop.stages[stage] = (crop.stages[stage] or 0) + 1
            end
        end
    end
    return crops, points, cropPoints
end

-- True when the crop does not grow on the whole grid of the field (other
-- crops or bare parts). nil when the grid cannot be read.
function FHRisk.isMixedField(field, fruitName)
    local crops, points = FHRisk.surveyCrops(field)
    if points == 0 then
        return nil
    end
    for _, crop in pairs(crops) do
        if crop.desc ~= nil and crop.desc.name == fruitName then
            return crop.count < points
        end
    end
    return true
end

local function mostCommon(counts)
    local best, bestCount = nil, 0
    for key, count in pairs(counts) do
        if count > bestCount or (count == bestCount and best ~= nil and tostring(key) < tostring(best)) then
            best, bestCount = key, count
        end
    end
    return best
end

-- The state the game keeps for a field is refreshed only now and then, so
-- after discing or sowing it can still show the old crop. The field's own
-- point is read live instead; the kept state is the fallback.
local function readLiveState(field)
    if field == nil or field.posX == nil or field.posZ == nil or FieldState == nil or FieldState.new == nil then
        return nil
    end
    local ok, state = pcall(function()
        local live = FieldState.new()
        live:update(field.posX, field.posZ)
        return live
    end)
    return ok and state or nil
end

-- seasonFruitName: the crop of the running season, kept while it still grows
-- somewhere on the field.
function FHRisk.getFieldSnapshot(field, seasonFruitName)
    local fieldState = readLiveState(field)
    if fieldState == nil then
        fieldState = field ~= nil and field.getFieldState ~= nil and field:getFieldState() or nil
    end
    if fieldState == nil then
        return nil
    end

    local fruitIndex = fieldState.fruitTypeIndex or FruitType.UNKNOWN
    local desc = getFruitDesc(fruitIndex)
    local stage, isActiveCrop = classifyStage(desc, fieldState.growthState or 0)
    local labelMatches = isActiveCrop and (seasonFruitName == nil or (desc ~= nil and desc.name == seasonFruitName))
    if not labelMatches then
        -- the field's own point is bare or has another crop than the season
        local crops = FHRisk.surveyCrops(field)
        local chosen = nil
        for index, crop in pairs(crops) do
            if seasonFruitName ~= nil and crop.desc ~= nil and crop.desc.name == seasonFruitName then
                chosen = index
            end
        end
        if chosen == nil and not isActiveCrop then
            local counts = {}
            for index, crop in pairs(crops) do
                counts[index] = crop.count
            end
            chosen = mostCommon(counts)
        end
        if chosen ~= nil then
            fruitIndex, desc = chosen, crops[chosen].desc
            stage, isActiveCrop = mostCommon(crops[chosen].stages), true
        end
    end
    local fruitName = desc ~= nil and desc.name or nil

    return {
        field = field,
        fieldState = fieldState,
        fruitIndex = fruitIndex,
        fruitName = fruitName,
        stage = stage,
        isActiveCrop = isActiveCrop == true,
        isCatchCrop = FHThreats.isCatchCrop(fruitName, desc)
        -- harvestFactors are read on demand by FHRisk.getHarvestFactors
    }
end

FHRisk.FACTOR_NAMES = {"spray", "plow", "lime", "weed", "stubble", "roller"}
-- The field work is read on a grid of n x n points.
FHRisk.FACTOR_SAMPLES = 6
-- Share of the crop points that must lack a field work before it counts as
-- missing: 0.5 for most work; stubble and rolling only when three quarters
-- lack it, so tramlines and field paths never count as neglect.
FHRisk.FACTOR_NEGLECT_SHARE = {stubble = 0.75, roller = 0.75}
-- With fewer crop points than this (a crop only just sown or emerging on part
-- of the field) these are not judged: a few spots say nothing about the field.
FHRisk.FACTOR_UNSURE = {stubble = true, roller = true}
FHRisk.FACTOR_MIN_SAMPLES = 4

local function readFactors(fieldState)
    if fieldState == nil or fieldState.getHarvestScaleFactors == nil then
        return nil
    end
    return {fieldState:getHarvestScaleFactors()}
end

-- Harvest scale factors of the field (1 = work done, lower = missing). They
-- are read at several points, but only where the field's crop grows:
-- tramlines, field paths and other spots without the crop would otherwise
-- count as neglected work, e.g. as unshredded stubble. A work counts as
-- missing only when most points lack it (FACTOR_NEGLECT_SHARE), so a few odd
-- spots do not change the result.
function FHRisk.getHarvestFactors(snapshot)
    if snapshot.harvestFactors ~= nil then
        return snapshot.harvestFactors
    end

    local samples = {}
    if FieldState ~= nil and FieldState.new ~= nil and snapshot.field ~= nil and snapshot.fruitIndex ~= FruitType.UNKNOWN then
        local ok = pcall(function()
            local state = FieldState.new()
            for _, point in ipairs(FHUtil.getSamplePoints(snapshot.field, FHRisk.FACTOR_SAMPLES)) do
                state:update(point.x, point.z)
                if state.fruitTypeIndex == snapshot.fruitIndex then
                    table.insert(samples, readFactors(state))
                end
            end
        end)
        if not ok then
            samples = {}
        end
    end
    snapshot.harvestSamples = #samples
    local unsure = #samples < FHRisk.FACTOR_MIN_SAMPLES
    if #samples == 0 then
        samples = {readFactors(snapshot.fieldState) or {}}
    end

    local factors = {}
    for i, name in ipairs(FHRisk.FACTOR_NAMES) do
        local values = {}
        for _, sample in ipairs(samples) do
            table.insert(values, tonumber(sample[i]) or 1)
        end
        table.sort(values)
        -- the value that the given share of the points does not reach
        local share = FHRisk.FACTOR_NEGLECT_SHARE[name] or 0.5
        factors[name] = values[math.min(#values, math.floor(#values * share) + 1)] or 1
        if unsure and FHRisk.FACTOR_UNSURE[name] then
            factors[name] = 1
        end
    end
    snapshot.harvestFactors = factors
    return factors
end

local function neglectOf(harvestFactor)
    return FHUtil.clamp(1 - (tonumber(harvestFactor) or 1), 0, 1)
end

-- Returns {name = 0..1} (0 = done, 1 = neglected) for every field work that
-- applies with the current game settings.
function FHRisk.getFieldWork(snapshot, entry)
    local info = g_currentMission.missionInfo
    local gameplay = Platform ~= nil and Platform.gameplay or {}
    local harvest = FHRisk.getHarvestFactors(snapshot)
    local work = {}

    if FHPrecisionFarming.isActive() and FHSettings.isOn("precisionFarming") then
        -- Precision Farming keeps nitrogen and pH in its own maps; the vanilla
        -- levels say nothing then. Its maps give nitrogen deficit or excess
        -- (60 kg N/ha off target counts fully), soil acidity and soil type.
        local pf = FHPrecisionFarming.getFieldData(snapshot.field, snapshot.fruitName)
        if pf ~= nil then
            if pf.hasNitrogenTarget then
                work.nitrogenDeficit = FHUtil.clamp(-pf.nitrogenOffset / 60, 0, 1)
                work.nitrogenExcess = FHUtil.clamp(pf.nitrogenOffset / 60, 0, 1)
            else
                work.fertilizer = (entry ~= nil and (entry.fertilizerFlags or 0) > 0) and 0 or 1
            end
            work.lime = FHUtil.clamp(-pf.phOffset, 0, 1)
            work.soilTypeIndex = pf.soilTypeIndex
        else
            -- Fallback: the fertilizing recorded by this mod.
            work.fertilizer = (entry ~= nil and (entry.fertilizerFlags or 0) > 0) and 0 or 1
        end
    else
        work.fertilizer = neglectOf(harvest.spray)
        if info.limeRequired then
            work.lime = neglectOf(harvest.lime)
        end
    end

    if info.weedsEnabled then
        work.weeds = neglectOf(harvest.weed)
    end
    if info.plowingRequiredEnabled then
        work.plowing = neglectOf(harvest.plow)
    end
    -- stubble only after a harvest on this field, and not when plowing buried it
    local plowed = work.plowing ~= nil and work.plowing <= 0
    local hadHarvest = entry == nil or entry.previousCropFruitName ~= nil
    if gameplay.useStubbleShred and FHSettings.isOn("stubbleRisk") and hadHarvest and not plowed then
        work.stubble = neglectOf(harvest.stubble)
    end
    if gameplay.useRolling then
        work.rolling = neglectOf(harvest.roller)
    end

    return work
end

-- Risk multiplier of one threat on a field and the factors that raise it.
function FHRisk.getThreatMultiplier(threat, snapshot, entry, work)
    local multiplier = 1
    local causes = {}
    local function apply(cause, value)
        if value ~= 1 then
            multiplier = multiplier * value
            if value > 1 then
                causes[cause] = (causes[cause] or 1) * value
            end
        end
    end

    local isDisease = threat.category == "disease"
    local flags = entry.fertilizerFlags or 0

    -- Nutrition: hungry plants are weak; fast or excess nitrogen makes lush, soft growth.
    if work.fertilizer ~= nil then
        apply("fertilizer", 1 + work.fertilizer * (isDisease and 0.25 or 0.15))
    end
    if work.nitrogenDeficit ~= nil then
        apply("nitrogenDeficit", 1 + work.nitrogenDeficit * (isDisease and 0.25 or 0.15))
    end
    if work.nitrogenExcess ~= nil and threat.lush then
        apply("nitrogenExcess", 1 + work.nitrogenExcess * 0.3)
    end
    if hasFlag(flags, FHRisk.FERTILIZERS.MANURE) then
        if threat.soilborne then
            apply("manure", 0.7)
        elseif threat.soilPest then
            apply("manure", 1.15)
        elseif isDisease then
            apply("manure", 0.9)
        end
    end
    if threat.lush then
        if hasFlag(flags, FHRisk.FERTILIZERS.LIQUIDMANURE) then
            apply("fastNitrogen", 1.25)
        elseif hasFlag(flags, FHRisk.FERTILIZERS.DIGESTATE) then
            apply("fastNitrogen", 1.15)
        elseif hasFlag(flags, FHRisk.FERTILIZERS.LIQUIDFERTILIZER) then
            apply("fastNitrogen", 1.1)
        end
    end

    -- A catch crop before the main crop improves soil health.
    if entry.catchCropBefore then
        apply("catchCrop", (threat.soilborne or threat.soilPest) and 0.6 or 0.9)
    end

    -- Soil type (Precision Farming): soil pests like light, sandy soil; soil-borne
    -- diseases like heavy, wet soil.
    if work.soilTypeIndex == 1 and threat.soilPest then
        apply("lightSoil", 1.2)
    elseif work.soilTypeIndex == 4 and threat.soilborne then
        apply("heavySoil", 1.2)
    end

    -- Soil work.
    if work.lime ~= nil then
        apply("lime", 1 + work.lime * (threat.soilborne and 0.5 or (isDisease and 0.15 or 0)))
    end
    if work.plowing ~= nil then
        local effect = (threat.residue and 0.6) or (threat.soilPest and 0.5) or (threat.stalkPest and 0.4) or 0
        apply("plowing", 1 + work.plowing * effect)
    end
    if work.stubble ~= nil then
        apply("stubble", 1 + work.stubble * ((threat.stalkPest and 0.8) or (threat.residue and 0.3) or 0))
    end
    if work.rolling ~= nil and threat.soilPest then
        apply("rolling", 1 + work.rolling * 0.2)
    end
    if work.weeds ~= nil then
        apply("weeds", 1 + work.weeds * ((threat.weedHost and 1.0) or (isDisease and 0.2 or 0.4)))
    end

    -- Crop rotation.
    local current = snapshot.fruitName
    local previous = entry.previousCropFruitName
    if previous ~= nil and not FHThreats.PERENNIAL[current] then
        local family = FHThreats.getFamily(current)
        local previousFamily = FHThreats.getFamily(previous)
        if previous == current then
            apply("sameCrop", 1.8)
        elseif family ~= nil and family == previousFamily then
            apply("cropFamily", 1.3)
        end
        if threat.after ~= nil and previousFamily ~= nil and threat.after[previousFamily] ~= nil then
            apply("previousCrop", threat.after[previousFamily])
        end
    end

    multiplier = FHUtil.clamp(multiplier, FHRisk.MIN_MULTIPLIER, FHRisk.MAX_MULTIPLIER)

    -- The "influence of farming" setting weakens or strengthens all factors.
    return multiplier ^ FHSettings.get("careInfluence"), causes
end

-- Evaluates one threat category ("disease" or "pest") for a field. The
-- multiplier is the one of the most likely threat; "threats" are all threats
-- of the category that attack the crop, each with its risk multiplier.
function FHRisk.evaluateCategory(snapshot, entry, category)
    local result = {multiplier = 1, mainCause = nil, threats = {}, hasThreats = false}
    if snapshot == nil or not snapshot.isActiveCrop then
        return result
    end

    local work = FHRisk.getFieldWork(snapshot, entry)
    local bestMultiplier = nil
    for _, threat in ipairs(FHThreats.forCrop(snapshot.fruitName, category)) do
        local multiplier, causes = FHRisk.getThreatMultiplier(threat, snapshot, entry, work)
        result.hasThreats = true

        if bestMultiplier == nil or multiplier > bestMultiplier then
            bestMultiplier = multiplier
            local mainCause, mainValue = nil, 1.05
            for cause, value in pairs(causes) do
                if value > mainValue then
                    mainCause, mainValue = cause, value
                end
            end
            result.mainCause = mainCause
        end

        table.insert(result.threats, {threat = threat, multiplier = multiplier})
    end

    result.multiplier = bestMultiplier or 1
    return result
end

-- Picks one candidate {threat, weight}, with a chance in proportion to its weight.
function FHRisk.pickCandidate(candidates)
    local total = 0
    for _, candidate in ipairs(candidates) do
        total = total + candidate.weight
    end

    local roll = math.random() * total
    for _, candidate in ipairs(candidates) do
        roll = roll - candidate.weight
        if roll <= 0 then
            return candidate.threat
        end
    end
    return candidates[#candidates] ~= nil and candidates[#candidates].threat or nil
end

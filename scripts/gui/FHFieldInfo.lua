-- Field Health: lines in the field info box of the HUD. Every line holds one
-- short piece of information, because the box cuts long lines off.
FHFieldInfo = {}

FHFieldInfo.SEVERITY = {"fh_severity_low", "fh_severity_medium", "fh_severity_high"}
-- shown risk level by multiplier
FHFieldInfo.RISK_LEVELS = {
    {upTo = 0.85, text = "fh_risk_low"},
    {upTo = 1.25, text = "fh_risk_normal"},
    {upTo = 2.0, text = "fh_risk_elevated"},
    {upTo = math.huge, text = "fh_risk_high"}
}
-- the main cause is shown above this multiplier
FHFieldInfo.CAUSE_FROM = 1.25

FHFieldInfo.LABELS = {
    disease = {threat = "fh_hud_disease", risk = "fh_hud_diseaseRisk", protection = "fh_hud_diseaseProtection", hint = "fh_hint_fungicide"},
    pest = {threat = "fh_hud_pest", risk = "fh_hud_pestRisk", protection = "fh_hud_pestProtection", hint = "fh_hint_insecticide"}
}

local function entryAtPlayer()
    if FHSimulation.fields == nil then
        return nil, nil
    end
    local field = FHUtil.getFieldAtPlayer()
    return FHSimulation:getEntry(FHUtil.getFieldId(field)), field
end

function FHFieldInfo.riskText(multiplier)
    for _, level in ipairs(FHFieldInfo.RISK_LEVELS) do
        if (multiplier or 1) <= level.upTo then
            return FHUtil.text(level.text)
        end
    end
    return ""
end

-- e.g. "Septoria (medium)"
function FHFieldInfo.threatText(entry, category)
    local threat = FHSimulation:getActiveThreat(entry, category)
    if threat == nil then
        return nil
    end
    local state = FHUtil.clamp(entry[FHSimulation.SLOT[category].state] or 1, 1, FHThreats.MAX_SEVERITY)
    return string.format("%s (%s)", FHThreats.shortName(threat), FHUtil.text(FHFieldInfo.SEVERITY[state]))
end

-- Threats, risks and protection (below the farmland lines).
function FHFieldInfo:addThreatLines(box)
    local entry = entryAtPlayer()
    if entry == nil or not entry.cropActive then
        return
    end

    local anyThreat = false
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local text = FHFieldInfo.threatText(entry, category)
        if text ~= nil then
            anyThreat = true
            box:addLine(FHUtil.text(FHFieldInfo.LABELS[category].threat), text)
        end
    end
    if not anyThreat then
        box:addLine(FHUtil.text("fh_hud_threats"), FHUtil.text("fh_hud_none"))
    end

    for _, category in ipairs(FHThreats.CATEGORIES) do
        local slot = FHSimulation.SLOT[category]
        local risk = entry[slot.risk] or 1
        box:addLine(FHUtil.text(FHFieldInfo.LABELS[category].risk), FHFieldInfo.riskText(risk))
        if entry[slot.cause] ~= nil and risk > FHFieldInfo.CAUSE_FROM then
            box:addLine(FHUtil.text("fh_hud_cause"), FHUtil.text("fh_cause_" .. entry[slot.cause]))
        end
    end

    if (entry.diseaseProtection or 0) <= 0 and (entry.pestProtection or 0) <= 0 then
        box:addLine(FHUtil.text("fh_hud_protection"), FHUtil.text("fh_hud_none"))
        return
    end
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local share = FHSimulation:getProtection(entry, category)
        local text = FHUtil.text("fh_hud_none")
        if share >= FHSettings.get("protectionThreshold") then
            text = FHUtil.text("fh_hud_protected")
        elseif share > 0 then
            text = FHUtil.percent(share)
        end
        box:addLine(FHUtil.text(FHFieldInfo.LABELS[category].protection), text)
    end
end

local function areaHa(field)
    return field ~= nil and (field.areaHa or (field.getAreaHa ~= nil and field:getAreaHa())) or 0
end

-- Expected harvest of a ripe field: litres and tons per area unit.
local function expectedHarvest(fieldState, field)
    local desc = fieldState ~= nil and g_fruitTypeManager ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex) or nil
    local growth = fieldState ~= nil and fieldState.growthState or nil
    if desc == nil or growth == nil or desc.minHarvestingGrowthState == nil
        or growth < desc.minHarvestingGrowthState or growth > desc.maxHarvestingGrowthState then
        return nil
    end
    local hectares, litresPerSqm = areaHa(field), desc.literPerSqm or 0
    if hectares <= 0 or litresPerSqm <= 0 then
        return nil
    end

    local scale = fieldState.getHarvestScaleMultiplier ~= nil and fieldState:getHarvestScaleMultiplier() or 1
    local litres = litresPerSqm * hectares * 10000 * scale
    -- fill type masses are tons per litre
    local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(desc.index)
    local tonsPerLitre = type(fillType) == "table" and fillType.massPerLiter or 0.001
    local units = g_i18n:getArea(hectares)
    return litres, litres * tonsPerLitre / ((units ~= nil and units > 0) and units or 1)
end

-- Field area, expected harvest and what to spray (below the field lines).
function FHFieldInfo:addCropLines(fieldState, box)
    local entry, field = entryAtPlayer()
    if field == nil then
        return
    end
    box:addLine(FHUtil.text("fh_field_area"), g_i18n:formatArea(areaHa(field), 2))

    local litres, tonsPerUnit = expectedHarvest(fieldState, field)
    if litres ~= nil then
        box:addLine(FHUtil.text("fh_potential_harvest"), g_i18n:formatVolume(litres, 0))
        box:addLine(FHUtil.text("fh_potential_yield"), string.format("%1.2f t/%s", tonsPerUnit, g_i18n:getAreaUnit()))
    end

    if entry ~= nil then
        for _, category in ipairs(FHThreats.CATEGORIES) do
            if FHSimulation:getActiveThreat(entry, category) ~= nil then
                box:addLine(FHUtil.text(FHFieldInfo.LABELS[category].hint), nil, true)
            end
        end
    end
end

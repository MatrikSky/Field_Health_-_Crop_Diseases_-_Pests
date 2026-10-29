-- Field Health: hooks into game classes. They are installed when the script
-- is loaded, before the vehicle types are finalized (finalizing copies the
-- class functions into every vehicle type). Every hook calls the original
-- function, and errors of this mod are caught so the game keeps running.
FHHooks = {}

local function active()
    return FHSimulation.fields ~= nil
end

---------------------------------------------------------------------------
-- Sprayers
---------------------------------------------------------------------------

-- Fungicide and insecticide cure and protect the sprayed cells; any other
-- spray is remembered as fertilizing (Precision Farming may bypass the
-- density map update below, so it is recorded here too).
local function onSprayerArea(sprayer, workArea)
    local params = sprayer.spec_sprayer ~= nil and sprayer.spec_sprayer.workAreaParameters or nil
    if params == nil or (params.sprayFillLevel or 0) <= 0 or (sprayer.getIsTurnedOn ~= nil and not sprayer:getIsTurnedOn()) then
        return
    end
    local category = FHProducts:getCategory(params.sprayFillType)
    if category ~= nil then
        FHSimulation:onSprayed(workArea, category)
    else
        local x, z = FHFieldMap.getWorkAreaCenter(workArea)
        if x ~= nil then
            FHSimulation:recordFertilizer(x, z, FHUtil.getFillTypeName(params.sprayFillType))
        end
    end
end

Sprayer.processSprayerArea = Utils.overwrittenFunction(Sprayer.processSprayerArea, function(self, superFunc, workArea, dt)
    local changed, total = superFunc(self, workArea, dt)
    if self.isServer and active() then
        FHUtil.protect("sprayer", onSprayerArea, self, workArea)
    end
    return changed, total
end)

-- The liquids only need field ground; which parts still need spraying is
-- decided by the AI area hook below.
Sprayer.setSprayerAITerrainDetailProhibitedRange = Utils.overwrittenFunction(Sprayer.setSprayerAITerrainDetailProhibitedRange, function(self, superFunc, fillType)
    if FHProducts:getCategory(fillType) == nil then
        return superFunc(self, fillType)
    end
    for _, clear in ipairs({"clearAITerrainDetailRequiredRange", "clearAITerrainDetailProhibitedRange", "clearAIFruitRequirements", "clearAIFruitProhibitions"}) do
        if self[clear] ~= nil then
            self[clear](self)
        end
    end
    if self.addAIGroundTypeRequirements ~= nil then
        self:addAIGroundTypeRequirements(Sprayer.AI_REQUIRED_GROUND_TYPES)
    end
end)

-- Fungicide and insecticide neither fertilize nor kill weeds; other sprays
-- are remembered per field, because the kind of fertilizer changes the risk.
-- (These two game functions take no "self", so they are wrapped directly.)
local updateSprayArea = FSDensityMapUtil.updateSprayArea
FSDensityMapUtil.updateSprayArea = function(startX, startZ, widthX, widthZ, heightX, heightZ, sprayTypeIndex, ...)
    local sprayType = g_sprayTypeManager ~= nil and g_sprayTypeManager:getSprayTypeByIndex(sprayTypeIndex) or nil
    if sprayType ~= nil and FHProducts:isLiquid(sprayType.fillType) then
        return 0, 0
    end
    if sprayType ~= nil and g_server ~= nil and active() then
        FHUtil.protect("fertilizer", FHSimulation.recordFertilizer, FHSimulation, (widthX + heightX) * 0.5, (widthZ + heightZ) * 0.5,
            sprayType.name or (sprayType.fillType ~= nil and sprayType.fillType.name) or nil)
    end
    return updateSprayArea(startX, startZ, widthX, widthZ, heightX, heightZ, sprayTypeIndex, ...)
end

-- AI helpers with fungicide or insecticide treat growing crops of fields that
-- are not protected yet and remaining threats; everything else counts as done.
local getAIAreaOfVehicle = AIVehicleUtil.getAIAreaOfVehicle
AIVehicleUtil.getAIAreaOfVehicle = function(vehicle, startX, startZ, widthX, widthZ, heightX, heightZ, ...)
    local area, total = getAIAreaOfVehicle(vehicle, startX, startZ, widthX, widthZ, heightX, heightZ, ...)
    local category = active() and FHProducts:getVehicleCategory(vehicle) or nil
    if category == nil then
        return area, total
    end
    local needed = FHUtil.protect("AI sprayer", FHSimulation.isSprayNeeded, FHSimulation, startX, startZ, widthX, widthZ, heightX, heightZ, category)
    if needed == false then
        return 0, total
    end
    return area, total
end

-- The liquids borrow the spray effect materials of herbicide and liquid
-- fertilizer as soon as the game registers them (see FHProducts). Guarded,
-- so the hooks below are installed even if the class ever changes.
if MaterialManager ~= nil and MaterialManager.addMaterial ~= nil then
    MaterialManager.addMaterial = Utils.appendedFunction(MaterialManager.addMaterial, function(manager, fillTypeIndex, materialType, materialIndex, materialId)
        FHUtil.protect("spray effects", FHProducts.onMaterialAdded, FHProducts, manager, fillTypeIndex, materialType, materialIndex, materialId)
    end)
end

---------------------------------------------------------------------------
-- Field info box of the HUD
---------------------------------------------------------------------------

PlayerHUDUpdater.fieldAddFarmland = Utils.appendedFunction(PlayerHUDUpdater.fieldAddFarmland, function(updater, data, box)
    if FHSettings.isOn("fieldInfo") then
        FHUtil.protect("field info", FHFieldInfo.addThreatLines, FHFieldInfo, box)
    end
end)

PlayerHUDUpdater.fieldAddField = Utils.appendedFunction(PlayerHUDUpdater.fieldAddField, function(updater, fieldState, box)
    if FHSettings.isOn("fieldInfo") then
        FHUtil.protect("field info", FHFieldInfo.addCropLines, FHFieldInfo, fieldState, box)
    end
end)

---------------------------------------------------------------------------
-- Saving and joining players
---------------------------------------------------------------------------

-- Written only together with the game's savegame, so quitting without
-- saving keeps both in step. An error here never stops the game saving.
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function(mission)
    FHUtil.protect("saving", FHSavegame.save)
end)

FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, function(mission, connection, user, farm)
    FHUtil.protect("join state", FHNetwork.sendJoinState, FHNetwork, connection)
end)

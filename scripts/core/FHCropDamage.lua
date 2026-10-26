-- Field Health: crop losses of severe threats. The crop of a small, irregular
-- patch is removed from the fruit density map and yields nothing at harvest.
FHCropDamage = {}

-- Destroys growing or ripe crop around (x, z); returns changed density pixels.
function FHCropDamage.destroyAt(field, x, z, radius)
    if g_server == nil or field == nil or g_fruitTypeManager == nil or g_terrainNode == nil then
        return 0
    end
    local fieldState = field:getFieldState()
    local fruitIndex = fieldState ~= nil and fieldState.fruitTypeIndex or FruitType.UNKNOWN
    local desc = fruitIndex ~= FruitType.UNKNOWN and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex) or nil
    if desc == nil or desc.terrainDataPlaneId == nil then
        return 0
    end

    local modifier = DensityMapModifier.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels, g_terrainNode)
    local filter = DensityMapFilter.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
    -- growing and harvestable states only; cut or withered crop stays
    filter:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, math.max(1, desc.maxHarvestingGrowthState or 1))
    modifier:setNewTypeIndexMode(DensityIndexCompareMode.ZERO)

    -- two or three small squares, shifted and turned at random
    local changed = 0
    for piece = 1, math.random(2, 3) do
        local size = radius * MathUtil.randomFloat(0.45, 0.75)
        local shift = piece == 1 and 0 or radius * MathUtil.randomFloat(0.3, 0.7)
        local heading = MathUtil.randomFloat(0, math.pi * 2)
        local cx, cz = x + math.cos(heading) * shift, z + math.sin(heading) * shift

        local turn = MathUtil.randomFloat(0, math.pi * 0.5)
        local ux, uz = math.cos(turn) * size, math.sin(turn) * size
        local sx, sz = cx - ux + uz, cz - uz - ux
        modifier:setParallelogramWorldCoords(sx, sz, sx + 2 * ux, sz + 2 * uz, sx - 2 * uz, sz + 2 * ux, DensityCoordType.POINT_POINT_POINT)
        local _, pieceChanged = modifier:executeSetWithStats(0, filter)
        changed = changed + (pieceChanged or 0)
    end
    return changed
end

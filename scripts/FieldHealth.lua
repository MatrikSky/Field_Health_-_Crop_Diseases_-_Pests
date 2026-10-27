-- Field Health: the only mod event listener. It starts and stops all modules
-- in a fixed order and forwards the frame updates.
FieldHealth = {}

FieldHealth.VERSION = "1.1.0.0"
-- other mods that do the same job and would spray, colour and save twice
FieldHealth.OVERLAPPING_MODS = {"FS25_CropDiseases_BMP", "FS25_CropDiseases"}

function FieldHealth:loadMap()
    for _, name in ipairs(FieldHealth.OVERLAPPING_MODS) do
        if g_modIsLoaded ~= nil and g_modIsLoaded[name] and name ~= FHUtil.MOD_NAME then
            FHUtil.log("Warning: %s is active as well. Both mods handle crop diseases; please use only one of them.", name)
        end
    end

    FHUtil.resetFieldCache()
    FHSettings.reset()
    FHUtil.protect("crop detection", FieldHealth.detectCrops)
    local directory = g_server ~= nil and FHUtil.getSavegameDirectory(false) or nil
    local mapFromFile = FHFieldMap:load(directory)
    FHDisplayMap:load()
    FHSimulation:load()
    FHProducts:load()
    FHNetwork:load()
    FHMiniMap:load()
    FHConsole:register()

    if g_server ~= nil then
        FHUtil.protect("loading savegame data", FHSavegame.load)
        FHSimulation:onDataLoaded(mapFromFile)
    end
    self.helpPending = true
    FHUtil.log("Version %s loaded", FieldHealth.VERSION)
end

-- Crops of DLCs and mods, e.g. onions of the Highlands Fishing Expansion.
function FieldHealth.detectCrops()
    local manager = g_fruitTypeManager
    if manager == nil then
        return
    end
    local fruitTypes = manager.getFruitTypes ~= nil and manager:getFruitTypes() or manager.fruitTypes
    for name, crop in pairs(FHThreats.detectCrops(fruitTypes)) do
        if name == crop then
            FHUtil.log("Crop %s found: its diseases and pests are active", name)
        else
            FHUtil.log("Crop %s recognised as %s: its diseases and pests are active", name, crop)
        end
    end
end

function FieldHealth:deleteMap()
    FHConsole:unregister()
    FHMiniMap:unload()
    FHMapPage.unload()
    FHNetwork:unload()
    FHProducts:unload()
    FHSimulation:unload()
    FHDisplayMap:unload()
    FHFieldMap:unload()
    FHUtil.resetFieldCache()
end

function FieldHealth:update(dt)
    -- the help pages of all mods are loaded once the game runs
    if self.helpPending then
        self.helpPending = false
        FHUtil.protect("help", FHHelp.onGameStarted)
    end
    FHUtil.protect("simulation", FHSimulation.update, FHSimulation, dt)
    FHUtil.protect("network", FHNetwork.update, FHNetwork, dt)
    FHUtil.protect("display map", FHDisplayMap.update, FHDisplayMap, dt)
    FHUtil.protect("minimap", FHMiniMap.update, FHMiniMap, dt)
end

function FieldHealth:draw()
    FHFieldMap:drawDebug()
end

addModEventListener(FieldHealth)

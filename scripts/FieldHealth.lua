-- Field Health: the only mod event listener. It starts and stops all modules
-- in a fixed order and forwards the frame updates.
FieldHealth = {}

FieldHealth.VERSION = "1.2.1.0"
-- other mods that do the same job and would spray, colour and save twice
FieldHealth.OVERLAPPING_MODS = {"FS25_CropDiseases_BMP", "FS25_CropDiseases"}

function FieldHealth:loadMap()
    for _, name in ipairs(FieldHealth.OVERLAPPING_MODS) do
        if g_modIsLoaded ~= nil and g_modIsLoaded[name] and name ~= FHUtil.MOD_NAME then
            FHUtil.log("Warning: %s is active as well. Both mods handle crop diseases; please use only one of them.", name)
        end
    end

    self.failed = false
    FHUtil.resetFieldCache()
    FHSettings.reset()
    FHUtil.protect("crop detection", FieldHealth.detectCrops)

    -- Without its core the mod stays off for this game session. It then
    -- saves nothing, so its data in the savegame stays as it was.
    local started, message = pcall(FieldHealth.start)
    if not started then
        FHUtil.reportError("starting", message)
        FHUtil.log("Field Health is off for this game session; its savegame data is kept unchanged")
        FieldHealth.stop()
        self.failed = true
        return
    end

    FHUtil.protect("minimap", FHMiniMap.load, FHMiniMap)
    FHUtil.protect("console", FHConsole.register, FHConsole)
    self.gameStartPending = true
    FHUtil.log("Version %s loaded", FieldHealth.VERSION)
end

-- Field map, simulation, products, network and the savegame data.
function FieldHealth.start()
    local directory = g_server ~= nil and FHUtil.getSavegameDirectory(false) or nil
    if directory ~= nil then
        FHSavegame.checkVersion(directory)
    end
    local mapFromFile = FHFieldMap:load(directory)
    FHDisplayMap:load()
    FHSimulation:load()
    FHProducts:load()
    FHNetwork:load()

    if g_server ~= nil then
        FHSavegame.load(directory)
        FHSimulation:onDataLoaded(mapFromFile)
    end
end

-- Stops the core modules; each one even when another fails.
function FieldHealth.stop()
    FHUtil.protect("stopping the network", FHNetwork.unload, FHNetwork)
    FHUtil.protect("stopping the products", FHProducts.unload, FHProducts)
    FHUtil.protect("stopping the simulation", FHSimulation.unload, FHSimulation)
    FHUtil.protect("stopping the display map", FHDisplayMap.unload, FHDisplayMap)
    FHUtil.protect("stopping the field map", FHFieldMap.unload, FHFieldMap)
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
    FHUtil.protect("console", FHConsole.unregister, FHConsole)
    FHUtil.protect("minimap", FHMiniMap.unload, FHMiniMap)
    FHUtil.protect("map page", FHMapPage.unload)
    FieldHealth.stop()
    FHUtil.resetFieldCache()
end

function FieldHealth:update(dt)
    if self.failed then
        return
    end
    -- once the game runs, the help pages of all mods and the spray effect
    -- materials are loaded
    if self.gameStartPending then
        self.gameStartPending = false
        FHUtil.protect("help", FHHelp.onGameStarted)
        FHUtil.protect("spray effects", FHProducts.checkSprayEffects, FHProducts)
    end
    FHUtil.protect("simulation", FHSimulation.update, FHSimulation, dt)
    FHUtil.protect("network", FHNetwork.update, FHNetwork, dt)
    FHUtil.protect("display map", FHDisplayMap.update, FHDisplayMap, dt)
    FHUtil.protect("minimap", FHMiniMap.update, FHMiniMap, dt)
end

function FieldHealth:draw()
    if not self.failed then
        FHUtil.protect("debug view", FHFieldMap.drawDebug, FHFieldMap)
    end
end

addModEventListener(FieldHealth)

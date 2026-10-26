-- Field Health: game settings of the mod. The server decides, stores them in
-- the savegame and sends them to all clients; only the admin may change them.
FHSettings = {}

FHSettings.INDEX_BITS = 5

local PRICES_SMALL = {10, 20, 30, 40, 50, 60, 70, 80, 100, 120, 150, 200}
local PRICES_MEDIUM = {50, 100, 150, 180, 200, 220, 250, 300, 350, 400, 500, 600}
local PRICES_LARGE = {200, 300, 400, 500, 600, 700, 800, 900, 1000, 1200, 1500, 2000}
local CHANCES = {0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50}
local RATES = {0.25, 0.5, 0.75, 1, 1.25, 1.5, 2}

-- Each option is a list of values; the savegame keeps the value, the network
-- and the menu use its index. format: "percent", "money" or a list of text keys.
FHSettings.OPTIONS = {
    {name = "enabled", values = {1, 0}, format = {"fh_set_on", "fh_set_off"}, default = 1},
    {name = "diseaseChance", values = CHANCES, format = "percent", default = 4},
    {name = "pestChance", values = CHANCES, format = "percent", default = 3},
    {name = "careInfluence", values = {0, 0.5, 1, 1.5}, format = {"fh_set_none", "fh_set_low", "fh_set_normal", "fh_set_high"}, default = 3},
    {name = "weatherInfluence", values = {0, 0.5, 1, 1.5}, format = {"fh_set_none", "fh_set_low", "fh_set_normal", "fh_set_high"}, default = 3},
    {name = "stubbleRisk", values = {1, 0}, format = {"fh_set_on", "fh_set_off"}, default = 1},
    {name = "fodderCrops", values = {1, 0}, format = {"fh_set_on", "fh_set_off"}, default = 2},
    {name = "progression", values = {1.0, 0.5, 0.25}, format = {"fh_set_slow", "fh_set_normalPace", "fh_set_fast"}, default = 2},
    {name = "spread", values = {0.5, 1, 2}, format = {"fh_set_small", "fh_set_medium", "fh_set_large"}, default = 2},
    {name = "patchSize", values = {0.6, 1, 1.5}, format = {"fh_set_patchSmall", "fh_set_patchNormal", "fh_set_patchLarge"}, default = 2},
    {name = "neighbourSpread", values = {0, 0.5, 1, 2}, format = {"fh_set_off", "fh_set_rarely", "fh_set_sometimes", "fh_set_often"}, default = 3},
    {name = "damage", values = {0, 1, 3, 6}, format = {"fh_set_off", "fh_set_damageLow", "fh_set_damageNormal", "fh_set_damageHigh"}, default = 3},
    {name = "protectionThreshold", values = {0.75, 0.80, 0.85, 0.90, 0.95}, format = "percent", default = 4},
    {name = "protectionDuration", values = {0, 2, 1, 0.5}, format = {"fh_set_untilHarvest", "fh_set_twoMonths", "fh_set_oneMonth", "fh_set_halfMonth"}, default = 1},
    {name = "fungicideUsage", values = RATES, format = "percent", default = 4},
    {name = "insecticideUsage", values = RATES, format = "percent", default = 4},
    {name = "fungicidePrice", values = PRICES_SMALL, format = "money", default = 5},
    {name = "insecticidePrice", values = PRICES_SMALL, format = "money", default = 8},
    {name = "fungicideCanisterPrice", values = PRICES_MEDIUM, format = "money", default = 6},
    {name = "insecticideCanisterPrice", values = PRICES_MEDIUM, format = "money", default = 9},
    {name = "fungicideCanister20Price", values = PRICES_LARGE, format = "money", default = 7},
    {name = "insecticideCanister20Price", values = PRICES_LARGE, format = "money", default = 10},
    {name = "farmLimit", values = {0, 1, 2, 3, 5, 10}, format = {"fh_set_unlimited", "1", "2", "3", "5", "10"}, default = 1},
    {name = "notifications", values = {1, 0}, format = {"fh_set_on", "fh_set_off"}, default = 1},
    {name = "fieldInfo", values = {1, 0}, format = {"fh_set_on", "fh_set_off"}, default = 1}
}

local optionByName = {}
for _, option in ipairs(FHSettings.OPTIONS) do
    optionByName[option.name] = option
end

FHSettings.selected = {}
-- Called after any change (spray rates, shop prices); set by FHProducts.
FHSettings.listeners = {}

function FHSettings.get(name)
    local option = optionByName[name]
    return option.values[FHSettings.selected[name] or option.default]
end

function FHSettings.isOn(name)
    return FHSettings.get(name) == 1
end

function FHSettings.getIndex(name)
    return FHSettings.selected[name] or optionByName[name].default
end

local function notify()
    for _, listener in ipairs(FHSettings.listeners) do
        FHUtil.protect("settings listener", listener)
    end
    if FHSettingsPage ~= nil then
        FHSettingsPage:refresh()
    end
end

function FHSettings.reset()
    for _, option in ipairs(FHSettings.OPTIONS) do
        FHSettings.selected[option.name] = option.default
    end
    notify()
end

-- Texts shown in the menu for each value of an option.
function FHSettings.getLabels(option)
    local labels = {}
    for i, value in ipairs(option.values) do
        if option.format == "percent" then
            labels[i] = FHUtil.percent(value)
        elseif option.format == "money" then
            labels[i] = (g_i18n ~= nil and g_i18n.formatMoney ~= nil) and g_i18n:formatMoney(value, 0, true) or tostring(value)
        else
            local label = option.format[i]
            labels[i] = string.sub(label, 1, 3) == "fh_" and FHUtil.text(label) or label
        end
    end
    return labels
end

function FHSettings.canEdit()
    return g_server ~= nil or (g_currentMission ~= nil and g_currentMission.isMasterUser == true)
end

-- On the server: applies and sends to everyone. On a client: asks the server.
function FHSettings.select(name, index)
    local option = optionByName[name]
    if option == nil or option.values[index] == nil then
        return
    end
    if g_server == nil then
        FHRequestEvent.sendSetting(name, index)
        return
    end

    FHSettings.selected[name] = index
    notify()
    if FHUtil.isMultiplayer() then
        FHSyncEvent.broadcastSettings()
    end
end

-- Values received from the server.
function FHSettings.applyAll(indices)
    for name, index in pairs(indices) do
        local option = optionByName[name]
        if option ~= nil and option.values[index] ~= nil then
            FHSettings.selected[name] = index
        end
    end
    notify()
end

-- The savegame stores values, so the option lists may change between versions.
function FHSettings.save(xmlFile, key)
    for _, option in ipairs(FHSettings.OPTIONS) do
        setXMLFloat(xmlFile, key .. "#" .. option.name, FHSettings.get(option.name))
    end
end

function FHSettings.load(xmlFile, key)
    for _, option in ipairs(FHSettings.OPTIONS) do
        local value = getXMLFloat(xmlFile, key .. "#" .. option.name)
        if value ~= nil then
            local best, bestDistance = option.default, math.huge
            for i, candidate in ipairs(option.values) do
                local distance = math.abs(candidate - value)
                if distance < bestDistance then
                    best, bestDistance = i, distance
                end
            end
            FHSettings.selected[option.name] = best
        end
    end
    notify()
end

function FHSettings.writeStream(streamId)
    for _, option in ipairs(FHSettings.OPTIONS) do
        streamWriteUIntN(streamId, FHSettings.getIndex(option.name), FHSettings.INDEX_BITS)
    end
end

function FHSettings.readStream(streamId)
    local indices = {}
    for _, option in ipairs(FHSettings.OPTIONS) do
        indices[option.name] = streamReadUIntN(streamId, FHSettings.INDEX_BITS)
    end
    return indices
end

FHSettings.reset()

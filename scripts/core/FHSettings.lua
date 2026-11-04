-- Field Health: game settings of the mod. The server decides, stores them in
-- the savegame and sends them to all clients; only the admin may change them.
FHSettings = {}

FHSettings.INDEX_BITS = 5

local PRICES_SMALL = {10, 20, 30, 40, 50, 60, 70, 80, 100, 120, 150, 200}
local PRICES_MEDIUM = {50, 100, 150, 180, 200, 220, 250, 300, 350, 400, 500, 600}
local PRICES_LARGE = {200, 300, 400, 500, 600, 700, 800, 900, 1000, 1200, 1500, 2000}
local CHANCES = {0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50}
local RATES = {0.25, 0.5, 0.75, 1, 1.25, 1.5, 2}

local ON_OFF = {"fh_set_on", "fh_set_off"}

-- Each option is a list of values; the savegame keeps the value, the network
-- and the menu use its index. format: "percent", "money" or a list of text keys.
-- section: the part of the settings tab the option is shown in. Options added
-- after 1.2 default to the behaviour before them, so older savegames play on
-- the same way.
FHSettings.OPTIONS = {
    {name = "enabled", section = "general", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "diseases", section = "general", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "pests", section = "general", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "gracePeriod", section = "general", values = {0, 1, 2}, format = {"fh_set_off", "fh_set_firstYear", "fh_set_firstTwoYears"}, default = 1},
    {name = "fodderCrops", section = "general", values = {1, 0}, format = ON_OFF, default = 2},
    {name = "farmLimit", section = "general", values = {0, 1, 2, 3, 5, 10}, format = {"fh_set_unlimited", "1", "2", "3", "5", "10"}, default = 1},
    {name = "diseaseChance", section = "chances", values = CHANCES, format = "percent", default = 4},
    {name = "pestChance", section = "chances", values = CHANCES, format = "percent", default = 3},
    {name = "careInfluence", section = "chances", values = {0, 0.5, 1, 1.5}, format = {"fh_set_none", "fh_set_low", "fh_set_normal", "fh_set_high"}, default = 3},
    {name = "weatherInfluence", section = "chances", values = {0, 0.5, 1, 1.5}, format = {"fh_set_none", "fh_set_low", "fh_set_normal", "fh_set_high"}, default = 3},
    {name = "stubbleRisk", section = "chances", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "precisionFarming", section = "chances", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "progression", section = "development", values = {1.0, 0.5, 0.25}, format = {"fh_set_slow", "fh_set_normalPace", "fh_set_fast"}, default = 2},
    {name = "spread", section = "development", values = {0.5, 1, 2}, format = {"fh_set_small", "fh_set_medium", "fh_set_large"}, default = 2},
    {name = "patchSize", section = "development", values = {0.6, 1, 1.5}, format = {"fh_set_patchSmall", "fh_set_patchNormal", "fh_set_patchLarge"}, default = 2},
    {name = "neighbourSpread", section = "development", values = {0, 0.5, 1, 2}, format = {"fh_set_off", "fh_set_rarely", "fh_set_sometimes", "fh_set_often"}, default = 3},
    {name = "damage", section = "development", values = {0, 1, 3, 6}, format = {"fh_set_off", "fh_set_damageLow", "fh_set_damageNormal", "fh_set_damageHigh"}, default = 3},
    {name = "protectionThreshold", section = "spraying", values = {0.75, 0.80, 0.85, 0.90, 0.95}, format = "percent", default = 4},
    {name = "protectionDuration", section = "spraying", values = {0, 2, 1, 0.5}, format = {"fh_set_untilHarvest", "fh_set_twoMonths", "fh_set_oneMonth", "fh_set_halfMonth"}, default = 1},
    {name = "fungicideUsage", section = "spraying", values = RATES, format = "percent", default = 4},
    {name = "insecticideUsage", section = "spraying", values = RATES, format = "percent", default = 4},
    {name = "aiSprayNeeded", section = "spraying", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "preSowingSpray", section = "spraying", values = {1, 0}, format = ON_OFF, default = 2},
    {name = "oneSpray", section = "spraying", values = {1, 0}, format = ON_OFF, default = 2},
    {name = "fungicidePrice", section = "prices", values = PRICES_SMALL, format = "money", default = 5},
    {name = "insecticidePrice", section = "prices", values = PRICES_SMALL, format = "money", default = 8},
    {name = "fungicideCanisterPrice", section = "prices", values = PRICES_MEDIUM, format = "money", default = 6},
    {name = "insecticideCanisterPrice", section = "prices", values = PRICES_MEDIUM, format = "money", default = 9},
    {name = "fungicideCanister20Price", section = "prices", values = PRICES_LARGE, format = "money", default = 7},
    {name = "insecticideCanister20Price", section = "prices", values = PRICES_LARGE, format = "money", default = 10},
    {name = "notifications", section = "display", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "fieldInfo", section = "display", values = {1, 0}, format = ON_OFF, default = 1},
    {name = "fieldInfoRisk", section = "display", values = {1, 0}, format = ON_OFF, default = 1}
}

-- Parts of the settings tab, in this order (header text fh_settings_section_<name>).
FHSettings.SECTIONS = {"general", "chances", "development", "spraying", "prices", "display"}

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

-- Whether threats of a category ("disease" or "pest") are switched on.
function FHSettings.isCategoryOn(category)
    return FHSettings.isOn("enabled") and FHSettings.isOn(category == "disease" and "diseases" or "pests")
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

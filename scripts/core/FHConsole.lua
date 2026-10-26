-- Field Health: console commands for admins and testing. Commands that change
-- the simulation run on the server; a client forwards them (admin only).
FHConsole = {}

FHConsole.COMMANDS = {
    {name = "fhInfo", method = "cmdInfo", help = "Field Health data of a field: fhInfo [fieldId|here]"},
    {name = "fhList", method = "cmdList", help = "List all threat keys"},
    {name = "fhSet", method = "cmdSet", help = "Put a threat on a field: fhSet <fieldId|here> <threatKey> [severity 1-3]"},
    {name = "fhClear", method = "cmdClear", help = "Remove all threats of a field: fhClear <fieldId|here>"},
    {name = "fhDailyTick", method = "cmdDailyTick", help = "Run the daily threat check now"},
    {name = "fhDebug", method = "cmdDebug", help = "Show threat and protection cells around you: fhDebug [radius]"},
    {name = "fhDebugLog", method = "cmdDebugLog", help = "Toggle detailed Field Health messages in the log"},
    {name = "fhPrecisionFarming", method = "cmdPrecisionFarming", help = "Write how Precision Farming data is read to the log"}
}

-- Commands a client may forward to the server.
FHConsole.REMOTE = {fhSet = true, fhClear = true, fhDailyTick = true}

function FHConsole:register()
    for _, command in ipairs(FHConsole.COMMANDS) do
        addConsoleCommand(command.name, command.help, command.method, self)
    end
end

function FHConsole:unregister()
    for _, command in ipairs(FHConsole.COMMANDS) do
        removeConsoleCommand(command.name)
    end
end

-- "here" or nothing means the field under the player.
local function fieldIdOf(argument)
    if argument == nil or argument == "" or argument == "here" then
        return FHUtil.getFieldId(FHUtil.getFieldAtPlayer())
    end
    return tonumber(argument)
end

local function serverOrForward(name, ...)
    if g_server ~= nil then
        return FHConsole:runOnServer(name, ...)
    end
    FHRequestEvent.sendCommand(name, ...)
    return "Sent to the server: " .. name
end

function FHConsole:runOnServer(name, a, b, c)
    if name == "fhSet" then
        return FHSimulation:forceThreat(tonumber(a), b, c)
    elseif name == "fhClear" then
        return FHSimulation:clearFieldThreats(tonumber(a))
    elseif name == "fhDailyTick" then
        FHSimulation:queueDay()
        return "Daily threat check queued"
    end
    return "Unknown command: " .. tostring(name)
end

function FHConsole:cmdInfo(fieldArg)
    local fieldId = fieldIdOf(fieldArg)
    local entry = FHSimulation:getEntry(fieldId)
    if entry == nil then
        return "No Field Health data for field " .. tostring(fieldId)
    end

    local fertilizers = {}
    for name in pairs(FHRisk.FERTILIZERS) do
        if FHRisk.hasFertilizer(entry.fertilizerFlags, name) then
            fertilizers[#fertilizers + 1] = name
        end
    end
    table.sort(fertilizers)

    local lines = {
        string.format("Field %s: crop=%s (active=%s, %d days), previous crop=%s, catch crop before=%s", tostring(fieldId),
            tostring(entry.cropFruitName), tostring(entry.cropActive), entry.activeDays or 0, tostring(entry.previousCropFruitName), tostring(entry.catchCropBefore)),
        "  fertilizers since harvest: " .. (#fertilizers > 0 and table.concat(fertilizers, ", ") or "none")
    }
    for _, category in ipairs(FHThreats.CATEGORIES) do
        local slot = FHSimulation.SLOT[category]
        lines[#lines + 1] = string.format("  %s: threat=%s severity=%d used=%s protection=%s risk x%.2f (%s) pressure %.2f/%.2f",
            category, tostring(entry[slot.key]), entry[slot.state] or 0, tostring(entry[slot.used]), FHUtil.percent(entry[slot.protection] or 0),
            entry[slot.risk] or 1, tostring(entry[slot.cause]), entry[slot.pressure] or 0, entry[slot.target] or 0)
    end

    -- details per threat are only known on the server
    local field = g_server ~= nil and FHUtil.getField(fieldId) or nil
    local snapshot = field ~= nil and FHRisk.getFieldSnapshot(field) or nil
    if snapshot ~= nil and snapshot.isActiveCrop then
        local work = FHRisk.getFieldWork(snapshot, entry)
        local parts = {}
        for name, value in pairs(work) do
            if name ~= "soilTypeIndex" then
                parts[#parts + 1] = string.format("%s=%.2f", name, value)
            end
        end
        if work.soilTypeIndex ~= nil then
            parts[#parts + 1] = "soilType=" .. work.soilTypeIndex
        end
        table.sort(parts)
        local month = FHUtil.getMonth()
        lines[#lines + 1] = string.format("  field work (0 = done): %s, growth stage %s, month %d", table.concat(parts, " "), tostring(snapshot.stage), month)
        lines[#lines + 1] = string.format("  field work read at %d points with the crop%s", snapshot.harvestSamples or 0,
            (snapshot.harvestSamples or 0) == 0 and " (none: stubble and rolling are not judged)" or "")
        lines[#lines + 1] = string.format("  weather of the last days: %s C, wetness %.2f",
            FHWeather.temperature ~= nil and string.format("%.1f", FHWeather.temperature) or "?", FHWeather.wetness or 0)
        for _, threat in ipairs(FHThreats.forCrop(snapshot.fruitName)) do
            local timing = FHThreats.getTiming(threat, snapshot.stage, month)
            lines[#lines + 1] = string.format("  %s: risk x%.2f, prevalence %.2f, timing %.2f, weather x%.2f%s", threat.key,
                FHRisk.getThreatMultiplier(threat, snapshot, entry, work), threat.prevalence, timing, FHWeather:getFactor(threat),
                timing > 0 and " (possible now)" or "")
        end
    end
    return table.concat(lines, "\n")
end

function FHConsole:cmdList()
    local lines = {}
    for _, threat in ipairs(FHThreats.LIST) do
        lines[#lines + 1] = string.format("%s (%s)", threat.key, threat.category)
    end
    return table.concat(lines, "\n")
end

function FHConsole:cmdSet(fieldArg, threatKey, severity)
    local fieldId = fieldIdOf(fieldArg)
    if fieldId == nil or threatKey == nil then
        return "Usage: fhSet <fieldId|here> <threatKey> [severity 1-3]"
    end
    return serverOrForward("fhSet", tostring(fieldId), threatKey, severity or "1")
end

function FHConsole:cmdClear(fieldArg)
    local fieldId = fieldIdOf(fieldArg)
    if fieldId == nil then
        return "Usage: fhClear <fieldId|here>"
    end
    return serverOrForward("fhClear", tostring(fieldId))
end

function FHConsole:cmdDailyTick()
    return serverOrForward("fhDailyTick")
end

function FHConsole:cmdDebug(radius)
    return FHFieldMap:toggleDebug(radius)
end

function FHConsole:cmdDebugLog()
    FHUtil.verbose = not FHUtil.verbose
    return "Field Health debug log: " .. (FHUtil.verbose and "on" or "off")
end

function FHConsole:cmdPrecisionFarming()
    local x, _, z = FHUtil.getPlayerPosition()
    print(FHPrecisionFarming.getDiagnostics(x, z))
    return "Precision Farming diagnostics written to the log"
end

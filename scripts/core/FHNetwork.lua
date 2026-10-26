-- Field Health: multiplayer. The server sends field states and changed map
-- cells twice a second and the whole state to joining players in small
-- parts. Clients never change the simulation themselves.
FHNetwork = {}

FHNetwork.INTERVAL = 500
FHNetwork.MAX_CELLS_PER_UPDATE = 8192
FHNetwork.SNAPSHOT_ROWS_PER_FRAME = 32
FHNetwork.SNAPSHOT_CELLS_PER_EVENT = 2048
-- a client asks again if the join state did not arrive (ms)
FHNetwork.CLIENT_RETRY = 15000

function FHNetwork:load()
    self.timer = 0
    self.signatures = {}
    self.joins = {}
    self.waitingForFields = g_server == nil
    self.waitingForMap = g_server == nil
    self.retryTimer = FHNetwork.CLIENT_RETRY
end

function FHNetwork:unload()
    self.joins = {}
    self.signatures = {}
end

---------------------------------------------------------------------------
-- Field entries on the wire
---------------------------------------------------------------------------

function FHNetwork.writeEntry(streamId, entry)
    for _, def in ipairs(FHSimulation.ENTRY) do
        if def.net then
            local value = entry[def.name]
            if def.type == "bool" then
                streamWriteBool(streamId, value == true)
            elseif def.type == "int" then
                streamWriteInt32(streamId, value or 0)
            elseif def.type == "float" then
                streamWriteFloat32(streamId, value or 0)
            elseif streamWriteBool(streamId, value ~= nil) then
                streamWriteString(streamId, value)
            end
        end
    end
end

function FHNetwork.readEntry(streamId)
    local entry = FHSimulation.newEntry()
    for _, def in ipairs(FHSimulation.ENTRY) do
        if def.net then
            if def.type == "bool" then
                entry[def.name] = streamReadBool(streamId)
            elseif def.type == "int" then
                entry[def.name] = streamReadInt32(streamId)
            elseif def.type == "float" then
                entry[def.name] = streamReadFloat32(streamId)
            elseif streamReadBool(streamId) then
                entry[def.name] = streamReadString(streamId)
            end
        end
    end
    return entry
end

local function signature(entry)
    local parts = {}
    for _, def in ipairs(FHSimulation.ENTRY) do
        if def.net then
            local value = entry[def.name]
            parts[#parts + 1] = def.type == "float" and string.format("%.2f", value or 0) or tostring(value)
        end
    end
    return table.concat(parts, "|")
end

local function allEntries()
    local list = {}
    for fieldId, entry in pairs(FHSimulation.fields or {}) do
        list[#list + 1] = {fieldId = fieldId, entry = entry}
    end
    return list
end

---------------------------------------------------------------------------
-- Server
---------------------------------------------------------------------------

function FHNetwork:update(dt)
    if g_server == nil then
        self:updateClient(dt)
        return
    end

    self:runJoins()
    self.timer = self.timer - dt
    if self.timer > 0 then
        return
    end
    self.timer = FHNetwork.INTERVAL
    if not FHUtil.isMultiplayer() or FHSimulation.fields == nil then
        return
    end

    local cells = FHFieldMap:takePending(FHNetwork.MAX_CELLS_PER_UPDATE)
    if #cells > 0 then
        FHSyncEvent.broadcastCells(cells)
    end

    local changed = {}
    for fieldId, entry in pairs(FHSimulation.fields) do
        local current = signature(entry)
        if self.signatures[fieldId] ~= current then
            self.signatures[fieldId] = current
            changed[#changed + 1] = {fieldId = fieldId, entry = entry}
        end
    end
    if #changed > 0 then
        FHSyncEvent.broadcastFields(changed, false)
    end
end

-- Settings and fields at once, the field map over the next frames.
function FHNetwork:sendJoinState(connection)
    if g_server == nil or connection == nil or FHSimulation.fields == nil then
        return
    end
    FHSyncEvent.sendSettings(connection)
    FHSyncEvent.sendFields(connection, allEntries(), true)

    for i = #self.joins, 1, -1 do
        if self.joins[i].connection == connection then
            table.remove(self.joins, i)
        end
    end
    table.insert(self.joins, {connection = connection, row = 0, first = true, cells = {}})
end

function FHNetwork:runJoins()
    local join = self.joins[1]
    if join == nil then
        return
    end

    join.row = FHFieldMap:collectRows(join.row, FHNetwork.SNAPSHOT_ROWS_PER_FRAME, join.cells)
    local done = join.row >= FHFieldMap.size
    local limit = FHNetwork.SNAPSHOT_CELLS_PER_EVENT
    while done or #join.cells >= limit do
        local part, rest = {}, {}
        for i, cell in ipairs(join.cells) do
            if i <= limit then
                part[#part + 1] = cell
            else
                rest[#rest + 1] = cell
            end
        end
        local last = done and #rest == 0
        local sent = pcall(FHSyncEvent.sendMapPart, join.connection, part, join.first, last)
        join.first = false
        join.cells = rest
        if not sent or last then
            table.remove(self.joins, 1)
            return
        end
    end
end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------

function FHNetwork:updateClient(dt)
    if not self.waitingForFields and not self.waitingForMap then
        return
    end
    -- fallback when the join state did not arrive
    self.retryTimer = self.retryTimer - dt
    if self.retryTimer <= 0 then
        self.retryTimer = FHNetwork.CLIENT_RETRY
        FHRequestEvent.sendJoinStateRequest()
    end
end

function FHNetwork:receiveFields(entries, replaceAll)
    if FHSimulation.fields == nil then
        return
    end
    if replaceAll then
        FHSimulation.fields = {}
        self.waitingForFields = false
    end
    for _, item in ipairs(entries) do
        FHSimulation.fields[item.fieldId] = item.entry
    end
end

function FHNetwork:receiveMapPart(cells, first, last)
    FHFieldMap:applyRemote(cells, first)
    if last then
        self.waitingForMap = false
    end
end

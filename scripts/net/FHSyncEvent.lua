-- Field Health: everything the server sends to clients, in one event class.
-- The first value on the wire says what follows.
FHSyncEvent = {}
local FHSyncEvent_mt = Class(FHSyncEvent, Event)
InitEventClass(FHSyncEvent, "FHSyncEvent")

FHSyncEvent.FIELDS = 1     -- field entries
FHSyncEvent.CELLS = 2      -- changed cells of the field map
FHSyncEvent.MAP_PART = 3   -- part of the whole field map for a joining player
FHSyncEvent.SETTINGS = 4   -- all settings
FHSyncEvent.ALERT = 5      -- a threat appeared, became severe or came from a neighbour
FHSyncEvent.KIND_BITS = 3

local ALERT_KINDS = {"new", "severe", "neighbour"}

function FHSyncEvent.emptyNew()
    return Event.new(FHSyncEvent_mt)
end

function FHSyncEvent.new(kind, payload)
    local self = FHSyncEvent.emptyNew()
    self.kind = kind
    self.payload = payload
    return self
end

local function writeText(streamId, value)
    if streamWriteBool(streamId, value ~= nil) then
        streamWriteString(streamId, value)
    end
end

local function readText(streamId)
    return streamReadBool(streamId) and streamReadString(streamId) or nil
end

local function writeCells(streamId, cells)
    streamWriteUInt16(streamId, #cells)
    for _, cell in ipairs(cells) do
        streamWriteUInt16(streamId, cell.x)
        streamWriteUInt16(streamId, cell.z)
        streamWriteUIntN(streamId, cell.value, FHFieldMap.BITS)
    end
end

local function readCells(streamId)
    local cells = {}
    for i = 1, streamReadUInt16(streamId) do
        cells[i] = {x = streamReadUInt16(streamId), z = streamReadUInt16(streamId), value = streamReadUIntN(streamId, FHFieldMap.BITS)}
    end
    return cells
end

function FHSyncEvent:writeStream(streamId, connection)
    local payload = self.payload
    streamWriteUIntN(streamId, self.kind, FHSyncEvent.KIND_BITS)

    if self.kind == FHSyncEvent.FIELDS then
        streamWriteBool(streamId, payload.replaceAll == true)
        streamWriteUInt16(streamId, #payload.entries)
        for _, item in ipairs(payload.entries) do
            streamWriteUInt16(streamId, item.fieldId)
            FHNetwork.writeEntry(streamId, item.entry)
        end
    elseif self.kind == FHSyncEvent.CELLS then
        writeCells(streamId, payload.cells)
    elseif self.kind == FHSyncEvent.MAP_PART then
        streamWriteBool(streamId, payload.first == true)
        streamWriteBool(streamId, payload.last == true)
        writeCells(streamId, payload.cells)
    elseif self.kind == FHSyncEvent.SETTINGS then
        FHSettings.writeStream(streamId)
    elseif self.kind == FHSyncEvent.ALERT then
        local kindIndex = 1
        for i, name in ipairs(ALERT_KINDS) do
            if name == payload.kind then
                kindIndex = i
            end
        end
        streamWriteUIntN(streamId, kindIndex, 2)
        streamWriteUInt16(streamId, payload.fieldId or 0)
        writeText(streamId, payload.threatKey)
        writeText(streamId, payload.fruitName)
        if streamWriteBool(streamId, payload.farmId ~= nil) then
            streamWriteUIntN(streamId, payload.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        end
    end
end

function FHSyncEvent:readStream(streamId, connection)
    self.kind = streamReadUIntN(streamId, FHSyncEvent.KIND_BITS)
    local payload = {}

    if self.kind == FHSyncEvent.FIELDS then
        payload.replaceAll = streamReadBool(streamId)
        payload.entries = {}
        for i = 1, streamReadUInt16(streamId) do
            local fieldId = streamReadUInt16(streamId)
            payload.entries[i] = {fieldId = fieldId, entry = FHNetwork.readEntry(streamId)}
        end
    elseif self.kind == FHSyncEvent.CELLS then
        payload.cells = readCells(streamId)
    elseif self.kind == FHSyncEvent.MAP_PART then
        payload.first = streamReadBool(streamId)
        payload.last = streamReadBool(streamId)
        payload.cells = readCells(streamId)
    elseif self.kind == FHSyncEvent.SETTINGS then
        payload.indices = FHSettings.readStream(streamId)
    elseif self.kind == FHSyncEvent.ALERT then
        payload.kind = ALERT_KINDS[streamReadUIntN(streamId, 2)] or "new"
        payload.fieldId = streamReadUInt16(streamId)
        payload.threatKey = readText(streamId)
        payload.fruitName = readText(streamId)
        if streamReadBool(streamId) then
            payload.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        end
    end

    self.payload = payload
    self:run(connection)
end

function FHSyncEvent:run(connection)
    -- only the server may send these
    if not connection:getIsServer() then
        return
    end
    local payload = self.payload
    if self.kind == FHSyncEvent.FIELDS then
        FHNetwork:receiveFields(payload.entries, payload.replaceAll)
    elseif self.kind == FHSyncEvent.CELLS then
        FHFieldMap:applyRemote(payload.cells, false)
    elseif self.kind == FHSyncEvent.MAP_PART then
        FHNetwork:receiveMapPart(payload.cells, payload.first, payload.last)
    elseif self.kind == FHSyncEvent.SETTINGS then
        FHSettings.applyAll(payload.indices)
    elseif self.kind == FHSyncEvent.ALERT then
        FHSimulation:showAlert(payload)
    end
end

function FHSyncEvent.broadcastFields(entries, replaceAll)
    g_server:broadcastEvent(FHSyncEvent.new(FHSyncEvent.FIELDS, {entries = entries, replaceAll = replaceAll}), false)
end

function FHSyncEvent.sendFields(connection, entries, replaceAll)
    connection:sendEvent(FHSyncEvent.new(FHSyncEvent.FIELDS, {entries = entries, replaceAll = replaceAll}))
end

function FHSyncEvent.broadcastCells(cells)
    g_server:broadcastEvent(FHSyncEvent.new(FHSyncEvent.CELLS, {cells = cells}), false)
end

function FHSyncEvent.sendMapPart(connection, cells, first, last)
    connection:sendEvent(FHSyncEvent.new(FHSyncEvent.MAP_PART, {cells = cells, first = first, last = last}))
end

function FHSyncEvent.broadcastSettings()
    g_server:broadcastEvent(FHSyncEvent.new(FHSyncEvent.SETTINGS, {}), false)
end

function FHSyncEvent.sendSettings(connection)
    connection:sendEvent(FHSyncEvent.new(FHSyncEvent.SETTINGS, {}))
end

function FHSyncEvent.broadcastAlert(message)
    g_server:broadcastEvent(FHSyncEvent.new(FHSyncEvent.ALERT, message), false)
end

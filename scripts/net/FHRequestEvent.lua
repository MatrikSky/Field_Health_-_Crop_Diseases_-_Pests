-- Field Health: requests of a client to the server, in one event class.
-- Changing settings and admin commands are only accepted from the admin.
FHRequestEvent = {}
local FHRequestEvent_mt = Class(FHRequestEvent, Event)
InitEventClass(FHRequestEvent, "FHRequestEvent")

FHRequestEvent.JOIN_STATE = 1  -- send me the whole state again
FHRequestEvent.SETTING = 2     -- change one setting
FHRequestEvent.COMMAND = 3     -- run an admin console command
FHRequestEvent.KIND_BITS = 2
FHRequestEvent.MAX_ARGS = 3

function FHRequestEvent.emptyNew()
    return Event.new(FHRequestEvent_mt)
end

function FHRequestEvent.new(kind, name, values)
    local self = FHRequestEvent.emptyNew()
    self.kind = kind
    self.name = name
    self.values = values or {}
    return self
end

function FHRequestEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.kind, FHRequestEvent.KIND_BITS)
    if self.kind == FHRequestEvent.SETTING then
        streamWriteString(streamId, self.name)
        streamWriteUIntN(streamId, self.values[1], FHSettings.INDEX_BITS)
    elseif self.kind == FHRequestEvent.COMMAND then
        streamWriteString(streamId, self.name)
        for i = 1, FHRequestEvent.MAX_ARGS do
            local value = self.values[i]
            if streamWriteBool(streamId, value ~= nil) then
                streamWriteString(streamId, tostring(value))
            end
        end
    end
end

function FHRequestEvent:readStream(streamId, connection)
    self.kind = streamReadUIntN(streamId, FHRequestEvent.KIND_BITS)
    self.values = {}
    if self.kind == FHRequestEvent.SETTING then
        self.name = streamReadString(streamId)
        self.values[1] = streamReadUIntN(streamId, FHSettings.INDEX_BITS)
    elseif self.kind == FHRequestEvent.COMMAND then
        self.name = streamReadString(streamId)
        for i = 1, FHRequestEvent.MAX_ARGS do
            if streamReadBool(streamId) then
                self.values[i] = streamReadString(streamId)
            end
        end
    end
    self:run(connection)
end

local function isAdmin(connection)
    local userManager = g_currentMission ~= nil and g_currentMission.userManager or nil
    local user = userManager ~= nil and userManager:getUserByConnection(connection) or nil
    return user ~= nil and user:getIsMasterUser()
end

function FHRequestEvent:run(connection)
    -- only clients send requests
    if connection:getIsServer() then
        return
    end
    if self.kind == FHRequestEvent.JOIN_STATE then
        FHNetwork:sendJoinState(connection)
    elseif self.kind == FHRequestEvent.SETTING and isAdmin(connection) then
        FHSettings.select(self.name, self.values[1])
    elseif self.kind == FHRequestEvent.COMMAND and isAdmin(connection) and FHConsole.REMOTE[self.name] then
        FHUtil.log("%s", FHConsole:runOnServer(self.name, self.values[1], self.values[2], self.values[3]))
    end
end

local function toServer(event)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(event)
    end
end

function FHRequestEvent.sendJoinStateRequest()
    toServer(FHRequestEvent.new(FHRequestEvent.JOIN_STATE))
end

function FHRequestEvent.sendSetting(name, index)
    toServer(FHRequestEvent.new(FHRequestEvent.SETTING, name, {index}))
end

function FHRequestEvent.sendCommand(name, ...)
    toServer(FHRequestEvent.new(FHRequestEvent.COMMAND, name, {...}))
end

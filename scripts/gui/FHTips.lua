-- Field Health: tips in a panel at the bottom of the screen. General tips
-- come one after another in a fixed order, at random intervals. Event tips
-- come when something happens: a sprayer with a liquid is ready, the player
-- sprays, a threat reaches the severe stage. A threat tip describes a disease
-- or pest the first time it appears on one of the player's fields. Every tip
-- is shown once per player: the history is kept in the player's profile, for
-- all savegames, until the player resets it in the settings. Nothing of this
-- goes into the savegame.
FHTips = {}

FHTips.FILE = "modSettings/FS25_FieldHealth/tips.xml"
FHTips.FILE_VERSION = 1

-- General tips in the order they are shown.
FHTips.GENERAL = {"welcome", "monitoring", "products", "whenToSpray", "protection", "farming", "weather", "aiHelper", "settings"}
-- Event tips in the order they are shown when several wait; threat tips
-- (id THREAT_PREFIX .. threat name) come before all of them.
FHTips.EVENTS = {"severe", "sprayerReady", "spraying"}
FHTips.THREAT_PREFIX = "threat_"

-- Minutes of play between two general tips (randomised below).
FHTips.FREQUENCIES = {
    {text = "fh_set_rarely", minutes = 20},
    {text = "fh_set_sometimes", minutes = 10},
    {text = "fh_set_often", minutes = 5}
}
FHTips.DEFAULT_FREQUENCY = 2
FHTips.FIRST_DELAY = {45000, 90000}
FHTips.SPREAD = {0.6, 1.4}
-- no tip right after another one (ms)
FHTips.DOWNTIME = 45000
-- an event tip that could not be shown at once waits this long at most; a
-- threat description waits longer, as several threats can appear on one day
FHTips.EVENT_WAIT = 120000
FHTips.THREAT_WAIT = 900000
FHTips.CHECK_INTERVAL = 500

FHTips.DURATION_MIN = 10000
FHTips.DURATION_MAX = 32000
FHTips.DURATION_PER_CHAR = 65
FHTips.FADE_IN = 250
FHTips.FADE_OUT = 500

FHTips.PANEL = {
    width = 0.38, bottom = 0.1, padding = 0.009, gap = 0.006,
    titleSize = 0.0165, textSize = 0.0145, lineSpacing = 1.25,
    background = {0, 0, 0, 0.72}, divider = {1, 1, 1, 0.18},
    title = {0.45, 0.78, 0.26, 1}, label = {1, 1, 1, 0.55}, text = {1, 1, 1, 1}
}

function FHTips:load()
    self.enabled = true
    self.frequency = FHTips.DEFAULT_FREQUENCY
    self.seen = {}
    self.queue = {}
    self.current = nil
    self.downtime = 0
    self.checkTimer = 0
    self.nextGeneral = FHTips.randomDelay(FHTips.FIRST_DELAY)
    self.lines = nil
    self:readFile()
end

function FHTips:unload()
    self.current = nil
    self.queue = {}
end

function FHTips.randomDelay(range)
    return range[1] + math.random() * (range[2] - range[1])
end

function FHTips:getInterval()
    local frequency = FHTips.FREQUENCIES[self.frequency] or FHTips.FREQUENCIES[FHTips.DEFAULT_FREQUENCY]
    local minutes = frequency.minutes * 60000
    return FHTips.randomDelay({minutes * FHTips.SPREAD[1], minutes * FHTips.SPREAD[2]})
end

---------------------------------------------------------------------------
-- History in the player's profile
---------------------------------------------------------------------------

local function filePath()
    return getUserProfileAppPath ~= nil and getUserProfileAppPath() .. FHTips.FILE or nil
end

function FHTips:readFile()
    local path = filePath()
    if path == nil or fileExists == nil or not fileExists(path) then
        return
    end
    local xmlFile = loadXMLFile("fieldHealthTips", path)
    if xmlFile == nil or xmlFile == 0 then
        return
    end
    local enabled = getXMLBool(xmlFile, "fieldHealthTips#enabled")
    if enabled ~= nil then
        self.enabled = enabled
    end
    local frequency = getXMLInt(xmlFile, "fieldHealthTips#frequency")
    if frequency ~= nil and FHTips.FREQUENCIES[frequency] ~= nil then
        self.frequency = frequency
    end
    for id in string.gmatch(getXMLString(xmlFile, "fieldHealthTips#seen") or "", "%S+") do
        self.seen[id] = true
    end
    delete(xmlFile)
end

function FHTips:writeFile()
    local path = filePath()
    if path == nil or g_dedicatedServer ~= nil then
        return
    end
    if createFolder ~= nil then
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. "modSettings/FS25_FieldHealth/")
    end
    local xmlFile = createXMLFile("fieldHealthTips", path, "fieldHealthTips")
    if xmlFile == nil or xmlFile == 0 then
        return
    end
    local seen = {}
    for id in pairs(self.seen) do
        seen[#seen + 1] = id
    end
    table.sort(seen)
    setXMLInt(xmlFile, "fieldHealthTips#version", FHTips.FILE_VERSION)
    setXMLBool(xmlFile, "fieldHealthTips#enabled", self.enabled)
    setXMLInt(xmlFile, "fieldHealthTips#frequency", self.frequency)
    setXMLString(xmlFile, "fieldHealthTips#seen", table.concat(seen, " "))
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

---------------------------------------------------------------------------
-- Settings of the player (section Tips of the settings tab)
---------------------------------------------------------------------------

function FHTips:setEnabled(enabled)
    self.enabled = enabled == true
    if not self.enabled then
        self.current, self.queue = nil, {}
    end
    self:writeFile()
end

function FHTips:setFrequency(index)
    if FHTips.FREQUENCIES[index] ~= nil then
        self.frequency = index
        self.nextGeneral = math.min(self.nextGeneral, self:getInterval())
        self:writeFile()
    end
end

function FHTips:getFrequencyLabels()
    local labels = {}
    for i, frequency in ipairs(FHTips.FREQUENCIES) do
        labels[i] = FHUtil.text(frequency.text)
    end
    return labels
end

-- All tips again, starting with the first one shortly.
function FHTips:reset()
    self.seen = {}
    self.queue = {}
    self.current = nil
    self.downtime = 0
    self.nextGeneral = FHTips.FIRST_DELAY[1]
    self:writeFile()
end

---------------------------------------------------------------------------
-- Which tip comes next
---------------------------------------------------------------------------

function FHTips:getNextGeneral()
    for _, id in ipairs(FHTips.GENERAL) do
        if not self.seen[id] then
            return id
        end
    end
    return nil
end

-- The threat a threat tip describes, nil for other tips.
function FHTips.getThreat(id)
    if type(id) ~= "string" or string.sub(id, 1, #FHTips.THREAT_PREFIX) ~= FHTips.THREAT_PREFIX then
        return nil
    end
    local name = string.sub(id, #FHTips.THREAT_PREFIX + 1)
    for _, threat in ipairs(FHThreats.LIST) do
        if threat.name == name then
            return threat
        end
    end
    return nil
end

function FHTips.isEvent(id)
    if FHTips.getThreat(id) ~= nil then
        return true
    end
    for _, eventId in ipairs(FHTips.EVENTS) do
        if eventId == id then
            return true
        end
    end
    return false
end

-- Values filled into the texts: names as the game shows them and the
-- protection threshold of the settings, as a whole number of percent.
function FHTips.getArguments(id)
    local threshold = tostring(math.floor(FHSettings.get("protectionThreshold") * 100 + 0.5))
    if id == "monitoring" or id == "sprayerReady" then
        return {FHUtil.text("fh_map_page")}
    elseif id == "protection" then
        return {threshold, FHUtil.text("fh_setting_oneSpray")}
    elseif id == "spraying" then
        return {threshold}
    elseif id == "settings" then
        return {FHUtil.text("fh_setting_farmLimit"), FHUtil.text("fh_setting_oneSpray"), FHUtil.text("fh_settings_section_crops")}
    end
    return {}
end

-- Title and text of a tip; extra is the category of the sprayer's liquid
-- (the insecticide has a text of its own).
function FHTips.getText(id, extra)
    local threat = FHTips.getThreat(id)
    if threat ~= nil then
        return FHUtil.text(threat.key), FHUtil.text("fh_tipThreat_" .. threat.name)
    end
    local title = FHUtil.text("fh_tip_" .. id .. "_title")
    local text = FHUtil.text("fh_tip_" .. id .. ((id == "sprayerReady" and extra == "pest") and "_pest" or ""))
    local arguments = FHTips.getArguments(id)
    if #arguments > 0 then
        local ok, formatted = pcall(string.format, text, unpack(arguments))
        if ok then
            text = formatted
        end
    end
    return title, text
end

function FHTips:canShow()
    if not self.enabled or g_dedicatedServer ~= nil or g_currentMission == nil or not FHSettings.isOn("enabled") then
        return false
    end
    local farmId = FHUtil.getLocalFarmId()
    if farmId == nil or farmId == 0 then
        return false
    end
    if g_currentMission.paused or (g_gui ~= nil and g_gui:getIsGuiVisible() and not g_gui:getIsOverlayGuiVisible()) then
        return false
    end
    local hud = g_currentMission.hud
    return hud == nil or hud.getIsVisible == nil or hud:getIsVisible()
end

function FHTips:show(id, extra)
    local title, text = FHTips.getText(id, extra)
    self.current = {
        id = id, title = title, text = text, time = 0,
        duration = FHUtil.clamp(#text * FHTips.DURATION_PER_CHAR, FHTips.DURATION_MIN, FHTips.DURATION_MAX)
    }
    self.lines = nil
    self.seen[id] = true
    self:writeFile()
end

-- Something happened that has a tip of its own.
function FHTips:onEvent(id, extra)
    if not self.enabled or self.seen[id] or not FHTips.isEvent(id) then
        return
    end
    for _, waiting in ipairs(self.queue) do
        if waiting.id == id then
            return
        end
    end
    local wait = FHTips.getThreat(id) ~= nil and FHTips.THREAT_WAIT or FHTips.EVENT_WAIT
    table.insert(self.queue, {id = id, extra = extra, wait = wait})
end

-- Alerts of the simulation (FHSimulation:showAlert, on the clients of the
-- farm): a new threat or one from a neighbour field brings its description.
function FHTips:onAlert(kind, threatKey)
    if kind == "severe" then
        self:onEvent("severe")
        return
    end
    local threat = threatKey ~= nil and FHThreats.get(threatKey) or nil
    if threat ~= nil then
        self:onEvent(FHTips.THREAT_PREFIX .. threat.name)
    end
end

-- The local player's sprayer: ready in a running vehicle, or spraying on a field.
function FHTips:checkSprayer()
    local sprayer, turnedOn, vehicle = FHProducts:getLocalSprayer()
    if sprayer == nil or vehicle == nil then
        return
    end
    if turnedOn then
        local x, _, z = FHUtil.getPlayerPosition()
        if x ~= nil and FHUtil.getFieldAt(x, z) ~= nil then
            self:onEvent("spraying")
        end
        return
    end
    local rootVehicle = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    -- also when the sprayer was attached by hand (e.g. a manual attach mod):
    -- the tip comes once the player sits in the tractor and starts it
    if rootVehicle.getIsMotorStarted == nil or rootVehicle:getIsMotorStarted() then
        self:onEvent("sprayerReady", FHProducts:getVehicleCategory(sprayer))
    end
end

function FHTips:update(dt)
    if g_dedicatedServer ~= nil or not self.enabled then
        return
    end
    for i = #self.queue, 1, -1 do
        local waiting = self.queue[i]
        waiting.wait = waiting.wait - dt
        if waiting.wait <= 0 then
            table.remove(self.queue, i)
        end
    end
    if not self:canShow() then
        return
    end

    self.checkTimer = self.checkTimer - dt
    if self.checkTimer <= 0 then
        self.checkTimer = FHTips.CHECK_INTERVAL
        FHUtil.protect("tips", self.checkSprayer, self)
    end

    local current = self.current
    if current ~= nil then
        current.time = current.time + dt
        if current.time >= current.duration then
            self.current = nil
            self.downtime = FHTips.DOWNTIME
        end
        return
    end
    self.downtime = math.max(0, self.downtime - dt)
    self.nextGeneral = self.nextGeneral - dt
    if self.downtime > 0 then
        return
    end
    -- events first, as they belong to what happens now; threat descriptions
    -- before the other events
    local nextIndex = nil
    for i, waiting in ipairs(self.queue) do
        if nextIndex == nil and FHTips.getThreat(waiting.id) ~= nil then
            nextIndex = i
        end
    end
    for _, eventId in ipairs(FHTips.EVENTS) do
        for i, waiting in ipairs(self.queue) do
            if nextIndex == nil and waiting.id == eventId then
                nextIndex = i
            end
        end
    end
    if nextIndex ~= nil then
        local waiting = table.remove(self.queue, nextIndex)
        if waiting ~= nil and not self.seen[waiting.id] then
            self:show(waiting.id, waiting.extra)
            return
        end
    end
    if self.nextGeneral <= 0 then
        local id = self:getNextGeneral()
        if id ~= nil then
            self:show(id)
        end
        self.nextGeneral = self:getInterval()
    end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function textSize(size)
    return getCorrectTextSize ~= nil and getCorrectTextSize(size) or size
end

-- Lines of a text that fit the width.
function FHTips.wrap(text, size, width)
    local lines = {}
    for paragraph in string.gmatch(text .. "\n", "([^\n]*)\n") do
        local line = ""
        for word in string.gmatch(paragraph, "%S+") do
            local candidate = line == "" and word or line .. " " .. word
            if line ~= "" and getTextWidth(size, candidate) > width then
                lines[#lines + 1] = line
                line = word
            else
                line = candidate
            end
        end
        lines[#lines + 1] = line
    end
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    return lines
end

function FHTips:draw()
    local current = self.current
    if current == nil or not self:canShow() then
        return
    end
    local panel = FHTips.PANEL
    local alpha = math.min(1, current.time / FHTips.FADE_IN, (current.duration - current.time) / FHTips.FADE_OUT)
    if alpha <= 0 then
        return
    end
    local titleSize, bodySize = textSize(panel.titleSize), textSize(panel.textSize)
    local width = panel.width
    local inner = width - 2 * panel.padding
    if self.lines == nil then
        self.lines = FHTips.wrap(current.text, bodySize, inner)
    end
    local lineHeight = bodySize * panel.lineSpacing
    local height = panel.padding * 2 + titleSize + panel.gap * 2 + #self.lines * lineHeight
    local left = 0.5 - width / 2
    local bottom = panel.bottom
    local top = bottom + height

    local function colour(c, a)
        return c[1], c[2], c[3], c[4] * (a or alpha)
    end
    drawFilledRect(left, bottom, width, height, colour(panel.background))

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(colour(panel.title))
    local y = top - panel.padding - titleSize
    renderText(0.5, y, titleSize, utf8ToUpper ~= nil and utf8ToUpper(current.title) or current.title)
    y = y - panel.gap
    drawFilledRect(left + panel.padding, y, inner, g_pixelSizeY or (1 / 1080), colour(panel.divider))
    y = y - panel.gap

    setTextBold(false)
    setTextColor(colour(panel.text))
    for _, line in ipairs(self.lines) do
        y = y - lineHeight
        renderText(0.5, y + (lineHeight - bodySize) * 0.5, bodySize, line)
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

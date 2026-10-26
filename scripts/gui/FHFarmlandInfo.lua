-- Field Health: threat and protection lines in the farmland box of the map
-- (shown when a farmland is clicked). The lines are copies of the box's own
-- "size"/"value" texts placed under the last farmland line; the box grows
-- and everything below (buttons, other mods' sections such as the soil info
-- of Precision Farming) moves down. The original layout is remembered and
-- restored exactly before the lines change.
FHFarmlandInfo = {}

FHFarmlandInfo.MAX_LINES = 4
FHFarmlandInfo.CHECK_INTERVAL = 500

local EPSILON = 0.000001

local function same(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) < EPSILON
end

local function isShown(element)
    if element == nil then
        return false
    end
    if element.getIsVisible ~= nil then
        return element:getIsVisible()
    end
    return element.visible ~= false
end

---------------------------------------------------------------------------
-- Texts
---------------------------------------------------------------------------

-- Short name of the threat of a category on the farmland ("+n" for more kinds).
local function threatOnFarmland(farmlandId, category)
    local names, count, first = {}, 0, nil
    for _, field in ipairs(g_fieldManager:getFields() or {}) do
        if field.farmland ~= nil and field.farmland.id == farmlandId then
            local entry = FHSimulation:getEntry(FHUtil.getFieldId(field))
            local threat = entry ~= nil and FHSimulation:getActiveThreat(entry, category) or nil
            if threat ~= nil and names[threat.key] == nil then
                names[threat.key] = true
                count = count + 1
                first = first or FHThreats.shortName(threat)
            end
        end
    end
    if first == nil then
        return nil
    end
    return count > 1 and string.format("%s +%d", first, count - 1) or first
end

local function protectionText(share)
    if share >= FHSettings.get("protectionThreshold") then
        return FHUtil.text("fh_map_protectedUntilHarvest")
    end
    return FHUtil.percent(share)
end

-- {label, value} pairs for a farmland; empty without growing crops.
function FHFarmlandInfo.buildLines(farmlandId)
    local disease, pest = FHSimulation:getFarmlandProtection(farmlandId)
    if disease == nil then
        return {}
    end
    local lines = {}
    local diseaseThreat = threatOnFarmland(farmlandId, "disease")
    local pestThreat = threatOnFarmland(farmlandId, "pest")
    if diseaseThreat ~= nil then
        lines[#lines + 1] = {FHUtil.text("fh_map_diseaseLabel"), diseaseThreat}
    end
    if pestThreat ~= nil then
        lines[#lines + 1] = {FHUtil.text("fh_map_pestLabel"), pestThreat}
    end
    lines[#lines + 1] = {FHUtil.text("fh_map_diseaseProtectionLabel"), protectionText(disease)}
    lines[#lines + 1] = {FHUtil.text("fh_map_pestProtectionLabel"), protectionText(pest)}
    return lines
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

-- Finds the parts of the farmland box once per menu; false when the box
-- does not look as expected (then nothing is added).
function FHFarmlandInfo:attach(frame)
    if self.frame == frame and self.box ~= nil then
        return true
    end
    local box = frame.contextBoxFarmland
    local sizeText = box ~= nil and box:getDescendantByName("farmlandSize") or nil
    local valueText = box ~= nil and box:getDescendantByName("farmlandValue") or nil
    if sizeText == nil or valueText == nil then
        return false
    end

    -- the label of the lowest farmland line serves as template for labels
    local label = nil
    for _, element in ipairs(box:getDescendants(function(e) return e.profile == "fs25_mapContextFarmlandTitle" end) or {}) do
        if label == nil or element.position[2] < label.position[2] then
            label = element
        end
    end
    if label == nil then
        return false
    end

    local parent = label.parent or box
    local lines = {}
    for i = 1, FHFarmlandInfo.MAX_LINES do
        lines[i] = {label = label:clone(parent), value = valueText:clone(parent)}
        lines[i].label:setVisible(false)
        lines[i].value:setVisible(false)
    end

    local spacing = math.abs(sizeText.position[2] - valueText.position[2])
    if spacing < EPSILON then
        local _, fallback = getNormalizedScreenValues(0, 30)
        spacing = fallback
    end

    self.frame = frame
    self.box = box
    self.labelTemplate = label
    self.lines = lines
    self.spacing = spacing
    self.background = box:getFirstDescendant(function(e) return e.profile ~= nil and string.find(e.profile, "mapContextBoxBgFarmland", 1, true) ~= nil end) or box.elements[1]
    self.buttons = frame.contextButtonListFarmland or box:getDescendantById("contextButtonListFarmland")
    self.applied = nil
    self.signature = nil
    self.timer = 0
    return true
end

-- Lowest visible farmland line next to the template (same column and width).
function FHFarmlandInfo:lowestLine()
    local own = {}
    for _, line in ipairs(self.lines) do
        own[line.label], own[line.value] = true, true
    end
    local template = self.labelTemplate
    local lowest = template
    for _, element in ipairs((template.parent or self.box).elements or {}) do
        if not own[element] and isShown(element) and element.position ~= nil and element.size ~= nil
            and same(element.position[1], template.position[1]) and same(element.size[1], template.size[1])
            and element.position[2] < lowest.position[2] then
            lowest = element
        end
    end
    return lowest
end

-- Elements lying completely below screen height y (searched through containers).
function FHFarmlandInfo:collectBelow(parent, y, skip, found)
    local _, tolerance = getNormalizedScreenValues(0, 2)
    for _, element in ipairs(parent.elements or {}) do
        if not skip[element] and element.absPosition ~= nil and element.absSize ~= nil and element.position ~= nil then
            if element.absPosition[2] + element.absSize[2] <= y + tolerance then
                found[#found + 1] = element
            else
                self:collectBelow(element, y, skip, found)
            end
        end
    end
    return found
end

-- Undoes our changes, but only where nobody else changed the layout since.
function FHFarmlandInfo:restore()
    local applied = self.applied
    if applied ~= nil then
        local shift = applied.shift
        if same(self.box.size[2], applied.boxHeight) then
            self.box:setSize(nil, applied.boxHeight - shift, true)
        end
        if self.background ~= nil and same(self.background.size[2], applied.backgroundHeight) then
            self.background:setSize(nil, applied.backgroundHeight - shift, true)
        end
        if self.buttons ~= nil and same(self.buttons.position[2], applied.buttonsY) then
            self.buttons:setPosition(nil, applied.buttonsY + shift)
        end
        for element, y in pairs(applied.moved) do
            if same(element.position[2], y) then
                element:setPosition(nil, y + shift)
            end
        end
    end
    for _, line in ipairs(self.lines) do
        line.label:setVisible(false)
        line.value:setVisible(false)
    end
    self.applied = nil
end

-- True while our layout is still in place (other mods may reset the box).
function FHFarmlandInfo:isIntact()
    local applied = self.applied
    if applied == nil then
        return true
    end
    for element, y in pairs(applied.moved) do
        if not same(element.position[2], y) then
            return false
        end
    end
    return same(self.box.size[2], applied.boxHeight)
        and (self.background == nil or same(self.background.size[2], applied.backgroundHeight))
        and (self.buttons == nil or same(self.buttons.position[2], applied.buttonsY))
end

function FHFarmlandInfo:show(texts)
    local shift = self.spacing * #texts
    local anchor = self:lowestLine()
    local moved = {}

    if anchor.absPosition ~= nil then
        local skip = {[self.background or false] = true, [self.buttons or false] = true}
        for _, line in ipairs(self.lines) do
            skip[line.label], skip[line.value] = true, true
        end
        for _, element in ipairs(self:collectBelow(self.box, anchor.absPosition[2], skip, {})) do
            element:setPosition(nil, element.position[2] - shift)
            moved[element] = element.position[2]
        end
    end

    for i, text in ipairs(texts) do
        local line = self.lines[i]
        local y = anchor.position[2] - self.spacing * i
        line.label:setPosition(nil, y)
        line.value:setPosition(nil, y)
        line.label:setText(text[1])
        line.value:setText(text[2])
        line.label:setVisible(true)
        line.value:setVisible(true)
    end

    self.box:setSize(nil, self.box.size[2] + shift, true)
    if self.background ~= nil then
        self.background:setSize(nil, self.background.size[2] + shift, true)
    end
    if self.buttons ~= nil then
        self.buttons:setPosition(nil, self.buttons.position[2] - shift)
    end
    self.applied = {
        shift = shift,
        moved = moved,
        boxHeight = self.box.size[2],
        backgroundHeight = self.background ~= nil and self.background.size[2] or nil,
        buttonsY = self.buttons ~= nil and self.buttons.position[2] or nil
    }
end

-- Shows the lines of the selected farmland; does nothing when unchanged.
function FHFarmlandInfo:update(frame, force)
    if FHSimulation.fields == nil or not self:attach(frame) then
        return
    end
    local farmland = frame.selectedFarmland
    local texts = (isShown(self.box) and farmland ~= nil) and FHFarmlandInfo.buildLines(farmland.id) or {}

    local parts = {tostring(farmland ~= nil and farmland.id)}
    for _, text in ipairs(texts) do
        parts[#parts + 1] = text[1] .. "=" .. text[2]
    end
    local signature = table.concat(parts, ";")
    if not force and signature == self.signature and self:isIntact() then
        return
    end

    self:restore()
    self.signature = signature
    if #texts > 0 then
        self:show(texts)
    end
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

InGameMenuMapFrame.update = Utils.appendedFunction(InGameMenuMapFrame.update, function(frame, dt)
    local info = FHFarmlandInfo
    info.timer = (info.timer or 0) + dt
    if info.timer >= FHFarmlandInfo.CHECK_INTERVAL then
        info.timer = 0
        FHUtil.protect("farmland info", info.update, info, frame, false)
    end
end)

if InGameMenuMapUtil ~= nil and InGameMenuMapUtil.showContextBox ~= nil then
    InGameMenuMapUtil.showContextBox = Utils.appendedFunction(InGameMenuMapUtil.showContextBox, function(box, _, _, _, _, _, _, _, _, isFarmlandBox)
        local frame = FHMapPage.frame
        if frame ~= nil and box == frame.contextBoxFarmland and isFarmlandBox ~= false then
            FHUtil.protect("farmland info", FHFarmlandInfo.update, FHFarmlandInfo, frame, true)
        end
    end)
end

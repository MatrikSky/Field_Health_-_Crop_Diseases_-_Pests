-- Field Health: weather of the last days for the infection pressure. The
-- server samples the game weather every in-game hour; at the end of a day
-- the mean temperature of the day and its share of rainy hours update a
-- short memory (leaves stay wet after the rain). Each threat has a weather
-- profile (FHThreats.WEATHER): a temperature range and how much rain helps it.
FHWeather = {}

FHWeather.TUNING = {
    -- typical share of rainy hours; more rain helps wet-loving threats
    normalWetness = 0.2,
    -- weight of the last day in the wetness memory
    wetnessMemory = 0.5,
    -- weather factor: temperature outside the range / in the optimum
    coldFactor = 0.4,
    optimumFactor = 1.2,
    -- rain: change of the factor per share of rainy hours, and its limits
    wetEffect = 2.5,
    minWetFactor = 0.4,
    maxWetFactor = 1.8,
    minFactor = 0.2,
    maxFactor = 2.5
}

function FHWeather:reset()
    self.temperature = nil
    self.wetness = FHWeather.TUNING.normalWetness
    self.lastHour = nil
    self:clearSamples()
end

function FHWeather:clearSamples()
    self.samples = {count = 0, temperature = 0, rain = 0}
end

-- Temperature (degrees Celsius) and whether it rains or snows now.
local function readWeather()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local weather = environment ~= nil and environment.weather or nil
    if weather == nil or weather.getCurrentTemperature == nil then
        return nil
    end
    local temperature = tonumber(weather:getCurrentTemperature())
    local raining = (weather.getIsRaining ~= nil and weather:getIsRaining())
        or (weather.getRainFallScale ~= nil and (tonumber(weather:getRainFallScale()) or 0) > 0.1)
    return temperature, raining == true
end

function FHWeather:sample()
    local temperature, raining = readWeather()
    if temperature == nil then
        return
    end
    local samples = self.samples
    samples.count = samples.count + 1
    samples.temperature = samples.temperature + temperature
    samples.rain = samples.rain + (raining and 1 or 0)
    -- right after loading the current weather stands for the last days
    if self.temperature == nil then
        self.temperature = temperature
        self.wetness = raining and 0.5 or FHWeather.TUNING.normalWetness
    end
end

-- One sample per in-game hour.
function FHWeather:update()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local dayTime = environment ~= nil and tonumber(environment.dayTime) or nil
    if dayTime == nil then
        return
    end
    local hour = math.floor(dayTime / 3600000)
    if hour ~= self.lastHour then
        self.lastHour = hour
        self:sample()
    end
end

-- The day ends: its weather becomes the weather of the last days.
function FHWeather:closeDay()
    if self.samples.count == 0 then
        self:sample()
    end
    local samples = self.samples
    if samples.count > 0 then
        local memory = FHWeather.TUNING.wetnessMemory
        self.temperature = samples.temperature / samples.count
        self.wetness = (1 - memory) * self.wetness + memory * samples.rain / samples.count
    end
    self:clearSamples()
end

-- 0 outside {min, low, high, max}, 1 between low and high.
local function rangeScore(value, range)
    local min, low, high, max = range[1], range[2], range[3], range[4]
    if value <= min or value >= max then
        return 0
    elseif value < low then
        return (value - min) / (low - min)
    elseif value > high then
        return (max - value) / (max - high)
    end
    return 1
end

-- How much the weather of the last days helps the threat (1 = average).
function FHWeather:getFactor(threat)
    local influence = FHSettings.get("weatherInfluence")
    local profile = threat.weatherProfile
    if influence <= 0 or profile == nil or self.temperature == nil then
        return 1
    end
    local tuning = FHWeather.TUNING
    local temperature = tuning.coldFactor + (tuning.optimumFactor - tuning.coldFactor) * rangeScore(self.temperature, profile.temperature)
    local wet = FHUtil.clamp(1 + profile.wet * (self.wetness - tuning.normalWetness) * tuning.wetEffect, tuning.minWetFactor, tuning.maxWetFactor)
    return FHUtil.clamp((temperature * wet) ^ influence, tuning.minFactor, tuning.maxFactor)
end

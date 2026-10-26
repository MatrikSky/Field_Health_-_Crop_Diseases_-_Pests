-- Field Health: catalogue of crop diseases and pests found in Poland, the
-- crops they attack, when they attack and the crop families used for crop
-- rotation.
FHThreats = {}

FHThreats.CATEGORIES = {"disease", "pest"}
FHThreats.MAX_SEVERITY = 3
-- Threat ids are stored in the savegame map (6 bits, 1..63). Never change the
-- id of an existing threat; a new threat gets the next free id.
FHThreats.ID_BITS = 6

-- Growth stages of a crop (FHRisk.getFieldSnapshot): emergence, leaf
-- development and tillering, stem elongation or budding, heading and
-- flowering up to ripening, ready to harvest.
FHThreats.STAGES = {"seedling", "leaves", "stem", "flowering", "ripe"}

-- Growing the same family again is a weak rotation.
local FAMILIES = {
    cereal = {"WHEAT", "WINTERWHEAT", "BARLEY", "WINTERBARLEY", "OAT", "RYE", "TRITICALE", "SPELT", "GREENRYE", "MILLET", "RICE", "RICELONGGRAIN"},
    maize = {"MAIZE", "SILAGEMAIZE", "SORGHUM"},
    brassica = {"CANOLA", "MUSTARD", "OILSEEDRADISH"},
    legume = {"SOYBEAN", "PEA", "GREENBEAN", "BEANS", "ALFALFA", "CLOVER"},
    beet = {"SUGARBEET", "BEETROOT", "SPINACH"},
    potato = {"POTATO"},
    umbellifer = {"CARROT", "PARSNIP"},
    allium = {"ONION"},
    sunflower = {"SUNFLOWER"},
    grassland = {"GRASS", "FIELDGRASS", "MEADOW"}
}

FHThreats.familyOf = {}
for family, fruits in pairs(FAMILIES) do
    for _, fruit in ipairs(fruits) do
        FHThreats.familyOf[fruit] = family
    end
end

-- The crop of this catalogue a fruit name stands for.
function FHThreats.resolveCrop(fruitName)
    return fruitName ~= nil and FHThreats.ALIASES[fruitName] or fruitName
end

function FHThreats.getFamily(fruitName)
    return FHThreats.familyOf[FHThreats.resolveCrop(fruitName)]
end

local function set(...)
    local result = {}
    for _, name in ipairs({...}) do
        result[name] = true
    end
    return result
end

-- Catch crops never get threats and help the next main crop.
FHThreats.CATCH_CROPS = set("OILSEEDRADISH")
-- Regrowing crops: growing them again is no rotation mistake.
FHThreats.PERENNIAL = set("GRASS", "FIELDGRASS", "MEADOW", "ALFALFA", "CLOVER", "GRAPE", "OLIVE", "POPLAR", "SUGARCANE")
-- Grassland is not sprayed against diseases and pests.
FHThreats.EXCLUDED = set("POPLAR", "OILSEEDRADISH", "GRASS", "FIELDGRASS", "MEADOW")
-- Meadows and fodder crops: threats only with the setting "fodderCrops".
FHThreats.FODDER = set("GRASS", "FIELDGRASS", "MEADOW", "CLOVER", "ALFALFA")
-- Threats of crops no entry below knows (e.g. new crops of a map).
FHThreats.GENERIC = {"fh_disease_grey_mould", "fh_pest_aphids"}
-- Crops of DLCs and mods under another fruit name (found by detectCrops):
-- fruit name -> crop of this catalogue.
FHThreats.ALIASES = {}
-- Field crops recognised by a part of their fruit name. Onions come with
-- the Highlands Fishing Expansion (or a mod); spring onions grow in
-- greenhouses and are no field crop.
FHThreats.DETECTED_CROPS = {
    {crop = "ONION", contains = "ONION", unless = "SPRING"}
}

--[[
    Weather profiles (FHWeather): daily mean temperature in degrees Celsius
    {none below, optimum from, optimum to, none above} and how much rain and
    leaf wetness help (1 = needs wet weather, 0 = no matter, -1 = likes it dry).
]]
FHThreats.WEATHER = {
    cold = {temperature = {-10, -2, 5, 12}, wet = 0.5},
    cool = {temperature = {0, 6, 15, 22}, wet = 0.4},
    mild = {temperature = {4, 12, 22, 28}, wet = -0.2},
    coolWet = {temperature = {4, 12, 20, 27}, wet = 1.0},
    warm = {temperature = {8, 15, 25, 32}, wet = 0.3},
    warmWet = {temperature = {10, 17, 26, 32}, wet = 1.0},
    hot = {temperature = {12, 20, 30, 36}, wet = 0.2},
    warmDry = {temperature = {8, 18, 28, 35}, wet = -0.6},
    hotDry = {temperature = {12, 22, 32, 38}, wet = -0.8},
    pestMild = {temperature = {5, 12, 22, 30}, wet = -0.2},
    pestHumid = {temperature = {6, 14, 22, 30}, wet = 0.3},
    soil = {temperature = {4, 10, 20, 28}, wet = 0.3}
}

local CEREALS = {"WHEAT", "WINTERWHEAT", "BARLEY", "WINTERBARLEY", "OAT", "RYE", "TRITICALE", "SPELT", "GREENRYE"}
local WHEATS = {"WHEAT", "WINTERWHEAT", "TRITICALE", "SPELT"}
local BARLEYS = {"BARLEY", "WINTERBARLEY"}
local MAIZES = {"MAIZE", "SILAGEMAIZE", "SORGHUM"}
local BRASSICAS = {"CANOLA", "MUSTARD"}
local BEETS = {"SUGARBEET", "BEETROOT"}
local LEGUMES = {"PEA", "BEANS", "GREENBEAN"}
local ROOTS = {"CARROT", "PARSNIP"}

local function crops(...)
    local result = {}
    for _, part in ipairs({...}) do
        for _, name in ipairs(type(part) == "table" and part or {part}) do
            result[#result + 1] = name
        end
    end
    return result
end

-- "0 0 .5 1 ..." -> list of numbers
local function numbers(text, count)
    local result = {}
    for value in text:gmatch("%S+") do
        result[#result + 1] = tonumber(value)
    end
    assert(#result == count, "expected " .. count .. " values: " .. text)
    return result
end

--[[
    prevalence    how common the threat is in Poland (1 = common; it weights
                  which threat appears and how often a crop gets one)
    months        activity from January to December (0 = none, 1 = peak)
    stages        activity in the growth stages seedling, leaves, stem,
                  flowering, ripe (0 = none, 1 = most susceptible)
    weather       weather profile (FHThreats.WEATHER)
    Traits used by the risk model (FHRisk):
    lush          likes lush growth from fast nitrogen (slurry, liquid fertilizer)
    residue       survives on crop residues (no plowing, unmulched stubble help it)
    soilborne     lives in the soil (acidic soil helps; manure and catch crops reduce it)
    soilPest      pest living in the soil (plowing and catch crops reduce it)
    weedHost      pest that multiplies on weeds
    stalkPest     pest overwintering in stalks and stubble
    after         extra risk factor when the previous crop belonged to a family
]]
FHThreats.LIST = {
    -- diseases (fungicide)
    {id = 1, name = "cereal_mildew", category = "disease", crops = crops(CEREALS), prevalence = 1.4,
        months = "0 0 .2 .6 1 .8 .2 0 .2 .4 .2 0", stages = "0 1 1 .5 0", weather = "mild",
        lush = true, color = {0.93, 0.93, 0.90}},
    {id = 2, name = "septoria", category = "disease", crops = crops(WHEATS), prevalence = 1.4,
        months = "0 0 .2 .5 1 1 .4 0 0 .3 .3 0", stages = "0 .6 1 1 0", weather = "coolWet",
        residue = true, color = {0.80, 0.62, 0.20}},
    {id = 3, name = "brown_rust", category = "disease", crops = crops(WHEATS, "RYE", "GREENRYE"), prevalence = 1.0,
        months = "0 0 0 .2 .6 1 .7 0 0 .3 .1 0", stages = "0 .3 .6 1 .3", weather = "warm",
        lush = true, color = {0.72, 0.33, 0.10}},
    {id = 4, name = "fusarium", category = "disease", crops = crops(CEREALS, "MILLET", MAIZES), prevalence = 0.9,
        months = "0 0 0 0 0 1 1 .7 .5 0 0 0", stages = "0 0 0 1 .6", weather = "warmWet",
        residue = true, after = {maize = 2.0}, color = {0.95, 0.45, 0.70}},
    {id = 5, name = "net_blotch", category = "disease", crops = crops(BARLEYS), prevalence = 1.1,
        months = "0 0 .2 .7 1 .7 0 0 0 .4 .2 0", stages = "0 1 1 .5 0", weather = "coolWet",
        residue = true, color = {0.48, 0.30, 0.72}},
    {id = 6, name = "snow_mould", category = "disease", crops = crops("WHEAT", "WINTERWHEAT", "WINTERBARLEY", "BARLEY", "RYE", "TRITICALE", "GREENRYE"),
        prevalence = 0.3, months = ".5 .8 1 .4 0 0 0 0 0 0 .2 .3", stages = "1 1 0 0 0", weather = "cold",
        lush = true, color = {0.55, 0.80, 0.95}},
    {id = 7, name = "sclerotinia", category = "disease", crops = crops(BRASSICAS, "SUNFLOWER", "SOYBEAN", LEGUMES, "POTATO", "CARROT"),
        prevalence = 1.0, months = "0 0 0 0 .8 1 .6 .5 .2 0 0 0", stages = "0 0 .3 1 .4", weather = "warmWet",
        soilborne = true, after = {brassica = 1.5, sunflower = 1.5, legume = 1.3}, color = {0.35, 0.35, 0.38}},
    {id = 8, name = "alternaria", category = "disease", crops = crops("POTATO", ROOTS, BRASSICAS, "SUNFLOWER", "ONION"), prevalence = 0.8,
        months = "0 0 0 0 0 .6 1 1 .6 0 0 0", stages = "0 0 .4 1 1", weather = "warm",
        residue = true, color = {0.15, 0.55, 0.55}},
    {id = 9, name = "late_blight", category = "disease", crops = crops("POTATO"), prevalence = 1.5,
        months = "0 0 0 0 .2 .8 1 .8 .3 0 0 0", stages = "0 .3 .7 1 .6", weather = "warmWet",
        color = {0.12, 0.35, 0.78}},
    {id = 10, name = "cercospora", category = "disease", crops = crops(BEETS, "SPINACH"), prevalence = 1.2,
        months = "0 0 0 0 0 .3 1 1 .6 .2 0 0", stages = "0 .3 1 1 .5", weather = "warmWet",
        residue = true, color = {0.86, 0.20, 0.20}},
    {id = 11, name = "grey_mould", category = "disease", crops = crops("GRAPE", "SUNFLOWER", LEGUMES, "SPINACH", "BUCKWHEAT", "ONION"),
        prevalence = 0.5, months = "0 0 0 0 .3 .7 1 1 .7 .3 0 0", stages = "0 0 .3 1 1", weather = "coolWet",
        lush = true, color = {0.68, 0.68, 0.62}},
    {id = 18, name = "yellow_rust", category = "disease", crops = crops(WHEATS), prevalence = 0.9,
        months = "0 0 .3 .8 1 .6 0 0 0 .2 .1 0", stages = "0 .7 1 .7 0", weather = "cool",
        lush = true, color = {1.00, 0.85, 0.15}},
    {id = 19, name = "tan_spot", category = "disease", crops = crops(WHEATS), prevalence = 0.9,
        months = "0 0 0 .3 .8 1 .5 0 0 0 0 0", stages = "0 .3 .8 1 0", weather = "warmWet",
        residue = true, color = {0.55, 0.40, 0.25}},
    {id = 20, name = "eyespot", category = "disease", crops = crops(WHEATS, "WINTERBARLEY", "BARLEY", "RYE"), prevalence = 0.9,
        months = "0 .3 .7 1 .6 0 0 0 0 .4 .5 .2", stages = "0 1 .8 0 0", weather = "cool",
        residue = true, color = {0.40, 0.75, 0.40}},
    {id = 21, name = "rhynchosporium", category = "disease", crops = crops(BARLEYS, "RYE", "TRITICALE", "GREENRYE"), prevalence = 1.1,
        months = "0 0 .3 1 1 .5 0 0 0 .5 .4 .1", stages = "0 1 1 .4 0", weather = "coolWet",
        residue = true, color = {0.70, 0.55, 0.85}},
    {id = 22, name = "ramularia", category = "disease", crops = crops(BARLEYS), prevalence = 0.6,
        months = "0 0 0 0 .3 1 .8 0 0 0 0 0", stages = "0 0 .3 1 .5", weather = "coolWet",
        color = {0.60, 0.15, 0.35}},
    {id = 23, name = "stem_rust", category = "disease", crops = crops(WHEATS, "RYE", "BARLEY", "OAT"), prevalence = 0.25,
        months = "0 0 0 0 0 .6 1 .6 0 0 0 0", stages = "0 0 0 1 .6", weather = "hot",
        color = {0.45, 0.20, 0.05}},
    {id = 24, name = "phoma", category = "disease", crops = crops(BRASSICAS), prevalence = 1.1,
        months = "0 0 .4 .5 .2 0 0 0 .7 1 .6 .2", stages = ".8 1 .6 0 0", weather = "coolWet",
        residue = true, after = {brassica = 1.6}, color = {0.20, 0.20, 0.55}},
    {id = 25, name = "cylindrosporiosis", category = "disease", crops = crops(BRASSICAS), prevalence = 0.5,
        months = "0 .2 1 .8 .3 0 0 0 0 .6 .8 .4", stages = "0 1 .7 0 0", weather = "cool",
        residue = true, after = {brassica = 1.3}, color = {0.50, 0.85, 0.75}},
    {id = 26, name = "beet_mildew", category = "disease", crops = crops(BEETS), prevalence = 0.9,
        months = "0 0 0 0 0 .2 .8 1 .6 0 0 0", stages = "0 0 .8 1 .6", weather = "warmDry",
        lush = true, color = {0.95, 0.95, 0.60}},
    {id = 27, name = "ascochyta", category = "disease", crops = crops(LEGUMES), prevalence = 0.8,
        months = "0 0 0 0 .6 1 .7 .2 0 0 0 0", stages = "0 .5 .8 1 .4", weather = "coolWet",
        residue = true, after = {legume = 1.5}, color = {0.75, 0.45, 0.30}},
    {id = 28, name = "downy_mildew", category = "disease", crops = crops("ONION", "SPINACH", "PEA"), prevalence = 1.0,
        months = "0 0 0 .2 .5 1 1 .6 .2 0 0 0", stages = "0 .8 1 1 .3", weather = "coolWet",
        lush = true, color = {0.55, 0.60, 0.85}},
    {id = 29, name = "corn_leaf_blight", category = "disease", crops = crops(MAIZES), prevalence = 0.6,
        months = "0 0 0 0 0 .2 .8 1 .6 0 0 0", stages = "0 0 .6 1 .6", weather = "warmWet",
        residue = true, after = {maize = 1.5}, color = {0.85, 0.65, 0.40}},
    {id = 30, name = "crown_rust", category = "disease", crops = crops("OAT"), prevalence = 0.6,
        months = "0 0 0 0 .2 .8 1 .4 0 0 0 0", stages = "0 0 .6 1 .3", weather = "warm",
        lush = true, color = {1.00, 0.55, 0.20}},
    -- pests (insecticide)
    {id = 12, name = "aphids", category = "pest", prevalence = 1.5,
        crops = crops(CEREALS, "MILLET", MAIZES, "POTATO", BEETS, "SPINACH", LEGUMES, "SOYBEAN", BRASSICAS, ROOTS, "SUNFLOWER",
            "BUCKWHEAT", "CLOVER", "ALFALFA", "COTTON"),
        months = "0 0 0 .4 .9 1 .7 .3 .4 .6 .2 0", stages = ".7 1 1 .6 0", weather = "warmDry",
        lush = true, weedHost = true, color = {0.45, 0.85, 0.25}},
    {id = 13, name = "leaf_beetle", category = "pest", crops = crops(CEREALS, "MILLET"), prevalence = 1.3,
        months = "0 0 0 .3 1 1 .3 0 0 0 0 0", stages = "0 .5 1 .8 0", weather = "warmDry",
        weedHost = true, color = {0.20, 0.45, 0.92}},
    {id = 14, name = "pollen_beetle", category = "pest", crops = crops(BRASSICAS), prevalence = 1.5,
        months = "0 0 .3 1 .8 .2 0 0 0 0 0 0", stages = "0 .2 1 .4 0", weather = "pestMild",
        weedHost = true, color = {1.00, 0.86, 0.10}},
    {id = 15, name = "potato_beetle", category = "pest", crops = crops("POTATO"), prevalence = 1.5,
        months = "0 0 0 0 .4 1 1 .6 .2 0 0 0", stages = "0 .7 1 1 .3", weather = "warmDry",
        after = {potato = 1.5}, color = {0.96, 0.55, 0.10}},
    {id = 16, name = "corn_borer", category = "pest", crops = crops(MAIZES, "MILLET"), prevalence = 0.9,
        months = "0 0 0 0 0 .5 1 .6 .2 0 0 0", stages = "0 0 .6 1 .3", weather = "warmDry",
        stalkPest = true, after = {maize = 1.5}, color = {0.72, 0.30, 0.78}},
    {id = 17, name = "wireworm", category = "pest", crops = crops("POTATO", "MAIZE", "SILAGEMAIZE", BEETS, ROOTS, "ONION"), prevalence = 0.7,
        months = "0 0 0 .8 1 .6 .3 .3 .3 0 0 0", stages = "1 .8 .3 .3 .3", weather = "soil",
        soilPest = true, after = {grassland = 2.5, legume = 1.3}, color = {0.82, 0.15, 0.15}},
    {id = 31, name = "stem_weevil", category = "pest", crops = crops(BRASSICAS), prevalence = 1.3,
        months = "0 .2 1 .8 .2 0 0 0 0 0 0 0", stages = "0 1 1 0 0", weather = "pestMild",
        after = {brassica = 1.2}, color = {0.35, 0.25, 0.15}},
    {id = 32, name = "seed_weevil", category = "pest", crops = crops(BRASSICAS), prevalence = 1.1,
        months = "0 0 0 .3 1 .5 0 0 0 0 0 0", stages = "0 0 .3 1 .3", weather = "pestMild",
        weedHost = true, color = {0.65, 0.50, 0.30}},
    {id = 33, name = "flea_beetle", category = "pest", crops = crops(BRASSICAS, BEETS, "SPINACH"), prevalence = 1.2,
        months = "0 0 0 .5 .9 .4 0 .3 1 .6 0 0", stages = "1 .8 .2 0 0", weather = "warmDry",
        weedHost = true, after = {brassica = 1.2}, color = {0.25, 0.25, 0.30}},
    {id = 34, name = "turnip_sawfly", category = "pest", crops = crops(BRASSICAS), prevalence = 0.5,
        months = "0 0 0 0 0 0 0 .3 1 .6 0 0", stages = ".8 1 0 0 0", weather = "pestMild",
        weedHost = true, color = {0.95, 0.70, 0.80}},
    {id = 35, name = "frit_fly", category = "pest", crops = crops("OAT", "WHEAT", "WINTERWHEAT", BARLEYS, "RYE", "TRITICALE", "MAIZE", "SILAGEMAIZE", "MILLET"),
        prevalence = 0.6, months = "0 0 0 .3 .8 1 .3 0 .5 .4 0 0", stages = "1 1 .3 0 0", weather = "pestMild",
        weedHost = true, after = {grassland = 1.5}, color = {0.55, 0.75, 0.95}},
    {id = 36, name = "wheat_midge", category = "pest", crops = crops(WHEATS, "RYE"), prevalence = 0.5,
        months = "0 0 0 0 .3 1 .4 0 0 0 0 0", stages = "0 0 .2 1 0", weather = "pestHumid",
        after = {cereal = 1.3}, color = {0.95, 0.40, 0.55}},
    {id = 37, name = "cutworm", category = "pest", crops = crops(BEETS, "POTATO", "MAIZE", "SILAGEMAIZE", ROOTS, "ONION", "SUNFLOWER"),
        prevalence = 0.5, months = "0 0 0 0 .3 .6 1 1 .5 0 0 0", stages = ".6 1 .8 .4 .2", weather = "hotDry",
        soilPest = true, weedHost = true, color = {0.55, 0.45, 0.35}},
    {id = 38, name = "beet_fly", category = "pest", crops = crops(BEETS, "SPINACH"), prevalence = 0.7,
        months = "0 0 0 .3 1 .8 .4 0 0 0 0 0", stages = ".6 1 .6 0 0", weather = "pestHumid",
        weedHost = true, color = {0.30, 0.65, 0.60}},
    {id = 39, name = "onion_fly", category = "pest", crops = crops("ONION"), prevalence = 1.2,
        months = "0 0 0 .3 1 .6 .5 .6 .3 0 0 0", stages = "1 1 .5 .2 0", weather = "pestHumid",
        soilPest = true, after = {allium = 1.5}, color = {0.80, 0.80, 0.80}},
    {id = 40, name = "thrips", category = "pest", crops = crops("ONION", LEGUMES), prevalence = 0.9,
        months = "0 0 0 0 .3 .7 1 1 .4 0 0 0", stages = "0 .5 1 1 .4", weather = "hotDry",
        weedHost = true, color = {0.90, 0.95, 0.40}},
    {id = 41, name = "carrot_fly", category = "pest", crops = crops(ROOTS), prevalence = 1.0,
        months = "0 0 0 0 .8 .7 .4 1 .6 .2 0 0", stages = ".6 1 1 .6 .2", weather = "pestHumid",
        soilPest = true, after = {umbellifer = 1.5}, color = {1.00, 0.60, 0.40}},
    {id = 42, name = "pea_leaf_weevil", category = "pest", crops = crops(LEGUMES, "SOYBEAN"), prevalence = 0.8,
        months = "0 0 0 .6 1 .5 0 0 0 0 0 0", stages = "1 1 .4 0 0", weather = "pestMild",
        after = {legume = 1.4}, color = {0.45, 0.55, 0.20}},
    {id = 43, name = "rootworm", category = "pest", crops = crops("MAIZE", "SILAGEMAIZE"), prevalence = 0.2,
        months = "0 0 0 0 0 .4 1 1 .3 0 0 0", stages = "0 0 .6 1 .4", weather = "warmDry",
        soilPest = true, after = {maize = 3.0}, color = {0.15, 0.60, 0.35}},
    {id = 44, name = "ground_beetle", category = "pest", crops = crops("WHEAT", "WINTERWHEAT", BARLEYS, "RYE", "TRITICALE"), prevalence = 0.2,
        months = "0 0 0 .6 .4 0 0 0 .6 1 .5 0", stages = "1 1 0 0 0", weather = "pestMild",
        soilPest = true, after = {cereal = 1.5}, color = {0.10, 0.30, 0.55}}
}

local byKey, byId, knownCrops = {}, {}, {}
for _, threat in ipairs(FHThreats.LIST) do
    -- the key doubles as the text key of the threat's name
    threat.key = string.format("fh_%s_%s", threat.category, threat.name)
    threat.cropSet = set(unpack(threat.crops))
    threat.monthWeights = numbers(threat.months, 12)
    local stageValues = numbers(threat.stages, #FHThreats.STAGES)
    threat.stageWeights = {}
    for i, stage in ipairs(FHThreats.STAGES) do
        threat.stageWeights[stage] = stageValues[i]
    end
    -- months of full activity in a year, for the infection pressure
    threat.exposure = 0
    for _, weight in ipairs(threat.monthWeights) do
        threat.exposure = threat.exposure + weight
    end
    threat.weatherProfile = FHThreats.WEATHER[threat.weather]
    assert(threat.weatherProfile ~= nil and threat.exposure > 0 and byId[threat.id] == nil and threat.id < 2 ^ FHThreats.ID_BITS,
        "bad threat definition: " .. threat.key)
    threat.color[4] = 1
    for _, crop in ipairs(threat.crops) do
        knownCrops[crop] = true
    end
    byKey[threat.key] = threat
    byId[threat.id] = threat
end

function FHThreats.get(key)
    return key ~= nil and byKey[key] or nil
end

function FHThreats.getById(id)
    return byId[tonumber(id) or 0]
end

-- Name for places with little room (HUD, map legend).
function FHThreats.shortName(threat)
    return FHUtil.text(threat.key .. "_short", FHUtil.text(threat.key))
end

function FHThreats.ofCategory(category)
    local result = {}
    for _, threat in ipairs(FHThreats.LIST) do
        if threat.category == category then
            result[#result + 1] = threat
        end
    end
    return result
end

function FHThreats.isCatchCrop(fruitName, desc)
    return (desc ~= nil and desc.isCatchCrop == true) or (fruitName ~= nil and FHThreats.CATCH_CROPS[fruitName] == true)
end

-- Recognises crops of DLCs and mods (FHThreats.DETECTED_CROPS) among the
-- fruit types of the game. Returns {fruit name = crop} of the crops found.
function FHThreats.detectCrops(fruitTypes)
    local found = {}
    for _, desc in pairs(fruitTypes or {}) do
        local name = type(desc) == "table" and desc.name or nil
        if type(name) == "string" then
            local upper = name:upper()
            for _, rule in ipairs(FHThreats.DETECTED_CROPS) do
                if upper:find(rule.contains, 1, true) and (rule.unless == nil or not upper:find(rule.unless, 1, true)) then
                    if name ~= rule.crop then
                        FHThreats.ALIASES[name] = rule.crop
                    end
                    found[name] = rule.crop
                end
            end
        end
    end
    return found
end

-- Threats (of a category, or all) that can attack the crop at some time.
function FHThreats.forCrop(fruitName, category)
    fruitName = FHThreats.resolveCrop(fruitName)
    local result = {}
    if fruitName == nil or FHThreats.EXCLUDED[fruitName] then
        return result
    end
    if FHThreats.FODDER[fruitName] and FHSettings ~= nil and not FHSettings.isOn("fodderCrops") then
        return result
    end

    if knownCrops[fruitName] then
        for _, threat in ipairs(FHThreats.LIST) do
            if threat.cropSet[fruitName] and (category == nil or threat.category == category) then
                result[#result + 1] = threat
            end
        end
    else
        for _, key in ipairs(FHThreats.GENERIC) do
            local threat = byKey[key]
            if category == nil or threat.category == category then
                result[#result + 1] = threat
            end
        end
    end
    return result
end

function FHThreats.attacks(threat, fruitName)
    for _, candidate in ipairs(FHThreats.forCrop(fruitName, threat.category)) do
        if candidate == threat then
            return true
        end
    end
    return false
end

-- How active the threat is in a growth stage and month (0 = not at all,
-- 1 = its most dangerous time).
function FHThreats.getTiming(threat, stage, month)
    if stage == nil or month == nil then
        return 0
    end
    return (threat.stageWeights[stage] or 0) * (threat.monthWeights[month] or 0)
end

-- Field Health: the in-game help (ESC > Help). The page icons come from an
-- own texture atlas. The tables are images with text, made in Polish and in
-- English: the help pages in modDesc name the Polish ones, and players with
-- another language get the English ones.
FHHelp = {}

FHHelp.ICON_CONFIG = "help/fieldHealthHelpIcons.xml"
FHHelp.ICON_PREFIX = "fieldHealthHelp"
-- file names of the table images: help/fieldHealthHelp_<table>_<language>.png
FHHelp.IMAGE_PATTERN = "(fieldHealthHelp_%w+_)pl(%.%a+)$"
FHHelp.MAX_DEPTH = 8

function FHHelp.registerIcons()
    if g_overlayManager ~= nil and g_overlayManager.addTextureConfigFile ~= nil then
        g_overlayManager:addTextureConfigFile(Utils.getFilename(FHHelp.ICON_CONFIG, FHUtil.MOD_DIRECTORY), FHHelp.ICON_PREFIX)
    end
end

-- Language of the table images: the game reads the l10n file of its
-- language (English for languages the mod has no texts for).
function FHHelp.getImageLanguage()
    return FHUtil.text("fh_help_tableLanguage") == "pl" and "pl" or "en"
end

-- Points the table images of the loaded help pages to the player's
-- language: every string naming one of them is changed. Returns how many.
function FHHelp.localizeImages(root)
    local language = FHHelp.getImageLanguage()
    if language == "pl" or type(root) ~= "table" then
        return 0
    end
    local count, visited = 0, {}
    local function walk(node, depth)
        if visited[node] or depth > FHHelp.MAX_DEPTH then
            return
        end
        visited[node] = true
        for key, value in pairs(node) do
            if type(value) == "string" then
                local changed, found = value:gsub(FHHelp.IMAGE_PATTERN, "%1" .. language .. "%2")
                if found > 0 then
                    node[key] = changed
                    count = count + 1
                end
            elseif type(value) == "table" then
                walk(value, depth + 1)
            end
        end
    end
    walk(root, 0)
    return count
end

-- After the help pages of the mods are loaded (once per game session).
function FHHelp.onGameStarted()
    local manager = g_helpLineManager
    local count = FHHelp.localizeImages(manager ~= nil and (manager.categories or manager) or nil)
    if count > 0 then
        FHUtil.trace("help: %d table images in language %s", count, FHHelp.getImageLanguage())
    end
end

FHUtil.protect("help icons", FHHelp.registerIcons)

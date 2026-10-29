# Changelog

All notable changes of **Field Health: Crop Diseases & Pests** are listed here, the newest first.

## Version numbers

Versions have four numbers, **A.B.C.D**:

| Number | Name | Raised when |
|---|---|---|
| **A** | Generation | the whole mod changes in a big way: a new simulation, a rework of how the mod is played, a port to a new game |
| **B** | Features | there is something new for players: threats, crops, products, settings, map or HUD features, a language, support for a DLC or another mod |
| **C** | Fixes | bugs are fixed or numbers are balanced: texts and help, compatibility with maps and mods, performance, models and textures |
| **D** | Hotfix | an urgent problem right after a release is fixed (an error, a missing file) and nothing else changes |

Raising a number sets the numbers after it to 0: 1.2.3.4 → 1.3.0.0. When a version brings several kinds of changes, the highest one counts.
**Every version loads the savegames of all earlier versions**, so nothing you own or set in the game is lost by an update.

## [1.2.1.0] - 2026-10-29

### Changed

- Bottles and canisters have simpler collisions with a flat bottom and straight sides: 24 points instead of 96. They are lighter for the physics and stand straight on concrete instead of leaning.
- Realistic weight of the full bottles and canisters: 1.1 kg for the 1 l bottle, 5.4 kg for the 5 l canister and 21.2 kg for the 20 l canister.

### Fixed

- A thrown bottle can now fall over, and a canister lying on its side stays there instead of standing up again by itself. The centre of mass was too low and every turn was slowed down.

## [1.2.0.0] - 2026-10-29

### Added

- Ukrainian, Turkish, Dutch, Danish, Swedish, Norwegian and Finnish. The mod now speaks 20 languages, and every one of them has the full in-game help.
- The tables of the in-game help in German, French and Russian. Other languages still show the English tables.

### Changed

- The daily check of infected fields is much lighter: the mod works out the cells of a field once instead of every time. On maps with big fields this removes short stutters at midnight.
- Multiplayer data goes out in smaller pieces, and a player who asks for the full state again gets it at most every 10 seconds.
- The XML files of the bottles and canisters point to the GIANTS schema, so XML editors can check them.

### Fixed

- The spray of fungicide and insecticide is now visible on every sprayer. Before, most sprayers from mods and some base game sprayers treated the field without showing any spray.
- Multiplayer: a player who joined while someone was spraying could see an incomplete map (protection or threats missing) until those spots changed again.
- If the data of the mod in a savegame cannot be read, or was saved by a newer version of the mod, the mod stays off for that session and leaves the data as it is instead of overwriting it.
- A savegame file edited by hand no longer stops loading at its first broken entry. The readable entries are kept.
- An error that repeats is written to the log three times at most instead of every frame.
- Right after loading, an AI sprayer with fungicide or insecticide no longer treats fields the mod has not checked yet as done.
- English help: the part about the field info box uses the same names as the box ("Disease protection", "Pest protection", "severe").
- Long words in the help tables are broken properly and no longer run into the next column.

## [1.1.0.0] - 2026-10-27

### Added

- Translations into French, German, Spanish (Spain and Latin America), Portuguese (Portugal and Brazil), Italian, Russian, Czech, Romanian and Hungarian: field info, map, minimap, notifications, settings with their descriptions, shop items and all pages of the in-game help. In these languages the tables of the help are still in English.

### Fixed

- The Polish description of the setting "Influence of weather" now uses the same option names as the setting itself.

## [1.0.0.0] - 2026-10-27

The first public release.

### Added

- 44 crop threats: 24 diseases fought with fungicide and 20 pests fought with insecticide, each with its own crops, months, growth stages and weather.
- An infection pressure that depends on how you farm (rotation, plowing, liming, mulching, fertilizing, weed control) and on the weather of the last days.
- Outbreaks as irregular patches that grow, spread downwind and can move to a touching player field; crop damage only in the high stage.
- Fungicide and insecticide in 1 l bottles and 5 l and 20 l canisters of two brands, Opryskex and MST; one spray cures and protects a field until harvest.
- A map page "Crop protection" with five layers, a minimap layer (Left Alt + \\), field info lines, farmland info and notifications.
- 25 settings in the game menu, Precision Farming support, onions of the Highlands Fishing DLC, full in-game help, English and Polish, multiplayer.

[1.2.1.0]: https://github.com/MatrikSky/Field_Health_-_Crop_Diseases_-_Pests/releases/tag/v1.2.1.0
[1.2.0.0]: https://github.com/MatrikSky/Field_Health_-_Crop_Diseases_-_Pests/releases/tag/v1.2.0.0
[1.1.0.0]: https://github.com/MatrikSky/Field_Health_-_Crop_Diseases_-_Pests/releases/tag/v1.1.0.0
[1.0.0.0]: https://github.com/MatrikSky/Field_Health_-_Crop_Diseases_-_Pests/releases/tag/v1.0.0.0

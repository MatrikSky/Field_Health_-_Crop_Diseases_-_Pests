## What does this pull request change?

<!-- A short description of the change. -->

## Why?

<!-- The problem it solves or the idea behind it. Link the issue, e.g. "Fixes #12". -->

## How was it tested?

- [ ] Tested in single player
- [ ] Tested in multiplayer (needed if the change touches the simulation, saving or the network)
- [ ] `log.txt` shows no errors from Field Health
- [ ] An existing savegame still loads with all fields, threats, protection and settings

## Savegame compatibility

Players have savegames of every released version – please check:

- [ ] No shop item file in `pallets/` was renamed or removed
- [ ] `FUNGICIDE` and `INSECTICIDE` keep their names
- [ ] No threat id or key changed (new threats use the next free id)
- [ ] No setting and no setting value was removed
- [ ] New brand configurations were added at the end
- [ ] Saved values and the savegame files `fieldHealth.xml` and `fieldHealthMap.grle` keep their names
- [ ] If the savegame format changed: the format version is higher and old data is converted when loaded

## Texts

- [ ] New or changed texts are in every file of `l10n/` (all 20 languages; say in the pull request if you cannot translate one), with the prefix `fh_`

## Screenshots (optional)

<!-- For changes you can see in the game: map, HUD, models, menus. -->

---

By opening this pull request you agree that your contribution is published under the [CC BY 4.0 licence](https://github.com/MatrikSky/Field_Health_-_Crop_Diseases_-_Pests/blob/main/LICENSE) of the project.

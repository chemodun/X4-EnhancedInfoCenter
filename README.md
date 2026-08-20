# Enhanced Info Center

A wide, tabbed property panel on the map's left sidebar. Your stations, fleets and ships in the vanilla Property Owned style, each tab showing its own set of columns.

It is written from scratch, inspired by the original `Info Center` by [Forleyor](https://www.nexusmods.com/profile/Forleyor?gameId=2659).

## Features

- **A wide panel instead of a narrow column** - the list opens over the map at a width you choose, from a quarter of the screen up to everything left of the map's information panel, so the columns have the room the vanilla list never has.
- **Seventeen tabs, one column layout each** - a tab is a fixed set of columns, so there are no column checkboxes and no horizontal squeeze: pick the tab that answers the question you have.
- **Six tab groups** - everything you own, stations alone, fleets alone, unassigned ships, a flat list of every ship with its own filter tabs, and deployables.
- **The vanilla Property Owned behaviour, kept** - fleets, subordinate groups and docked ships expand and collapse, rows carry the alert marker, the hull bar and the faction colours, and picking a row selects the object on the map exactly as the vanilla list does.
- **Expand all and collapse all** - the sorter row carries a whole-list version of a row's own `+` / `-`, and an option says whether it acts on the top level rows alone or on every node below them.
- **Sortable columns** - the sorter row sorts by name, sector, order, hull, skill, crew skill or cargo, and the `Cargo` button walks total capacity and used capacity.
- **A right bar options panel** - ship sizes, ship roles, deployable types, display options, alternating row colour and panel width, in the map's own right sidebar, so the map and the list stay visible while you change them.
- **Deployables at last** - satellites, mines, navigation beacons, resource probes, laser towers and lockboxes get a tab of their own, with identical names collapsed into one countable row.
- **Follows your UI settings** - the panel takes its row height and font size from the `UI Extensions and HUD` map settings, like every other panel that mod governs.

## Requirements

- `X4: Foundations` 8.00 and 9.00.
- [UI Extensions and HUD](https://www.nexusmods.com/x4foundations/mods/518) by [kuertee](https://www.nexusmods.com/profile/kuertee?gameId=2659), which provides the map menu hooks the panel is built on.
- [Mod Support APIs](https://www.nexusmods.com/x4foundations/mods/503) by [SirNukes](https://www.nexusmods.com/profile/sirnukes?gameId=2659) to be installed and enabled. Version `1.95` and upper is required.
- [Options Helper](https://www.nexusmods.com/x4foundations/mods/2089), to provide the in-game Debug Level option. Version `1.10` and upper is required.
- [Print Extension List](https://www.nexusmods.com/x4foundations/mods/2191), to record the game version and the enabled extensions in the log. Version `1.00` and upper is required.

## Notes and limitations

- **The panel width is capped by the map's information panel.** The slider is a share of the screen, but the panel stops at the left edge of the right hand information panel, so on a narrow screen - or with a wide information panel - it stops there instead of running under it.
- **The opening tab applies from the next load.** The tab strip owns the current tab once the map is open, exactly as the vanilla list owns its own mode, so the `Opening tab` option seeds it per game load and changing it shows no immediate effect.
- **Orders of ships that are not yours stay blank.** A foreign ship docked at your station is listed, but its order and activity are not shown - the same rule the vanilla list follows.
- **The trade tabs show the current trade, not a history.** The ware column names the first trade at or after the current point in the order queue, so a finished trade is never reported as an ongoing one.

## Installation

- **Nexus Mods**: [Enhanced Info Center](https://www.nexusmods.com/x4foundations/mods/1970)

## Usage

Open the map and pick **Info Center** from the left sidebar - the entry sits right below **Object List** on 9.00, and below **Property Owned** on 8.00.

The panel has a title, one or two rows of tab icons and the list itself. Click a tab to switch the list; the map's own next tab and previous tab input, keyboard or gamepad, steps through them as well.

### The tabs

- **Overview**, **Crew** and **Trade & Cargo** - everything you own, in three column layouts: stations, fleets and unassigned ships, each section expandable down to the docked ships.
- **Stations: Overview**, **Stations: Crew**, **Stations: Trade & Cargo** - the same three layouts over your stations alone.
- **Fleets: Overview**, **Fleets: Crew**, **Fleets: Trade & Cargo** - the same three over your fleets alone.
- **Unassigned Ships** - every ship that answers to no commander, with its own docked ships under it.
- **Ships: Overview**, **Ships: Crew**, **Ships: Trade & Cargo** - one flat list of every ship you own, no sections and nothing to expand; the fastest way to sort the whole fleet by a single column.
- **Damaged**, **Wait for Signal**, **Failed Orders** - that same flat list under a filter: hull below full, an order waiting on the proceed signal, and an order that has failed, the last one showing what failed and the message it failed with.
- **Deployables** - satellites, mines, navigation beacons, resource probes, laser towers and lockboxes. Objects that share a name are collapsed into one row carrying that name and, in the hull column, how many there are; expand it to see them individually.

The columns follow the tab: **Overview** shows the current order, the current activity and the hull bar, **Crew** replaces the hull with the manager or pilot skill and the combined crew skill, and **Trade & Cargo** replaces both with the cargo hold, the ware being traded and, on a station row, its account. A station or a fleet row has no order of its own, so it fills those columns with the icons of the ships under it instead.

### Sorting and expanding

- Click a column header on the sorter row to sort by it, and again to reverse the order. `Cargo` carries two figures, so its button walks total capacity, then used capacity.
- The `+` and `-` button on the left of a row opens and closes a fleet, a subordinate group or a block of docked ships.
- The same button on the sorter row does it for the whole list at once. It shows `-` only when everything in scope is already open, and the **Expand/collapse scope** option decides whether that scope is the top level rows or every node below them.

### Selecting on the map

Row interaction is the vanilla one, deliberately: a click makes the row current and selects that object on the map, ctrl click and shift click add to and extend the selection, a double click focuses the map on the object - or, on a subordinate group row, on the whole group - and a right click opens the interact menu for it. While the map is asking you to pick a target - a ship to hire from, a builder, a position - the panel answers with the same picker frame the vanilla list does.

### Panel options

Pick **Info Center Options** from the map's right sidebar. The options apply immediately and are stored per player, not per savegame.

- **Ship Size** - `XL`, `L`, `M`, `S` and `Spacesuit`, filtering every list by hull size.
- **Ship Roles** - `Fight`, `Trade`, `Mine`, `Build`, `Auxiliary`, `Salvage`, `Dismantling` and `Racing`, filtering by what a ship is fitted out for.
- **Deployables** - `Laser Towers`, `Mines`, `Navigation Beacons`, `Resource Probes`, `Satellites` and `Lockboxes`, filtering the Deployables tab.
- **Display** - `Sorter row` switches the header row off, `Expand/collapse scope` sets what the sorter row's expand button acts on, `Panel width` is the share of the screen the panel takes, and `Opening tab` is the tab each new session starts on.
- **Alternating row colour** - one flag each for `Stations`, `Fleets`, `Ships` and `Deployables`, so a long section can be striped while a short one is not.
- **Trade & Cargo** - `Hide rows with no cargo or trade` drops everything that is neither carrying nor trading from the three trade tabs.

### Extension options

**Options Menu > Extension options > Info Center**:

- **Debug Level** - `None` by default. `Debug` records what the panel does in the game log, `Trace` adds the per row detail. Needed only when reporting a problem.

## Credits

- Author: Chem O`Dun, on [Nexus Mods](https://www.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) - for the X series.
- [Forleyor](https://www.nexusmods.com/profile/Forleyor?gameId=2659) - for the original Info Center, which this panel takes its purpose from.
- [kuertee](https://www.nexusmods.com/profile/kuertee?gameId=2659) - for the UI Extensions hooks the panel plugs into.
- [SirNukes](https://www.nexusmods.com/profile/sirnukes?gameId=2659) - for the Mod Support APIs that power the UI hooks.

## Changelog

### [1.00] - 202?-??-??

- **Added**
  - Initial release.

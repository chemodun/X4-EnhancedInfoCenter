# Enhanced Info Center

A wide, tabbed property panel on the map's left sidebar. Your stations, fleets and ships in the vanilla Property Owned style, each tab showing its own set of columns.

It is written from scratch, inspired by the original `Info Center`.

## Features

- **A wide panel instead of a narrow column** - the list opens over the map at a width you choose, from a quarter of the screen up to everything left of the map's information panel, so the columns have the room the vanilla list never has.
- **Seventeen tabs, one column layout each** - a tab is a fixed set of columns, so there are no column checkboxes and no horizontal squeeze: pick the tab that answers the question you have.
- **Six tab groups** - everything you own, stations alone, fleets alone, unassigned ships, a flat list of every ship with its own filter tabs, and deployables.
- **Sortable columns** - the sorter row sorts by name, sector, order, hull, skill, crew skill or cargo, and the `Cargo` button walks total capacity and used capacity.
- **A right bar options panel** - ship sizes, ship roles, deployable types, display options, alternating row colour and panel width, in the map's own right sidebar, so the map and the list stay visible while you change them.
- **Paged by default, for speed** - the list is cut into pages that fit the panel, and only the page you are on is built, so a large property costs no more to open than a small one. Switch paging off in the options for one long scrolling list instead.

## Requirements

- `X4: Foundations` 8.00 and 9.00.
- [UI Extensions and HUD](https://www.nexusmods.com/x4foundations/mods/518) by [kuertee](https://www.nexusmods.com/profile/kuertee?gameId=2659), which provides the map menu hooks the panel is built on.
- [Mod Support APIs](https://www.nexusmods.com/x4foundations/mods/503) by [SirNukes](https://www.nexusmods.com/profile/sirnukes?gameId=2659) to be installed and enabled. Version `1.95` and upper is required.
- [Options Helper](https://www.nexusmods.com/x4foundations/mods/2089), to provide the in-game Debug Level option. Version `1.10` and upper is required.
- [Print Extension List](https://www.nexusmods.com/x4foundations/mods/2191), to record the game version and the enabled extensions in the log. Version `1.00` and upper is required.

## Installation

- **Nexus Mods**: [Enhanced Info Center](https://www.nexusmods.com/x4foundations/mods/1970)

## Usage

Open the map and pick **Info Center** from the left sidebar - the entry sits right below **Object List** on 9.00, and below **Property Owned** on 8.00.

![Info Center](docs/images/info_center.png)

The panel has a title, one. scrollable if needed, row of tab icons and the list itself. Click a tab to switch the list; the map's own next tab and previous tab input, keyboard or gamepad, steps through them as well.

### The tabs

- **Overview**, **Crew** and **Trade & Cargo** - everything you own, in three column layouts: stations, fleets and unassigned ships, each section expandable down to the docked ships.
  - ![Info Center: Overview](docs/images/info_center_overview.png)
  - ![Info Center: Crew](docs/images/info_center_crew.png)
  - ![Info Center: Trade & Cargo](docs/images/info_center_trade.png)

- **Stations: Overview**, **Stations: Crew**, **Stations: Trade & Cargo** - the same three layouts over your stations alone.
  - ![Info Center: Stations Overview](docs/images/info_center_stations_overview.png)
  - ![Info Center: Stations Crew](docs/images/info_center_stations_crew.png)
  - ![Info Center: Stations Trade & Cargo](docs/images/info_center_stations_trade.png)

- **Fleets: Overview**, **Fleets: Crew**, **Fleets: Trade & Cargo** - the same three over your fleets alone.
  - ![Info Center: Fleets Overview](docs/images/info_center_fleets_overview.png)
  - ![Info Center: Fleets Crew](docs/images/info_center_fleets_crew.png)
  - ![Info Center: Fleets Trade & Cargo](docs/images/info_center_fleets_trade.png)

- **Unassigned Ships** - every ship that answers to no commander, equal to vanilla.
  - ![Info Center: Unassigned Ships](docs/images/info_center_unassigned.png)

- **Ships: Overview**, **Ships: Crew**, **Ships: Trade & Cargo** - one flat list of every ship you own, no sections and nothing to expand; the fastest way to sort the whole fleet by a single column.
  - ![Info Center: Ships Overview](docs/images/info_center_ships_overview.png)
  - ![Info Center: Ships Crew](docs/images/info_center_ships_crew.png)
  - ![Info Center: Ships Trade & Cargo](docs/images/info_center_ships_trade.png)

- **Damaged**, **Wait for Signal**, **Failed Orders** - that same flat list under a filter: hull below full, an order waiting on the proceed signal, and an order that has failed, the last one showing what failed and the message it failed with.
  - ![Info Center: Damaged](docs/images/info_center_ships_damaged.png)
  - ![Info Center: Wait for Signal](docs/images/info_center_ships_wait.png)
  - ![Info Center: Failed Orders](docs/images/info_center_ships_failed_orders.png)

- **Deployables** - satellites, mines, navigation beacons, resource probes, laser towers and lockboxes. Objects that share a name are collapsed into one row carrying that name and, in the hull column, how many there are; expand it to see them individually.
  - ![Info Center: Deployables](docs/images/info_center_deployables.png)

The columns follow the tab: **Overview** shows the current order, the current activity and the hull bar, **Crew** replaces the hull with the manager or pilot skill and the combined crew skill, and **Trade & Cargo** replaces both with the ware being traded, on a station row its account, and the cargo hold at the row end. A station or a fleet row has no order of its own, so it fills those columns with the icons of the ships under it instead.

### Sorting and expanding

- Click a column header on the sorter row to sort by it, and again to reverse the order. `Cargo` carries two figures, so its button walks total capacity, then used capacity.
- The `+` and `-` button on the left of a row opens and closes a fleet, a subordinate group or a block of docked ships.
- The same button on the sorter row does it for the whole list at once. It shows `-` only when everything in scope is already open, and the **Expand/collapse scope** option decides whether that scope is the top level rows or every node below them.
  - ![Info Center: Expanded All](docs/images/info_center_expanded_all.png)

### Paging

- `Paging` cuts every tab's list into pages and puts the vanilla page control - first, previous, the page number, next, last - on the tab title's line, at the right end of the panel. **It is on by default, and it is the faster of the two modes**: a page is built and drawn on its own, so the panel only ever lays out a windowful of rows instead of every ship, station and deployable you own. With a large property the difference is the panel opening and refreshing at once rather than after a pause. Turn it off and the list goes back to one scrolling whole - every row built on every refresh.
- A page holds as many top level rows as the panel shows with every one of them collapsed, whether they are collapsed or not: rows you open push the rest of the page past the lower edge, where the list scrolls down to them the way it always did.
- The Deployables tab counts differently, because its top level rows are groups of a name rather than objects: it counts the rows it is showing at that moment, copies of an opened group included, and cuts the pages out of that. A group with more copies than the page has room for simply carries on over the next one.
- Each tab remembers the page it stands on, and the box between the arrows takes a page number typed straight into it. On the tabs that list the build queue, the queue follows the last page.

### Selecting on the map

Row interaction is the vanilla one, deliberately: a click makes the row current and selects that object on the map, ctrl click and shift click add to and extend the selection, a double click focuses the map on the object - or, on a subordinate group row, on the whole group - and a right click opens the interact menu for it. While the map is asking you to pick a target - a ship to hire from, a builder, a position - the panel answers with the same picker frame the vanilla list does.

### Panel options

Pick **Info Center Options** from the map's right sidebar. The options apply immediately and are stored per player, not per savegame.

![Info Center: Panel options](docs/images/info_center_options_panel.png)

- **Ship Size** - `XL`, `L`, `M`, `S` and `Spacesuit`, filtering every list by hull size.
  - ![Info Center: Ship Sizes XL and S filtered](docs/images/info_center_ship_size_filtered.png)
- **Ship Roles** - `Fight`, `Trade`, `Mine`, `Build`, `Auxiliary`, `Salvage`, `Dismantling` and `Racing`, filtering by what a ship is fitted out for.
  - ![Info Center: Ship Roles Fight filtered in addition](docs/images/info_center_ship_roles_fight_filtered_in_addition.png)
- **Deployables** - `Laser Towers`, `Mines`, `Navigation Beacons`, `Resource Probes`, `Satellites` and `Lockboxes`, filtering the Deployables tab.
- **Display** - `Paging` cuts every list into pages and is on by default, for the speed it buys on a large property, `Expand/collapse scope` sets what the sorter row's expand button acts on, `Panel width` is the share of the screen the panel takes, and `Opening tab` is the tab each new session starts on.
  - ![Info Center: Overview Paging On](docs/images/info_center_overview_paging_on.png)
  - ![Info Center: Overview Paging Off](docs/images/info_center_overview_paging_off.png)
  - ![Info Center: Expand/collapse only first level rows](docs/images/info_center_expand_collapse_only_first_level_rows.png)
  - ![Info Center: Expand/collapse all rows](docs/images/info_center_expand_collapse_all_rows.png)

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
- To the author for the original Info Center.
- [kuertee](https://www.nexusmods.com/profile/kuertee?gameId=2659) - for the UI Extensions hooks the panel plugs into.
- [SirNukes](https://www.nexusmods.com/profile/sirnukes?gameId=2659) - for the Mod Support APIs that power the UI hooks.

## Changelog

### [1.00] - 202?-??-??

- **Added**
  - Initial release.

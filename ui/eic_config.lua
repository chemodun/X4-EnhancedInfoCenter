-- Info Center - shared identity, geometry, column model and logging.
-- Requires nothing: a column paints from a row context and never reaches for the menu.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C   = ffi.C

local eic = {
  PAGE             = 1972092440,
  -- menu.infoTableMode / menu.searchTableMode values that select this mod's panels.
  MODE             = "eic",
  RIGHTMODE        = "eic_options",
  configBlackboard = "$InfoCenterConfig",
  debugLevel       = "none",
  isV9             = C.GetGameVersion().major >= 9,

  -- Registered in libraries/icons.xml, bar the unassigned tab's, which is vanilla's own.
  icons = {
    sideBar     = "eic_infocenter",
    options     = "eic_options",
    overview    = "eic_overview",
    condition   = "eic_condition",
    crew        = "eic_crew",
    trade       = "eic_trade",
    stOverview  = "eic_st_overview",
    stCrew      = "eic_st_crew",
    stTrade     = "eic_st_trade",
    flOverview  = "eic_fl_overview",
    flCrew      = "eic_fl_crew",
    flTrade     = "eic_fl_trade",
    shOverview  = "eic_sh_overview",
    shCrew      = "eic_sh_crew",
    shTrade     = "eic_sh_trade",
    ships       = "eic_ships",
    unassigned  = "mapst_ol_unassigned",
    damaged     = "eic_damaged",
    signal      = "eic_signal",
    failed      = "eic_failed",
  },

  -- A share of the view, so it neither compounds with info_panel_width nor needs a per-resolution case.
  widthPercent    = 60,
  widthPercentMin = 25,
  widthPercentMax = 90,

  -- Read by vanilla's helpers off infoTableData; our own fleet cell is uncapped.
  MAXICONS = 5,

  -- Live panel state: session-only, the way vanilla treats menu.propertyMode.
  viewMode   = "overview",
  sorterType = "name",

  -- Set by eic_panel.Init; the other modules read the map menu from here.
  menu      = nil,
  mapConfig = nil,
  rowHeight = nil,
  fontSize  = nil,
}

-- Carried over from forleyor's Info Center on first run; options that became tabs have no entry.
local LEGACY_OPTIONS = {
  infocenter_shipclassXL    = "classXL",
  infocenter_shipclassL     = "classL",
  infocenter_shipclassM     = "classM",
  infocenter_shipclassS     = "classS",
  infocenter_spacesuit      = "roleSpacesuit",

  infocenter_lasertowers    = "laserTowers",
  infocenter_mines          = "mines",
  infocenter_navbeacons     = "navBeacons",
  infocenter_resourceprobes = "resourceProbes",
  infocenter_satellites     = "satellites",
  infocenter_lockboxes      = "lockboxes",

  infocenter_fighters       = "roleFight",
  infocenter_traders        = "roleTrade",
  infocenter_miners         = "roleMine",
  infocenter_builders       = "roleBuild",
  infocenter_shipresupply   = "roleResupply",
  infocenter_shiptug        = "roleTug",
  infocenter_shiprecycling  = "roleRecycling",
  infocenter_shipracing     = "roleRacing",

  infocenter_sorterrow      = "sorterRow",
  -- One legacy flag, three flags here: the value seeds all of them.
  infocenter_altrowcolor    = { "altRowStations", "altRowFleets", "altRowShips" },
}

-- EIC_Options holds only what the player changed; everything else answers from here.
local OPTION_DEFAULTS = {
  classXL        = true,
  classL         = true,
  classM         = true,
  classS         = true,
  roleSpacesuit  = true,

  laserTowers    = true,
  mines          = true,
  navBeacons     = true,
  resourceProbes = true,
  satellites     = true,
  lockboxes      = true,

  roleFight      = true,
  roleTrade      = true,
  roleMine       = true,
  roleBuild      = true,
  roleResupply   = true,
  roleTug        = true,
  roleRecycling  = true,
  roleRacing     = true,

  sorterRow      = true,
  expandScope    = "first",
  altRowStations = true,
  altRowFleets   = true,
  altRowShips    = true,

  hideEmptyTradeRows = false,

  widthPercent   = 60,
  startView      = "overview",
}

local function write(message, ...)
  if select("#", ...) > 0 then
    message = string.format(message, ...)
  end
  DebugError("InfoCenter: " .. message)
end

function eic.Error(message, ...) write(message, ...) end
function eic.Debug(message, ...) if eic.debugLevel ~= "none" then write(message, ...) end end
function eic.Trace(message, ...) if eic.debugLevel == "trace" then write(message, ...) end end

function eic.ReadDebugLevel()
  local playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  local config = GetNPCBlackboard(playerId, eic.configBlackboard)
  if config and config.debugLevel then
    eic.debugLevel = tostring(config.debugLevel)
  end
end

function eic.SetDebugLevel(_, level)
  if level and level ~= "" then
    eic.debugLevel = tostring(level)
  else
    eic.ReadDebugLevel()
  end
end

-- The savedvariable is declared in ui.xml.
function eic.getOption(id)
  local value = EIC_Options[id]
  if value == nil then
    return OPTION_DEFAULTS[id]
  end
  return value
end

function eic.setOption(id, value)
  EIC_Options[id] = value
end

-- The right-hand info panel's left edge is the hard stop for the wide frame.
function eic.frameWidth(menu, mapConfig)
  local minWidth = menu.infoTableWidth
  local maxWidth = Helper.viewWidth - 2 * menu.infoTableOffsetX - menu.infoTableWidth - mapConfig.contextBorder
  local percent  = tonumber(eic.getOption("widthPercent")) or eic.widthPercent
  local width    = math.floor(percent / 100 * Helper.viewWidth)

  if maxWidth < minWidth then
    return minWidth
  end
  return math.max(minWidth, math.min(maxWidth, width))
end

-- Logical columns.
--
-- span        physical columns the cell occupies before any growth
-- fixed       "row" square button column, "icon" fleet-icon columns
-- minPercent  lower bound for an auto-sized column
-- weight      share of the leftover width one physical column takes, 1 being the equal default;
--             below 1 the difference goes to the slack column, so no other column moves
-- slack       takes what the narrow columns give up; the growing column by default
-- grow        swallows the unused columns to its right, and the view's surplus under 13
-- growBack    swallows the unused run to its left
-- applies     nil means every row; false leaves the physical columns empty
-- sort        a sorter key, or a list of { key, header } steps the button walks
-- render      paints the single (possibly spanned) cell; reaches the engine through ctx.data
eic.COLUMNS = {
  expand = {
    id    = "expand",
    span  = 1,
    fixed = "row",
    render = function(cell, ctx)
      if ctx.expand then
        cell:createButton(ctx.expand.colors):setText(ctx.expand.text, { halign = "center" })
        cell.handlers.onClick = ctx.expand.onClick
      elseif ctx.isCommanderRepeat then
        cell:createText("\27[menu_star_04]", { halign = "center", color = Color["text_skills"] })
      end
    end,
  },

  name = {
    id         = "name",
    span       = 1,
    minPercent = 20,
    header     = ReadText(1001, 2809),
    sort       = "name",
    render = function(cell, ctx)
      local text = ctx.alert .. ctx.name
      if ctx.kind == "wing" and ctx.fleetName ~= "" then
        cell:createText(string.format("%s: %s%s\27X", ctx.fleetName, Helper.convertColorToText(ctx.color), text),
          { font = ctx.font, mouseOverText = ctx.mouseOver })
      else
        cell:createText(text, { font = ctx.font, color = ctx.color, mouseOverText = ctx.mouseOver })
      end
    end,
  },

  sector = {
    id     = "sector",
    span   = 2,
    header = ReadText(1001, 11284),
    sort   = "sector",
    render = function(cell, ctx)
      cell:createText(ctx.locationText, { halign = "center", color = ctx.data.getSectorColor(ctx.sectorId) })
    end,
  },

  order = {
    id      = "order",
    span    = 3,
    grow    = true,
    header  = ReadText(1001, 8392),
    sort    = "order",
    applies = function(ctx)
      return ctx.isConstruction or (ctx.kind ~= "station" and ctx.kind ~= "wing")
    end,
    render = function(cell, ctx)
      if ctx.isConstruction then
        cell:createText(ReadText(1001, 3217), { halign = "center", color = Color["text_inactive"] })
      else
        cell:createText(ctx.orderText, { halign = "center" })
      end
    end,
  },

  action = {
    id      = "action",
    span    = 1,
    grow    = true,
    header  = ReadText(1001, 12822),
    applies = function(ctx) return ctx.kind == "ship" end,
    render = function(cell, ctx)
      cell:createText(ctx.actionText, { halign = "center" })
    end,
  },

  -- One cell of inline icons over the order and activity columns a station or wing row
  -- leaves empty; subordinate group rows fill the same columns through the same builder.
  fleet = {
    id       = "fleet",
    span     = 1,
    growBack = true,
    applies  = function(ctx)
      return (ctx.kind == "station" or ctx.kind == "wing") and not ctx.isConstruction
    end,
    render = function(cell, ctx)
      cell:createText(ctx.data.fleetTypesText(ctx.fleetTypes), { halign = "right" })
    end,
  },

  hullBar = {
    id      = "hullBar",
    span    = 1,
    header  = ReadText(1001, 1),
    sort    = "hull",
    applies = function(ctx) return not ctx.isConstruction end,
    render = function(cell, ctx)
      cell:createObjectShieldHullBar(ctx.component, { height = ctx.rowHeight / 2 })
    end,
  },

  -- Stars need less room than an equal share; what these give up goes to the activity column.
  skill = {
    id      = "skill",
    span    = 2,
    weight  = 0.8,
    header  = ReadText(1001, 9124),
    sort    = "skill",
    applies = function(ctx) return not ctx.isConstruction end,
    render = function(cell, ctx)
      local text, mouseOver = ctx.data.getSkillText(ctx)
      cell:createText(text, {
        halign = "center", color = (text ~= "") and Color["text_skills"] or nil, mouseOverText = mouseOver,
      })
    end,
  },

  crewSkill = {
    id      = "crewSkill",
    span    = 2,
    weight  = 0.8,
    header  = ReadText(1001, 9427),
    sort    = "crew",
    applies = function(ctx) return (ctx.kind ~= "station") and (not ctx.isConstruction) end,
    render = function(cell, ctx)
      local text, mouseOver = ctx.data.getCrewSkillText(ctx)
      cell:createText(text, {
        halign = "center", color = (text ~= "") and Color["text_skills"] or nil, mouseOverText = mouseOver,
      })
    end,
  },

  -- Only a ship trades; a station row leaves the space to the account cell, a wing row to cargo.
  ware = {
    id      = "ware",
    span    = 1,
    grow    = true,
    header  = ReadText(1001, 45),
    applies = function(ctx) return ctx.kind == "ship" end,
    render = function(cell, ctx)
      cell:createText(ctx.data.getTradeWareText(ctx), { halign = "center" })
    end,
  },

  -- Never spans, so the figures line up down one column whatever row they sit on;
  -- a fleet row sums the holds under it instead of showing the leader's own.
  cargo = {
    id      = "cargo",
    span    = 2,
    slack   = true,
    header  = ReadText(1001, 63),
    -- Two figures in one cell, so the button sorts by either: total, then used.
    sort    = {
      { key = "cargo" },
      { key = "cargoUsed", header = ReadText(1001, 11277) },
    },
    applies = function(ctx) return not ctx.isConstruction end,
    render = function(cell, ctx)
      local text, mouseOver
      if ctx.kind == "wing" then
        text, mouseOver = ctx.data.getFleetCargoText(ctx)
      else
        text, mouseOver = ctx.data.getCargoText(ctx)
      end
      cell:createText(text, { halign = "right", mouseOverText = mouseOver })
    end,
  },

  balance = {
    id       = "balance",
    span     = 1,
    growBack = true,
    header   = ReadText(1001, 7773),
    applies  = function(ctx) return (ctx.kind == "station") and (not ctx.isConstruction) end,
    render = function(cell, ctx)
      cell:createText(ctx.data.getMoneyText(ctx), { halign = "right" })
    end,
  },

  -- The signal itself is the tab's filter, so the column shows what follows it instead.
  nextOrder = {
    id      = "nextOrder",
    span    = 1,
    grow    = true,
    header  = ReadText(eic.PAGE, 202),
    applies = function(ctx) return ctx.kind ~= "station" end,
    render = function(cell, ctx)
      local text, mouseOver, color = ctx.data.getNextOrderText(ctx)
      cell:createText(text, { halign = "center", color = color, mouseOverText = mouseOver })
    end,
  },

  failedOrder = {
    id      = "failedOrder",
    span    = 2,
    header  = ReadText(1001, 8837),
    applies = function(ctx) return ctx.kind ~= "station" end,
    render = function(cell, ctx)
      local failure = ctx.data.getFailure(ctx.info)
      cell:createText(failure and failure.text or "", { halign = "center", color = Color["text_warning"] })
    end,
  },

  failureMessage = {
    id      = "failureMessage",
    span    = 1,
    grow    = true,
    header  = ReadText(1001, 9189),
    applies = function(ctx) return ctx.kind ~= "station" end,
    render = function(cell, ctx)
      local failure = ctx.data.getFailure(ctx.info)
      cell:createText(failure and failure.message or "", {
        color = Color["text_warning"], mouseOverText = failure and failure.mouseOver or nil,
      })
    end,
  },
}

-- One column list per tab; the flat form drops the columns that need a structural row.
-- The Trade forms state the activity column rather than let it take the surplus, and the slack
-- cargo cell takes back what it gives up, so all three end on the same physical map.
local TRADE_ACTION      = { "action", span = 2, weight = 0.8 }
local TRADE_WIDE_WARE   = { "ware", span = 2 }

local PROPERTY_COLUMNS   = { "expand", "name", "sector", "order", "action", "fleet", "hullBar" }
local CREW_COLUMNS       = { "expand", "name", "sector", "order", "action", "fleet", "skill", "crewSkill" }
local TRADE_COLUMNS      = { "expand", "name", "sector", "order", TRADE_ACTION, "cargo", "ware", "balance" }
local FLEET_TRADE_COLUMNS = { "expand", "name", "sector", "order", TRADE_ACTION, "cargo", TRADE_WIDE_WARE }
local SHIP_COLUMNS       = { "name", "sector", "order", "action", "hullBar" }
local SHIP_CREW_COLUMNS  = { "name", "sector", "order", "action", "skill", "crewSkill" }
local SHIP_TRADE_COLUMNS = { "name", "sector", "order", { "action", span = 3, weight = 0.8 }, "cargo", TRADE_WIDE_WARE }
local SIGNAL_COLUMNS     = { "name", "sector", "order", "nextOrder", "hullBar" }
local FAILED_COLUMNS     = { "name", "sector", "order", "failedOrder", "failureMessage" }

-- Tab names shared by the scoped groups, each behind its own prefix.
local NAME_OVERVIEW = ReadText(1001, 8045)
local NAME_CREW     = ReadText(1001, 80)
local NAME_TRADE    = ReadText(eic.PAGE, 201)

--- "Stations: Overview" - the group prefix in front of the tab's own name.
local function scopedName(scope, name)
  return string.format(ReadText(eic.PAGE, 203), scope, name)
end

-- One entry per tab cell, in strip order, spacers separating the groups.
-- scope narrows data.collect to one section, filter names a predicate in eic_data.ROW_FILTERS,
-- strip picks which of the two tab tables draws the cell.
eic.VIEWS = {
  { strip = 1, category = "overview",   name = NAME_OVERVIEW,                                   icon = eic.icons.overview,   source = "property", columns = PROPERTY_COLUMNS },
  { strip = 1, category = "crew",       name = NAME_CREW,                                       icon = eic.icons.crew,       source = "property", columns = CREW_COLUMNS },
  { strip = 1, category = "trade",      name = NAME_TRADE,                                      icon = eic.icons.trade,      source = "property", columns = TRADE_COLUMNS,      filter = "tradeCargo" },
  { strip = 1, spacer = true },
  { strip = 1, category = "stOverview", name = scopedName(ReadText(1001, 4), NAME_OVERVIEW),    icon = eic.icons.stOverview, source = "property", columns = PROPERTY_COLUMNS,   scope = "stations" },
  { strip = 1, category = "stCrew",     name = scopedName(ReadText(1001, 4), NAME_CREW),        icon = eic.icons.stCrew,     source = "property", columns = CREW_COLUMNS,       scope = "stations" },
  { strip = 1, category = "stTrade",    name = scopedName(ReadText(1001, 4), NAME_TRADE),       icon = eic.icons.stTrade,    source = "property", columns = TRADE_COLUMNS,      scope = "stations", filter = "tradeCargo" },
  { strip = 1, spacer = true },
  { strip = 2, category = "flOverview", name = scopedName(ReadText(1001, 8326), NAME_OVERVIEW), icon = eic.icons.flOverview, source = "property", columns = PROPERTY_COLUMNS,   scope = "fleets" },
  { strip = 2, category = "flCrew",     name = scopedName(ReadText(1001, 8326), NAME_CREW),     icon = eic.icons.flCrew,     source = "property", columns = CREW_COLUMNS,       scope = "fleets" },
  { strip = 2, category = "flTrade",    name = scopedName(ReadText(1001, 8326), NAME_TRADE),    icon = eic.icons.flTrade,    source = "property", columns = FLEET_TRADE_COLUMNS, scope = "fleets",  filter = "tradeCargo" },
  { strip = 2, spacer = true },
  { strip = 2, category = "unassigned", name = ReadText(1001, 8327),                            icon = eic.icons.unassigned, source = "property", columns = PROPERTY_COLUMNS,   scope = "unassigned" },
  { strip = 2, spacer = true },
  { strip = 2, category = "shOverview", name = scopedName(ReadText(1001, 6), NAME_OVERVIEW),    icon = eic.icons.shOverview, source = "ships",    columns = SHIP_COLUMNS },
  { strip = 2, category = "shCrew",     name = scopedName(ReadText(1001, 6), NAME_CREW),        icon = eic.icons.shCrew,     source = "ships",    columns = SHIP_CREW_COLUMNS },
  { strip = 2, category = "shTrade",    name = scopedName(ReadText(1001, 6), NAME_TRADE),       icon = eic.icons.shTrade,    source = "ships",    columns = SHIP_TRADE_COLUMNS, filter = "tradeCargo" },
  { strip = 2, category = "damaged",    name = ReadText(1001, 1501),                            icon = eic.icons.damaged,    source = "ships",    columns = SHIP_COLUMNS,       filter = "damaged" },
  { strip = 2, category = "signal",     name = ReadText(1041, 111),                             icon = eic.icons.signal,     source = "ships",    columns = SIGNAL_COLUMNS,     filter = "signal" },
  { strip = 2, category = "failed",     name = ReadText(1001, 11621),                           icon = eic.icons.failed,     source = "ships",    columns = FAILED_COLUMNS,     filter = "failed" },
}

--- The tab strip as a dropdown list. A dropdown option's icon field draws nothing, so the
--- tab icon goes into the text as an escape sequence, the way vanilla's dropdowns carry one.
local function viewChoices()
  local choices = {}
  for _, view in ipairs(eic.VIEWS) do
    if view.category and (not view.pending) then
      choices[#choices + 1] = {
        id   = view.category,
        text = "\27[" .. view.icon .. "] " .. view.name,
        icon = "",
        displayremoveoption = false,
      }
    end
  end
  return choices
end

-- The right bar in draw order. An option is a checkbox unless it names a scale, which
-- makes it a slider, or choices, which makes it a dropdown.
eic.OPTION_SECTIONS = {
  {
    caption = ReadText(1001, 9648),
    { id = "classXL",       name = ReadText(1001, 48) },
    { id = "classL",        name = ReadText(1001, 49) },
    { id = "classM",        name = ReadText(1001, 50) },
    { id = "classS",        name = ReadText(1001, 51) },
    -- Smallest size of all; the id stays as it was, so saved settings carry over.
    { id = "roleSpacesuit", name = ReadText(eic.PAGE, 301) },
  },
  {
    caption = ReadText(eic.PAGE, 300),
    { id = "roleFight",     name = ReadText(20213, 300) },
    { id = "roleTrade",     name = ReadText(20213, 200) },
    { id = "roleMine",      name = ReadText(20213, 500) },
    { id = "roleBuild",     name = ReadText(20213, 400) },
    { id = "roleResupply",  name = ReadText(20213, 1500) },
    { id = "roleTug",       name = ReadText(20213, 1800) },
    { id = "roleRecycling", name = ReadText(20213, 1900) },
    { id = "roleRacing",    name = ReadText(20213, 2000) },
  },
  {
    caption = ReadText(1001, 1332),
    { id = "laserTowers",    name = ReadText(1001, 1333) },
    { id = "mines",          name = ReadText(1001, 1326) },
    { id = "navBeacons",     name = ReadText(1001, 1328) },
    { id = "resourceProbes", name = ReadText(1001, 1329) },
    { id = "satellites",     name = ReadText(1001, 1327) },
    { id = "lockboxes",      name = ReadText(eic.PAGE, 302) },
  },
  {
    caption = ReadText(eic.PAGE, 303),
    { id = "sorterRow", name = ReadText(eic.PAGE, 304) },
    {
      id      = "expandScope",
      name    = ReadText(eic.PAGE, 309),
      choices = {
        { id = "first", text = ReadText(eic.PAGE, 310), icon = "", displayremoveoption = false },
        { id = "full",  text = ReadText(eic.PAGE, 311), icon = "", displayremoveoption = false },
      },
    },
    {
      id    = "widthPercent",
      name  = ReadText(eic.PAGE, 306),
      scale = { min = eic.widthPercentMin, max = eic.widthPercentMax, step = 1, suffix = "%" },
    },
    {
      id      = "startView",
      name    = ReadText(eic.PAGE, 308),
      choices = viewChoices(),
    },
  },
  -- Named by section, and a scoped tab is the same section, so one flag covers both.
  {
    caption = ReadText(eic.PAGE, 305),
    { id = "altRowStations", name = ReadText(1001, 4) },
    { id = "altRowFleets",   name = ReadText(1001, 8326) },
    { id = "altRowShips",    name = ReadText(1001, 6) },
  },
  {
    caption = NAME_TRADE,
    { id = "hideEmptyTradeRows", name = ReadText(eic.PAGE, 307) },
  },
}

-- Derived, so moving a cell between strips needs no second edit.
eic.NUMSTRIPS = 0
for _, view in ipairs(eic.VIEWS) do
  eic.NUMSTRIPS = math.max(eic.NUMSTRIPS, view.strip)
end

function eic.viewIndex(category)
  for i, view in ipairs(eic.VIEWS) do
    if view.category == category then
      return i
    end
  end
end

function eic.stripEntries(strip)
  local entries = {}
  for _, view in ipairs(eic.VIEWS) do
    if view.strip == strip then
      entries[#entries + 1] = view
    end
  end
  return entries
end

--- Column 1 of the first strip is the scroll hint; later strips indent by the same width instead.
function eic.stripFirstColumn(strip)
  return (strip == 1) and 2 or 1
end

function eic.stripPosition(category)
  for strip = 1, eic.NUMSTRIPS do
    local first = eic.stripFirstColumn(strip)
    for i, view in ipairs(eic.stripEntries(strip)) do
      if view.category == category then
        return strip, first + i - 1
      end
    end
  end
end

function eic.view()
  return eic.VIEWS[eic.viewIndex(eic.viewMode) or 1]
end

--- A column entry is an id, or a table of the id plus span/weight overriding it for one view.
function eic.columnId(item)
  return (type(item) == "table") and item[1] or item
end

function eic.sorterBase(sorterType)
  return (tostring(sorterType):gsub("Inverse$", ""))
end

--- A column's sort steps; a plain key is the single-step case every column but Cargo uses.
function eic.sortSteps(def)
  if def.sort == nil then
    return nil
  end
  if type(def.sort) == "string" then
    return { { key = def.sort } }
  end
  return def.sort
end

--- True when one of the view's columns carries this sorter, so the sorter row shows it.
function eic.viewOffersSorter(view, sorterType)
  local base = eic.sorterBase(sorterType)
  for _, item in ipairs(view.columns or {}) do
    local def = eic.COLUMNS[eic.columnId(item)]
    for _, step in ipairs((def and eic.sortSteps(def)) or {}) do
      if step.key == base then
        return true
      end
    end
  end
  return false
end

--- The next tab a scroll can land on; spacers and unfinished views are skipped.
function eic.nextView(direction)
  local index = eic.viewIndex(eic.viewMode)
  if index == nil then
    return nil
  end

  local step = (direction == "right") and 1 or -1
  for i = index + step, (step > 0) and #eic.VIEWS or 1, step do
    local view = eic.VIEWS[i]
    if view.category and (not view.pending) then
      return view.category
    end
  end
end

-- InfoCenter_Filters is forleyor's savedvariable and only exists while his mod is
-- installed, so a missing one is not a failed import and stays retryable.
local function importLegacyOptions()
  if EIC_Options.legacyImported then
    return
  end

  local legacy = rawget(_G, "InfoCenter_Filters")
  if type(legacy) ~= "table" then
    eic.Debug("no InfoCenter_Filters found, nothing to import")
    return
  end

  local count = 0
  for oldId, target in pairs(LEGACY_OPTIONS) do
    local value = legacy[oldId]
    if type(value) == "boolean" then
      for _, newId in ipairs((type(target) == "table") and target or { target }) do
        EIC_Options[newId] = value
        eic.Trace("imported %s as %s = %s", oldId, newId, tostring(value))
      end
      count = count + 1
    end
  end

  EIC_Options.legacyImported = true
  eic.Debug("imported %d option(s) from InfoCenter_Filters", count)
end

local function init()
  ---@diagnostic disable-next-line: global-in-non-module
  EIC_Options = EIC_Options or {}

  RegisterEvent("InfoCenter.SetDebugLevel", eic.SetDebugLevel)
  eic.ReadDebugLevel()
  importLegacyOptions()

  -- A preference, not live state: it seeds viewMode once and the strip owns it from there.
  local startView = tostring(eic.getOption("startView"))
  if eic.viewIndex(startView) then
    eic.viewMode = startView
  end

  eic.Debug("config init: debugLevel=%s widthPercent=%s view=%s",
    eic.debugLevel, tostring(eic.getOption("widthPercent")), eic.viewMode)
end

Register_Require_With_Init("extensions.enhanced_info_center.ui.eic_config", eic, init)

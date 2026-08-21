-- Info Center - the filter row above the sorter row: the controls it holds, the lists they
-- offer and the rows they leave standing. Reads objects through eic_data and is read back by
-- the row builder, so nothing here reaches for the row builder itself.

local eic  = require("extensions.enhanced_info_center.ui.eic_config")
local data = require("extensions.enhanced_info_center.ui.eic_data")

local filters = {}

-- The dropdown entry standing for "no filter"; never a sector key, a ware id or a star count.
local ANY = "*"

-- One filter set per tab, session-lived, the way eic.pages keeps one page per tab.
local state = {}

--region Object values
--
-- Each returns the key a filter matches on, the text its list shows and, where the column
-- paints its cell, the colour to paint the entry in. A value exists exactly where the column
-- would draw one, so a list never offers a row the cell leaves blank.

--- Full stars alone: the thirds the skill cells draw, divided down and capped at the fifth.
local function fullStars(value)
  return math.min(5, math.floor(math.floor(value * 15 / 100) / 3))
end

local function sectorValue(info)
  if (info.sectorId == nil) or (info.sector == nil) or (info.sector == "") then
    return nil
  end
  return tostring(info.sectorId), info.sector, data.getSectorColor(info.sectorId)
end

local function orderValue(info)
  if not Helper.isComponentClass(info.realClassId, "ship") then
    return nil
  end
  return data.getOrderKind(info.id)
end

local function wareValue(info)
  local trade = data.getTradeWare(info)
  if (trade == nil) or (trade.ware == nil) then
    return nil
  end
  return trade.ware, trade.name or trade.ware
end

local function skillValue(info)
  local value = data.skillValue(info)
  if value <= 0 then
    return nil
  end
  local stars = fullStars(value)
  return tostring(stars), Helper.displaySkill(stars * 3)
end

local function crewSkillValue(info)
  local value = data.crewSkillValue(info)
  if value <= 0 then
    return nil
  end
  local stars = fullStars(value)
  return tostring(stars), Helper.displaySkill(stars * 3)
end

-- One control per entry, over the column it filters, in the order the row draws them.
-- A ware column alone is too narrow for a list, so the cell takes in the account column
-- after it where the view has one and the activity column before it where it has not.
-- `numeric` sorts the list by key rather than by text, since a star string sorts by its
-- escape sequence and not by how many stars it draws.
local FILTERS = {
  { id = "name",      column = "name",      search = true, hint = 407 },
  { id = "sector",    column = "sector",    any = 401, value = sectorValue },
  { id = "order",     column = "order",     any = 402, value = orderValue },
  { id = "ware",      column = "ware",      any = 403, value = wareValue, to = "balance", from = "action" },
  { id = "skill",     column = "skill",     any = 404, value = skillValue,     numeric = true },
  { id = "crewSkill", column = "crewSkill", any = 405, value = crewSkillValue, numeric = true },
}

--endregion

--region State

local function current()
  state[eic.viewMode] = state[eic.viewMode] or {}
  return state[eic.viewMode]
end

function filters.get(id)
  return current()[id]
end

--- Any change drops the tab back to its first page - the list it was paging is gone - and is
--- worth a rebuild only when the value really moved, or a closed edit box would cost a cursor.
function filters.set(id, value)
  if (value == "") or (value == ANY) then
    value = nil
  end
  local set = current()
  if set[id] == value then
    return false
  end

  set[id] = value
  eic.pages[eic.viewMode] = 1
  eic.Debug("filter %s on %s set to %s", id, eic.viewMode, tostring(value))
  eic.menu.refreshInfoFrame()
  return true
end

--endregion

--region The refresh pass

-- What one build of the list knows about its filters: which controls the tab shows, what each
-- of their lists may offer, and which rows survive. Rebuilt by prepare, read by everything else.
local scan = { active = false, controls = {}, options = {}, texts = {}, colors = {},
  subtree = {}, subCount = {}, dockCount = {}, groupCount = {},
  open = { property = {}, groups = {}, docked = {} } }

--- True while nothing is set: the whole pass then only fills the lists the controls offer.
function filters.active()
  return scan.active
end

function filters.any()
  for _ in pairs(current()) do
    return true
  end
  return false
end

--- The whole set at once, so the reset button costs one rebuild rather than one per control.
function filters.clear()
  if not filters.any() then
    return false
  end
  state[eic.viewMode] = {}
  eic.pages[eic.viewMode] = 1
  eic.Debug("filters cleared on %s", eic.viewMode)
  eic.menu.refreshInfoFrame()
  return true
end

--- Whether one object answers one control. A control that is not set answers for everything.
local function passes(control, info, key)
  local wanted = filters.get(control.id)
  if wanted == nil then
    return true
  end
  if control.search then
    local needle = wanted:lower()
    return ((info.name or ""):lower():find(needle, 1, true) ~= nil)
        or ((info.objectid or ""):lower():find(needle, 1, true) ~= nil)
  end
  return key == wanted
end

--- One node and everything under it, returning whether the subtree holds a match: that is what
--- keeps a commander or a station on the list when only something under it matched.
local function walk(instance, view, component)
  local visible, info = data.isRowVisible(instance, view, component)
  if not visible then
    return false
  end

  local key = tostring(component)
  local seen = scan.subtree[key]
  if seen ~= nil then
    return seen
  end
  -- Claimed before the children are walked, so a ship listed under two parents is counted by
  -- both without being walked twice, and a loop between them could not run away.
  scan.subtree[key] = false

  -- Values first: a node its own filter hides still fills the lists the other controls offer.
  local keys = {}
  for _, control in ipairs(scan.controls) do
    if not control.search then
      local id, text, color = control.value(info)
      if id then
        keys[control.id] = id
        scan.texts[control.id][id]  = text
        scan.colors[control.id][id] = color
      end
    end
  end

  -- A list may offer what survives every filter but its own, so a choice can never empty it.
  local misses, missed = 0, nil
  for _, control in ipairs(scan.controls) do
    if not passes(control, info, keys[control.id]) then
      misses = misses + 1
      missed = control
    end
  end
  if misses <= 1 then
    for _, control in ipairs(scan.controls) do
      local id = keys[control.id]
      if id and ((misses == 0) or (missed == control)) then
        scan.options[control.id][id] = true
      end
    end
  end
  local matched = (misses == 0)

  local infoTableData = eic.menu.infoTableData[instance]
  local subordinates  = infoTableData.subordinates[key] or {}
  local dockedShips   = infoTableData.dockedships[key] or {}

  -- Counted per branch, since a group or a dock block with nothing left in it draws no header.
  local groupCounts, subCount, dockCount = {}, 0, 0
  for _, subordinate in ipairs(subordinates) do
    local group = subordinate.component
        and data.getObjectInfo(instance, subordinate.component).subordinateGroup
    if group and (group > 0) and walk(instance, view, subordinate.component) then
      groupCounts[group] = (groupCounts[group] or 0) + 1
      subCount = subCount + 1
    end
  end
  for _, docked in ipairs(dockedShips) do
    if docked.component and walk(instance, view, docked.component) then
      dockCount = dockCount + 1
    end
  end

  scan.subCount[key]  = subCount
  scan.dockCount[key] = dockCount
  for group, count in pairs(groupCounts) do
    scan.groupCount[key .. group] = count
  end

  -- A row standing only for what is under it is opened to show it; one that matched on its own
  -- is a hit like any other and keeps the state the player left it in.
  if not matched then
    if subCount + dockCount > 0 then
      scan.open.property[key] = true
    end
    for group, count in pairs(groupCounts) do
      if count > 0 then
        scan.open.groups[key .. group] = true
      end
    end
    if dockCount > 0 then
      scan.open.docked[key] = true
    end
  end

  local survives = matched or ((subCount + dockCount) > 0)
  scan.subtree[key] = survives
  return survives
end

--- The deployables tab groups its objects by name before the filters have had their say, so
--- the groups are pruned to what is left and the ones emptied by it drop out with their header.
local function pruneGroups(instance, section)
  local kept = {}
  for _, group in ipairs(section.groups) do
    local items, sector, sectorId = {}, nil, nil
    for _, component in ipairs(group.items) do
      if scan.subtree[tostring(component)] then
        local info = data.getObjectInfo(instance, component)
        items[#items + 1] = component
        if #items == 1 then
          sector, sectorId = info.sector, info.sectorId
        elseif sector ~= info.sector then
          -- A shared sector is worth stating on the group row; a mixed one is false, not a name.
          sector = false
        end
      end
    end
    if #items > 0 then
      group.items, group.sector, group.sectorId = items, sector, sectorId
      kept[#kept + 1] = group
    end
  end
  section.groups = kept
end

--- Run once per build, between collecting the objects and counting the rows they make: it
--- fills the lists the controls offer and settles which rows the filters leave standing.
function filters.prepare(instance, layout, sections)
  scan = { active = false, controls = {}, options = {}, texts = {}, colors = {},
    subtree = {}, subCount = {}, dockCount = {}, groupCount = {},
    open = { property = {}, groups = {}, docked = {} } }

  for _, control in ipairs(FILTERS) do
    if layout.byId[control.column] then
      scan.controls[#scan.controls + 1] = control
      scan.options[control.id] = {}
      scan.texts[control.id]   = {}
      scan.colors[control.id]  = {}
      if filters.get(control.id) ~= nil then
        scan.active = true
      end
    end
  end
  if #scan.controls == 0 then
    return
  end

  for _, section in ipairs(sections) do
    if section.kind ~= "construction" then
      for _, component in ipairs(section.items) do
        walk(instance, layout.view, component)
      end
      if scan.active and (section.kind == "deployables") then
        pruneGroups(instance, section)
      end
    end
  end
end

--endregion

--region What the row builder asks

--- The row gates plus the filters, and a parent stands whenever anything under it matched.
function filters.visible(instance, view, component)
  local visible, info = data.isRowVisible(instance, view, component)
  if visible and scan.active then
    visible = scan.subtree[tostring(component)] and true or false
  end
  return visible, info
end

--- Whether a row still has anything to unfold, which is what puts an expand button on it.
--- `dockedOnly` is a row in a dock block, which never unfolds its subordinates.
function filters.hasChildren(key, subordinates, dockedShips, dockedOnly)
  if not scan.active then
    return (((not dockedOnly) and subordinates.hasRendered) or (#dockedShips > 0)) and true or false
  end
  local subCount = dockedOnly and 0 or (scan.subCount[key] or 0)
  return (subCount + (scan.dockCount[key] or 0)) > 0
end

function filters.subordinatesShown(key)
  return (not scan.active) or ((scan.subCount[key] or 0) > 0)
end

function filters.groupShown(key, group)
  return (not scan.active) or ((scan.groupCount[key .. group] or 0) > 0)
end

function filters.dockShown(key)
  return (not scan.active) or ((scan.dockCount[key] or 0) > 0)
end

--- Opened for this build alone: the player's own expansion table is never written, so
--- clearing the filters puts the list back exactly as they left it.
function filters.forceOpen(kind, key)
  return scan.active and scan.open[kind][key] and true or false
end

--- The build queue is not part of the filtered list, so a filter takes it off the tab rather
--- than leave a page of tasks under two matching rows.
function filters.showConstruction()
  return not scan.active
end

--endregion

--region The row

--- In the leading column, which is the expand column on a sectioned tab and the lead column
--- on a flat one - the same cell the sorter row keeps its expand-all button in.
local function createResetButton(row, layout, height)
  local entry = layout.byId.expand or layout.byId.lead
  if entry == nil then
    return
  end

  local cell       = row[entry.first]
  local iconHeight = height * 3 / 4
  local button     = cell:createButton({
    scaling = false, height = height, active = filters.any(),
    mouseOverText = ReadText(eic.PAGE, 406),
  })
  button:setIcon("widget_cross_01", {
    width = iconHeight, height = iconHeight,
    x = (button:getColSpanWidth() - iconHeight) / 2, y = (height - iconHeight) / 2,
  })
  cell.handlers.onClick = function() return filters.clear() end
end

--- Vanilla's own search box: it filters once the player is done typing, since a rebuild per
--- keystroke would take the box out from under them. noupdate keeps the map's refresh off it.
local function createSearchBox(cell, control, height)
  cell:createEditBox({
    description = ReadText(eic.PAGE, control.hint),
    defaultText = ReadText(1001, 3250),
    scaling     = false,
    height      = height,
  }):setText(filters.get(control.id) or "",
    { x = Helper.standardTextOffsetx, fontsize = eic.fontSize, scaling = true })

  cell.handlers.onEditBoxActivated   = function() eic.menu.noupdate = true end
  cell.handlers.onEditBoxDeactivated = function(_, text)
    eic.menu.noupdate = false
    return filters.set(control.id, text)
  end
end

--- The values this build found, plus the entry that clears the control. What is set stays on
--- the list even when nothing carries it any more, or the box would not say what it filters by.
local function createDropDown(cell, control, height)
  local list  = {}
  local set   = filters.get(control.id)
  local found = false
  for id in pairs(scan.options[control.id]) do
    list[#list + 1] = { id = id, text = scan.texts[control.id][id] or id }
    found = found or (id == set)
  end
  if set and (not found) then
    list[#list + 1] = { id = set, text = scan.texts[control.id][set] or set }
  end

  table.sort(list, function(a, b)
    if control.numeric then
      return tonumber(a.id) < tonumber(b.id)
    end
    if a.text ~= b.text then
      return a.text < b.text
    end
    return a.id < b.id
  end)

  -- Coloured only once the list is in order: the colour goes into the text as an escape
  -- sequence, and sorting on that would order the entries by faction rather than by name.
  local options = { { id = ANY, text = ReadText(eic.PAGE, control.any), icon = "", displayremoveoption = false } }
  for _, item in ipairs(list) do
    local color = scan.colors[control.id][item.id]
    local text  = color and (Helper.convertColorToText(color) .. item.text .. "\27X") or item.text
    options[#options + 1] = { id = item.id, text = text, icon = "", displayremoveoption = false }
  end

  -- The height is already scaled, so the widget must not scale it again; the text sets its own
  -- scaling back, since setTextProperties otherwise hands it the widget's.
  cell:createDropDown(options, {
    startOption = set or ANY, scaling = false, height = height, textOverride = "",
  }):setTextProperties({ halign = "center", fontsize = eic.fontSize, scaling = true })
  cell.handlers.onDropDownConfirmed = function(_, id) return filters.set(control.id, id) end
end

--- Generated from the same layout the sorter row and the data rows walk, so a control cannot
--- end up over a column it does not filter. A tab shows only the controls it has columns for.
function filters.createRow(ftable, layout)
  local row    = ftable:addRow(true, { fixed = true, bgColor = Color["frame_background_semitransparent"] })
  -- An edit box has a floor of its own, and the row is never shorter than the tallest thing on it.
  local height = Helper.scaleY(eic.rowHeight)
  if height < Helper.editboxMinHeight then
    height = Helper.editboxMinHeight
  end

  createResetButton(row, layout, height)

  for _, control in ipairs(scan.controls) do
    local entry = layout.byId[control.column]
    local first = entry.first
    local last  = entry.first + entry.span - 1

    -- Widened over the neighbour the view has, forwards for preference: neither column
    -- carries a control of its own, so the cell can take either without displacing one.
    local to = control.to and layout.byId[control.to]
    if to then
      last = to.first + to.span - 1
    else
      local from = control.from and layout.byId[control.from]
      first = (from and from.first) or first
    end

    local cell = row[first]
    if last > first then
      cell:setColSpan(last - first + 1)
    end

    if control.search then
      createSearchBox(cell, control, height)
    else
      createDropDown(cell, control, height)
    end
  end
end

--endregion

Register_Require_Response("extensions.enhanced_info_center.ui.eic_filters", filters)

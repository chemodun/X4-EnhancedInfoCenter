-- Info Center - the generic row builder.
-- One walk over the view's column list paints every kind of row: a column that does not
-- apply leaves its columns empty and a growing neighbour swallows the run.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C   = ffi.C

---@diagnostic disable-next-line: unresolved-require
local eic  = require("extensions.enhanced_info_center.ui.eic_config")
---@diagnostic disable-next-line: unresolved-require
local data = require("extensions.enhanced_info_center.ui.eic_data")
local flt  = require("extensions.enhanced_info_center.ui.eic_filters")

-- pageFollowed: set when a build turned the page itself to follow the map's selection, and
-- cleared by the panel with the menu.set* fields it is built alongside.
local rows = { pageFollowed = false }

-- Encyclopedia entries the map records for what it has shown.
local KNOWN_ITEM_CLASS = {
  station = "stationtypes",
  ship_xl = "shiptypes_xl",
  ship_l  = "shiptypes_l",
  ship_m  = "shiptypes_m",
  ship_s  = "shiptypes_s",
  ship_xs = "shiptypes_xs",
}

--region Layout

-- Weights reach the engine as integers; see the note in rows.resolve.
local WEIGHT_SCALE = 20

local function applies(def, ctx)
  return (def.applies == nil) or def.applies(ctx)
end

--- Resolves a view's column list to physical columns, filling the table exactly.
function rows.resolve(view)
  local maxCols = Helper.maxTableCols
  local layout  = { entries = {}, byId = {}, total = 0 }
  local next     = 1
  local growIdx  = nil
  local slackIdx = nil

  for _, item in ipairs(view.columns) do
    local id  = eic.columnId(item)
    local def = eic.COLUMNS[id]
    if def == nil then
      eic.Error("view %s names unknown column %s", view.category, id)
    else
      local over  = (item ~= id) and item or {}
      local entry = {
        def    = def,
        first  = next,
        span   = over.span or def.span or 1,
        weight = over.weight or def.weight or 1.0,
      }
      next = next + entry.span
      layout.entries[#layout.entries + 1] = entry
      layout.byId[id] = entry
      if def.grow then
        growIdx = #layout.entries
      end
      if def.slack then
        slackIdx = slackIdx or #layout.entries
      end
    end
  end

  local used = next - 1
  if used > maxCols then
    eic.Error("view %s resolves to %d columns, above the cap of %d", view.category, used, maxCols)
    return nil
  end

  -- The surplus goes to the last growing column, rather than leaving a gap at the row end.
  if (used < maxCols) and growIdx then
    local surplus = maxCols - used
    layout.entries[growIdx].span = layout.entries[growIdx].span + surplus
    for i = growIdx + 1, #layout.entries do
      layout.entries[i].first = layout.entries[i].first + surplus
    end
    used = maxCols
  end

  -- Columns share the leftover width equally. What the narrow ones give up goes to the slack
  -- column, leaving the total weight - and so every other column's width - as it was.
  local given = 0.0
  for _, entry in ipairs(layout.entries) do
    given = given + entry.span * (1 - entry.weight)
  end
  local takerIdx = slackIdx or growIdx
  if (given > 0) and takerIdx then
    local taker = layout.entries[takerIdx]
    taker.weight = taker.weight + given / taker.span
  end

  -- Vanilla sums the weights as floats and gives the last column the ceil of the residue,
  -- which rounds a fractional-weight table one pixel over its width. Integers keep it exact.
  for _, entry in ipairs(layout.entries) do
    entry.weight = math.floor(entry.weight * WEIGHT_SCALE + 0.5)
  end

  -- Settled once the surplus has moved every `first`: a merge column hands its columns to the
  -- entry after it, which draws over both everywhere the filter row does not.
  for i, entry in ipairs(layout.entries) do
    local following = layout.entries[i + 1]
    if entry.def.merge and following then
      following.mergedFirst = entry.first
      following.mergedSpan  = following.span + (following.first - entry.first)
    end
  end

  layout.total = used
  return layout
end

--- Structural rows split where the object rows start their order column.
local function splitColumn(layout)
  local entry = layout.byId.order or layout.byId.action
  return entry and entry.first or (math.floor(layout.total / 2) + 1)
end

--- Where a structural row prints fleet data: the order column to the row end.
--- nil when the view has no fleet column, which keeps the data off the tabs without one.
local function fleetColumns(layout)
  if layout.byId.fleet == nil then
    return nil
  end
  return splitColumn(layout), layout.total
end

--- Where a structural row prints a cargo summary, so a group's total sits under its rows.
--- nil when the view has no cargo column.
local function cargoColumns(layout)
  local entry = layout.byId.cargo
  if entry == nil then
    return nil
  end
  return entry.first, entry.first + entry.span - 1
end

local function renderColumns(row, layout, ctx)
  local entries = layout.entries
  local i = 1
  local skipped = nil

  while i <= #entries do
    local entry = entries[i]
    local def   = entry.def
    local step  = i + 1

    if applies(def, ctx) then
      local first = entry.mergedFirst or entry.first
      local span  = entry.mergedSpan or entry.span
      if def.growBack and skipped then
        span  = span + (first - skipped)
        first = skipped
      end
      if def.grow then
        while (step <= #entries) and (not applies(entries[step].def, ctx)) do
          span = span + entries[step].span
          step = step + 1
        end
      end

      local cell = row[first]
      if span > 1 then
        cell:setColSpan(span)
      end
      def.render(cell, ctx)
      skipped = nil
    else
      skipped = skipped or entry.first
    end

    i = step
  end
end

local function applyColumnWidths(ftable, layout)
  local iconWidth = eic.menu.getShipIconWidth()
  for _, entry in ipairs(layout.entries) do
    local def = entry.def
    if def.fixed == "row" then
      -- 9.x insets the table inside its frame border and widens this column to match.
      ftable:setColWidth(entry.first,
        Helper.scaleY(eic.rowHeight) + (eic.isV9 and Helper.standardContainerOffset or 0), false)
    elseif def.fixed == "icon" then
      for i = 0, entry.span - 1 do
        ftable:setColWidth(entry.first + i, iconWidth, false)
      end
    elseif def.minPercent then
      ftable:setColWidthMinPercent(entry.first, def.minPercent, entry.weight)
    else
      for i = 0, entry.span - 1 do
        ftable:setColWidthMin(entry.first + i, 0, entry.weight, false)
      end
    end
  end

  -- A leading button column stays outside the row background, as vanilla's does.
  local first = layout.byId.expand and 2 or 1
  ftable:setDefaultBackgroundColSpan(first, layout.total - first + 1)
end

--endregion

--region Row context

--- The upkeep alert marker vanilla shows on its own property rows.
local function alertMarker(component)
  local menu = eic.menu
  if not menu.getFilterOption("layer_other", false) then
    return "", ""
  end

  local alertStatus, missionList = menu.getContainerAlertLevel(component)
  local minAlertLevel = tonumber(menu.getFilterOption("think_alert", false)) or 0
  if (minAlertLevel == 0) or (alertStatus < minAlertLevel) then
    return "", ""
  end

  local color = menu.holomapcolor.highalertcolor
  if alertStatus == 1 then
    color = menu.holomapcolor.lowalertcolor
  elseif alertStatus == 2 then
    color = menu.holomapcolor.mediumalertcolor
  end
  return Helper.convertColorToText(color) .. "\027[workshop_error]\027X",
      ReadText(1001, 3305) .. ReadText(1001, 120) .. "\n" .. missionList
end

local function buildContext(instance, layout, component, iteration, index, info)
  local menu           = eic.menu
  local view           = layout.view
  local key            = tostring(component)
  local component64    = info.id64
  local subordinates   = menu.infoTableData[instance].subordinates[key] or {}
  local isStation      = Helper.isComponentClass(info.realClassId, "station")
  local isWing         = (iteration == 0) and (not isStation) and (#subordinates > 0)
  local isDoubleRow    = (iteration == 0) and (isStation or (#subordinates > 0))
  local isConstruction = isStation and IsComponentConstruction(component) and true or false

  local name, color, bgColor, font, mouseOver = menu.getContainerNameAndColors(component, iteration, isDoubleRow, false, true)
  local alert, alertMouseOver = alertMarker(component)
  if alertMouseOver ~= "" then
    mouseOver = (mouseOver ~= "") and (mouseOver .. "\n\n" .. alertMouseOver) or alertMouseOver
  end

  local ctx = {
    view              = view,
    -- The section the row was emitted under, nested rows included; alternating colour is per section.
    section           = layout.sectionId,
    -- The columns reach the engine through here; see the contract in eic_config.
    data              = data,
    component         = component,
    id64              = component64,
    key               = key,
    info              = info,
    instance          = instance,
    kind              = isStation and "station" or (isWing and "wing" or "ship"),
    iteration         = iteration,
    index             = index,
    isConstruction    = isConstruction,
    isCommanderRepeat = false,
    name              = name,
    color             = color,
    bgColor           = bgColor,
    font              = font,
    mouseOver         = mouseOver,
    alert             = alert,
    fleetName         = "",
    sectorId          = info.sectorId,
    locationText      = info.sector or "",
    orderText         = "",
    actionText        = "",
    fleetTypes        = {},
    rowHeight         = eic.rowHeight,
    fontSize          = eic.fontSize,
    expand            = nil,
  }

  -- Asked for only where a column shows it; the deployables tab has neither.
  if (ctx.kind == "ship") and (layout.byId.order or layout.byId.action) then
    ctx.orderText, ctx.actionText = data.getOrderText(component)
  elseif not isConstruction then
    -- No entry cap: the cell spans the order and activity columns, so every type fits.
    ctx.fleetTypes = menu.getPropertyOwnedFleetData(instance, component, info.macro, nil)
    if isWing then
      ctx.fleetName = ffi.string(C.GetFleetName(component64))
    end
  end

  return ctx
end

-- The alternating-colour flag per section; construction rows paint their own background.
local SECTION_ALT_OPTION = {
  ownedstations    = "altRowStations",
  ownedfleets      = "altRowFleets",
  ownedships       = "altRowShips",
  owneddeployables = "altRowDeployables",
}

local function isDimmedRow(ctx)
  local option = SECTION_ALT_OPTION[ctx.section]
  return option and eic.getOption(option) and ((ctx.index % 2) == 1) and true or false
end

local function rowBackground(ctx)
  if isDimmedRow(ctx) then
    return Color["row_background_unselectable"]
  end
  return ctx.bgColor
end

--- A button paints its own background, so the default azure would stand out against the dim.
local function expandButtonColors(ctx)
  if isDimmedRow(ctx) then
    return { bgColor = Color["row_background_unselectable"] }
  end
  return {}
end

--endregion

--region Rows

local createObjectRow

local function createSubordinateSection(rowGroup, layout, instance, component, iteration, location)
  local menu         = eic.menu
  local key          = tostring(component)
  local component64  = ConvertIDTo64Bit(component)
  local subordinates = menu.infoTableData[instance].subordinates[key] or {}

  local groups = {}
  for _, subordinate in ipairs(subordinates) do
    if subordinate.component then
      local group = data.getObjectInfo(instance, subordinate.component).subordinateGroup
      if group and (group > 0) then
        if groups[group] then
          groups[group].subordinates[#groups[group].subordinates + 1] = subordinate
        else
          groups[group] = {
            assignment   = ffi.string(C.GetSubordinateGroupAssignment(component64, group)),
            subordinates = { subordinate },
          }
        end
      end
    end
  end

  for group = 1, 10 do
    if groups[group] and flt.groupShown(key, group) then
      local groupKey  = key .. group
      local extended  = menu.isSubordinateExtended(key, group)
      if (not extended) and menu.isCommander(component64, 0, group) then
        menu.extendedsubordinates[groupKey] = true
        extended = true
      end
      extended = extended or flt.forceOpen("groups", groupKey)

      local row = rowGroup:addRow({ "subordinates" .. groupKey, component, group },
        { bgColor = Color["row_background_blue"] })
      row[1]:createButton({}):setText(extended and "-" or "+", { halign = "center" })
      row[1].handlers.onClick = function() return menu.buttonExtendSubordinate(key, group) end

      local text = string.format("%s (%s)",
        string.rep("    ", iteration + 1) .. string.format(ReadText(1001, 8398), ReadText(20401, group)),
        data.assignmentName(groups[group].assignment))

      -- The group's make-up in the columns a station or wing row puts its fleet icons in.
      -- A Trade view has no such column and carries the group's summed holds instead.
      local first, last = fleetColumns(layout)
      local summary, properties
      if first then
        summary    = data.fleetTypesText(data.getGroupFleetTypes(instance, groups[group].subordinates))
        properties = { halign = "right" }
      else
        first, last = cargoColumns(layout)
        if first then
          local mouseOver
          summary, mouseOver = data.getGroupCargoText(instance, groups[group].subordinates)
          properties = { halign = "right", mouseOverText = mouseOver }
        end
      end

      if first then
        row[2]:setColSpan(math.max(1, first - 2)):createText(text)
        row[first]:setColSpan(last - first + 1):createText(summary, properties)
      else
        row[2]:setColSpan(layout.total - 1):createText(text)
      end

      if menu.highlightedborderstationcategory == ("subordinates" .. groupKey) then
        menu.sethighlightborderrow = row.index
      end

      if extended then
        data.sortEntries(instance, groups[group].subordinates)
        for i, subordinate in ipairs(groups[group].subordinates) do
          createObjectRow(rowGroup, layout, instance, subordinate.component, iteration + 2, location, i)
        end
      end
    end
  end
end

local function createDockedSection(rowGroup, layout, instance, component, iteration, location, isStation)
  local menu        = eic.menu
  local key         = tostring(component)
  local component64 = ConvertIDTo64Bit(component)
  local dockedShips = menu.infoTableData[instance].dockedships[key] or {}
  local split       = splitColumn(layout)

  if (not menu.isDockedShipsExtended(key)) and menu.isDockContext(component64) then
    menu.extendeddockedships[key] = true
  end
  local extended = menu.isDockedShipsExtended(key, isStation) or flt.forceOpen("docked", key)

  local row = rowGroup:addRow({ "dockedships", component }, { bgColor = Color["row_background_blue"] })
  row[1]:createButton({}):setText(extended and "-" or "+", { halign = "center" })
  row[1].handlers.onClick = function() return menu.buttonExtendDockedShips(key, isStation) end
  row[2]:setColSpan(math.max(1, split - 2)):createText(string.rep("    ", iteration + 1) .. ReadText(1001, 3265))

  -- The summary counts what the block lists, so a filtered dock does not head a short list
  -- with the full tally.
  local playerShips, foreignShips = {}, 0
  for _, docked in ipairs(dockedShips) do
    if flt.visible(instance, layout.view, docked.component) then
      if data.getObjectInfo(instance, docked.component).isPlayerOwned then
        playerShips[#playerShips + 1] = docked
      else
        foreignShips = foreignShips + 1
      end
    end
  end

  -- Player ships are their fleet-type icons in player colour, or the dock icon on a view without
  -- the fleet column; foreign ships are the plain dock icon, absent when the dock holds none.
  local text = ""
  if #playerShips > 0 then
    if fleetColumns(layout) then
      text = data.fleetTypesText(data.getGroupFleetTypes(instance, playerShips),
        menu.holomapcolor.playercolor)
    end
    if text == "" then
      text = Helper.convertColorToText(menu.holomapcolor.playercolor)
          .. "\27[order_dockat] " .. #playerShips .. "\27X"
    end
  end
  if foreignShips > 0 then
    local foreignText = "\27[order_dockat] " .. foreignShips
    text = (text ~= "") and (text .. "  " .. foreignText) or foreignText
  end

  local cargoFirst, cargoLast = cargoColumns(layout)
  if text ~= "" then
    -- On a Trade view the dock count stops short of the cargo column, which takes the summed holds.
    local countLast = (cargoFirst or (layout.total + 1)) - 1
    row[split]:setColSpan(countLast - split + 1):createText(text, { halign = "right" })
  end
  if cargoFirst and (#playerShips > 0) then
    local summary, mouseOver = data.getGroupCargoText(instance, playerShips)
    row[cargoFirst]:setColSpan(cargoLast - cargoFirst + 1):createText(summary,
      { halign = "right", mouseOverText = mouseOver })
  end

  if IsSameComponent(component, menu.highlightedbordercomponent) and (menu.highlightedborderstationcategory == "dockedships") then
    menu.sethighlightborderrow = row.index
  end

  if extended then
    data.sortEntries(instance, dockedShips)
    for i, docked in ipairs(dockedShips) do
      createObjectRow(rowGroup, layout, instance, docked.component, iteration + 2, location, i, true)
    end
  end
end

createObjectRow = function(rowGroup, layout, instance, component, iteration, commanderLocation, index, isDocked)
  local menu          = eic.menu
  local visible, info = flt.visible(instance, layout.view, component)
  if not visible then
    return
  end

  local key          = tostring(component)
  local subordinates = menu.infoTableData[instance].subordinates[key] or {}
  local dockedShips  = menu.infoTableData[instance].dockedships[key] or {}
  if (not menu.isPropertyExtended(key)) and (menu.isCommander(info.id64, 0) or menu.isDockContext(info.id64)) then
    menu.extendedproperty[key] = true
  end

  local ctx = buildContext(instance, layout, component, iteration, index, info)

  -- A fleet row carries the fleet's name, not the leader's, so a filter matching the leader
  -- would stand on a row that shows nothing of what it matched: open it for its own row below.
  local openForLeader = (ctx.kind == "wing") and subordinates.hasRendered and flt.matchedSelf(key)

  -- A ship in a dock block stands for what is sitting in that dock; its own subordinates are
  -- listed where it commands them, not here.
  local hasChildren = flt.hasChildren(key, subordinates, dockedShips, isDocked) or openForLeader
  local extended    = menu.isPropertyExtended(key) or flt.forceOpen("property", key) or openForLeader

  if hasChildren then
    ctx.expand = {
      text    = extended and "-" or "+",
      colors  = expandButtonColors(ctx),
      onClick = function() return menu.buttonExtendProperty(key) end,
    }
  end

  local row = rowGroup:addRow({ "property", component, nil, iteration },
    { bgColor = rowBackground(ctx), multiSelected = menu.isSelectedComponent(component) })
  if (menu.getNumSelectedComponents() == 1) and menu.isSelectedComponent(component) then
    menu.setrow = row.index
  end
  if IsSameComponent(component, menu.highlightedbordercomponent) then
    menu.sethighlightborderrow = row.index
  end

  renderColumns(row, layout, ctx)

  local nameEntry = layout.byId.name
  if (row[1].type == "button") and nameEntry then
    row[1].properties.height = row[nameEntry.first]:getMinTextHeight(false)
  end

  local knownItemClass = KNOWN_ITEM_CLASS[info.className]
  if knownItemClass and info.macro then
    AddKnownItem(knownItemClass, info.macro)
  end

  if extended then
    local location = GetComponentData(component, "sectorid") or commanderLocation

    -- A fleet row names the fleet, so its own ship repeats below it, marked with a star. A
    -- commanded ship expands under its own row and would only duplicate it. The repeat stands
    -- outside the subordinate gate: it is the leader itself, not one of the rows a filter cuts.
    if (ctx.kind == "wing") and subordinates.hasRendered then
      local repeatCtx = {}
      for k, v in pairs(ctx) do repeatCtx[k] = v end
      repeatCtx.kind              = "ship"
      repeatCtx.isCommanderRepeat = true
      repeatCtx.expand            = nil
      if repeatCtx.orderText == "" then
        repeatCtx.orderText, repeatCtx.actionText = data.getOrderText(component)
      end

      local commanderRow = rowGroup:addRow({ "property", component, nil, iteration },
        { bgColor = Color["frame_background_semitransparent"], multiSelected = menu.isSelectedComponent(component) })
      renderColumns(commanderRow, layout, repeatCtx)
    end

    if (not isDocked) and subordinates.hasRendered and flt.subordinatesShown(key) then
      createSubordinateSection(rowGroup, layout, instance, component, iteration, location)
    end

    if (#dockedShips > 0) and flt.dockShown(key) then
      createDockedSection(rowGroup, layout, instance, component, iteration, location, ctx.kind == "station")
    end
  end
end

--- One section over the window `first` to `last`, both indices into its own node list.
local function createSection(ftable, layout, instance, section, first, last)
  local menu  = eic.menu
  local nodes = section.nodes
  layout.sectionId = section.id

  -- A section whose rows all sit on other pages stays off this one, header and all.
  if (#nodes > 0) and (first > last) then
    return
  end

  -- A flat view is one section under a tab that already names it, so it has none.
  if section.name then
    local header = ftable:addRow(false, { bgColor = Color["row_title_background"] })
    header[1]:setColSpan(layout.total):createText(section.name, Helper.headerRowCenteredProperties)
    if section.id == menu.highlightedbordersection then
      menu.sethighlightborderrow = header.index + 1
    end
  end

  local rowGroup = eic.isV9 and ftable:addRowGroup({}) or ftable

  for i = first, last do
    createObjectRow(rowGroup, layout, instance, nodes[i], 0, nil, i)
  end

  if #nodes == 0 then
    local row = rowGroup:addRow(section.id, { bgColor = Color["frame_background_semitransparent"] })
    row[1]:setColSpan(layout.total):createText(section.none, { halign = "center" })
  end
end

--- The header of a name group: the common name where an object row has its name, the sector
--- when every copy shares one, and how many there are where the copies show their hull.
local function createGroupRow(rowGroup, layout, group, index)
  local menu     = eic.menu
  local target   = { kind = "namegroup", key = group.name }
  local expanded = data.isExpanded(target)
  local ctx      = { section = layout.sectionId, index = index, bgColor = Color["row_background"] }

  local row = rowGroup:addRow("namegroup", { bgColor = rowBackground(ctx) })
  row[1]:createButton(expandButtonColors(ctx)):setText(expanded and "-" or "+", { halign = "center" })
  row[1].handlers.onClick = function()
    data.setExpanded(target, not expanded)
    return menu.refreshInfoFrame()
  end

  local nameEntry = layout.byId.name
  local nameCell  = row[nameEntry.first]
  if nameEntry.span > 1 then
    nameCell:setColSpan(nameEntry.span)
  end
  nameCell:createText(group.name, { font = Helper.standardFontBold, color = menu.holomapcolor.playercolor })
  row[1].properties.height = nameCell:getMinTextHeight(false)

  local sectorEntry = layout.byId.sector
  if sectorEntry and group.sector then
    local cell = row[sectorEntry.first]
    if sectorEntry.span > 1 then
      cell:setColSpan(sectorEntry.span)
    end
    cell:createText(group.sector, { halign = "center", color = data.getSectorColor(group.sectorId) })
  end

  local hullEntry = layout.byId.hullBar
  if hullEntry then
    row[hullEntry.first]:createText(tostring(#group.items),
      { halign = "right", font = Helper.standardFontBold, color = menu.holomapcolor.playercolor })
  end
end

--- Deployables listed by what they are: one row per repeated name, its copies under it when open.
--- Its nodes are already the rows, so the window states them directly and a long group can open
--- across a page boundary.
local function createDeployableSection(ftable, layout, instance, section, first, last)
  local nodes = section.nodes
  layout.sectionId = section.id

  if (#nodes > 0) and (first > last) then
    return
  end

  local rowGroup = eic.isV9 and ftable:addRowGroup({}) or ftable

  for i = first, last do
    local node = nodes[i]
    if node.group then
      createGroupRow(rowGroup, layout, node.group, i)
    else
      createObjectRow(rowGroup, layout, instance, node.component, node.member and 1 or 0, nil, i)
    end
  end

  if #nodes == 0 then
    local row = rowGroup:addRow(section.id, { bgColor = Color["frame_background_semitransparent"] })
    row[1]:setColSpan(layout.total):createText(section.none, { halign = "center" })
  end
end

local function createConstructionRow(rowGroup, layout, component, construction, iteration)
  local menu  = eic.menu
  local split = splitColumn(layout)

  local name = ReadText(20109, 5101)
  if construction.component ~= 0 then
    name = ffi.string(C.GetComponentName(construction.component))
  elseif construction.macro ~= "" then
    name = GetMacroData(construction.macro, "name")
    if construction.amount then
      name = construction.amount .. ReadText(1001, 42) .. " " .. name
    end
  end
  name = string.rep("    ", iteration) .. name

  local color = menu.holomapcolor.playercolor
  local row = rowGroup:addRow({ "construction", component, construction },
    { bgColor = Color["frame_background_semitransparent"], multiSelected = menu.isSelectedComponent(construction.component) })
  if menu.highlightedconstruction and (construction.id == menu.highlightedconstruction.id) then
    menu.sethighlightborderrow = row.index
  end
  if (construction.component ~= 0) and IsSameComponent(ConvertStringTo64Bit(tostring(construction.component)), menu.highlightedbordercomponent) then
    menu.sethighlightborderrow = row.index
  end

  local missingText = construction.ismissingresources and ReadText(1026, 3223) or ""
  if construction.inprogress then
    row[1]:setColSpan(split - 1):createText(function()
      return menu.getShipBuildProgress(construction.component,
        name .. " (" .. ffi.string(C.GetObjectIDCode(construction.component)) .. ")")
    end, { color = color, mouseOverText = missingText })
    row[split]:setColSpan(layout.total - split + 1):createText(function()
      return (construction.ismissingresources and "\27Y\27[warning] " or "") ..
          Helper.formatTimeLeft(C.GetBuildProcessorEstimatedTimeLeft(construction.buildercomponent))
    end, { halign = "right", color = color, mouseOverText = missingText })
  else
    local duration = C.GetBuildTaskDuration(construction.buildingcontainer, construction.id)
    row[1]:setColSpan(split - 1):createText(name, { color = color })
    local timeText = construction.amount
        and string.format(ReadText(1001, 11608), Helper.formatTimeLeft(duration))
        or ("#" .. construction.queueposition .. " - " .. Helper.formatTimeLeft(duration))
    row[split]:setColSpan(layout.total - split + 1):createText(timeText, { halign = "right", color = color })
  end
end

local function createConstructionSection(ftable, layout, section)
  if #section.items == 0 then
    return
  end

  local menu = eic.menu
  local header = ftable:addRow(false, { bgColor = Color["row_title_background"] })
  header[1]:setColSpan(layout.total):createText(section.name, Helper.headerRowCenteredProperties)
  if section.id == menu.highlightedbordersection then
    menu.sethighlightborderrow = header.index + 1
  end

  local rowGroup = eic.isV9 and ftable:addRowGroup({}) or ftable
  for _, construction in ipairs(section.items) do
    if construction.empty then
      rowGroup:addEmptyRow(eic.rowHeight / 2)
    else
      createConstructionRow(rowGroup, layout, ConvertStringTo64Bit(tostring(construction.buildingcontainer)), construction, 1)
    end
  end
end

--endregion

--region Sorter row

--- The step a column's button is currently on, nil when the sorter is elsewhere.
local function activeSortStep(def)
  local base = eic.sorterBase(eic.sorterType)
  for i, step in ipairs(eic.sortSteps(def) or {}) do
    if step.key == base then
      return step, i
    end
  end
end

--- One press walks the column's steps: each key ascending, then descending, then the next.
function rows.buttonSorter(def)
  local steps       = eic.sortSteps(def)
  local step, index = activeSortStep(def)

  if step == nil then
    eic.sorterType = steps[1].key
  elseif eic.sorterType == step.key then
    eic.sorterType = step.key .. "Inverse"
  else
    eic.sorterType = steps[(index % #steps) + 1].key
  end
  eic.Debug("sorter set to %s", eic.sorterType)
  eic.menu.refreshInfoFrame()
end

--- One press flips every node the current scope names, so the list opens or closes as a whole.
function rows.buttonExpandAll(targets, expanded)
  for _, target in ipairs(targets) do
    data.setExpanded(target, not expanded)
  end
  eic.Debug("expand all: %d node(s) set to %s", #targets, tostring(not expanded))
  eic.menu.refreshInfoFrame()
end

--- What one row costs the window, counted the way table:getFullHeight counts it, bar the
--- border below the last row: counting that one too leaves a caller short rather than over.
function rows.rowFullHeight(ftable, index)
  local row    = ftable.rows[index]
  local height = row:getHeight()
  if row.properties.borderBelow then
    height = height + Helper.borderSize
  end
  -- Row padding and row groups are 9.0 only: on 8.0 reading the padding logs a widget error
  -- and yields nil, and getFullHeight counts neither.
  if eic.isV9 then
    height = height + row.properties.paddingTop + row.properties.paddingBottom
    -- A row group pads above and below it, and that padding lands on the row opening the group.
    if row.group and ((index == 1) or (ftable.rows[index - 1].group ~= row.group)) then
      height = height + 2 * Helper.standardContainerOffset
    end
  end
  return height
end

--- The first row a selection can land on; the filter row and the sorter row above it are
--- fixed. The view name is not among them - it heads its own table, over the page control.
function rows.firstDataRow()
  return 3
end

--- The whole-list counterpart of a row's own expand button, in the column those sit in.
--- A view without that column - the flat ship tabs - has nothing to unfold and gets none.
local function createExpandAllButton(row, layout, instance, sections, buttonHeight)
  local entry = layout.byId.expand
  if entry == nil then
    return
  end

  local targets = data.expandTargets(instance, layout.view, sections)
  if #targets == 0 then
    return
  end

  local expanded = data.allExpanded(targets)
  local cell     = row[entry.first]
  cell:createButton({
    scaling = false, height = buttonHeight,
    mouseOverText = ReadText(eic.PAGE, expanded and 313 or 312),
  }):setText(expanded and "-" or "+", { halign = "center", scaling = true })
  cell.handlers.onClick = function() return rows.buttonExpandAll(targets, expanded) end
end

--- Generated from the same column list the data rows walk, so a header cannot end up over the
--- wrong column. A column with a sort key becomes a button, one with only a header a label.
local function createSorterRow(ftable, layout, instance, sections)
  local row          = ftable:addRow(true, { fixed = true, bgColor = Color["frame_background_semitransparent"] })
  local buttonHeight = Helper.scaleY(eic.rowHeight)
  local iconHeight   = buttonHeight * 3 / 4

  createExpandAllButton(row, layout, instance, sections, buttonHeight)

  for _, entry in ipairs(layout.entries) do
    local def = entry.def
    if def.header then
      local cell = row[entry.mergedFirst or entry.first]
      local span = entry.mergedSpan or entry.span
      if span > 1 then
        cell:setColSpan(span)
      end

      if def.sort then
        -- The active step names the button, so a multi-step column says which figure it sorts by.
        local step   = activeSortStep(def)
        local button = cell:createButton({ scaling = false, height = buttonHeight })
            :setText((step and step.header) or def.header, { halign = "center", scaling = true })
        local arrow
        if step then
          arrow = (eic.sorterType == step.key) and "table_arrow_inv_down" or "table_arrow_inv_up"
        end
        if arrow then
          button:setIcon(arrow, {
            width = iconHeight, height = iconHeight,
            x = button:getColSpanWidth() - iconHeight, y = (buttonHeight - iconHeight) / 2,
          })
        end
        cell.handlers.onClick = function() return rows.buttonSorter(def) end
      else
        -- A label can end up over a narrow column, so it carries its own text.
        cell:createText(def.header, { halign = "center", font = Helper.standardFontBold, mouseOverText = def.header })
      end
    end
  end
end

--endregion

--region Paging

--- The deployables tab's nodes are the rows themselves, flattened: a name group is not an object
--- and an open one stands for as many rows as it holds, so a page there is a window over what is
--- drawn. A group of one is drawn as the object alone, with no header over it.
local function deployableNodes(section)
  local nodes = {}
  for _, group in ipairs(section.groups) do
    if #group.items == 1 then
      nodes[#nodes + 1] = { component = group.items[1] }
    else
      nodes[#nodes + 1] = { group = group }
      if data.isExpanded({ kind = "namegroup", key = group.name }) then
        for _, component in ipairs(group.items) do
          nodes[#nodes + 1] = { component = component, member = true }
        end
      end
    end
  end
  return nodes
end

--- The top-level nodes each section shows once the filters have had their say, kept on the
--- section: the list a page slices, and the count that tells an empty section from a paged-out one.
local function collectNodes(instance, layout, sections)
  local total = 0
  for _, section in ipairs(sections) do
    if section.kind == "construction" then
      section.nodes = nil
    elseif section.kind == "deployables" then
      section.nodes = deployableNodes(section)
    else
      local nodes = {}
      for _, component in ipairs(section.items) do
        if flt.visible(instance, layout.view, component) then
          nodes[#nodes + 1] = component
        end
      end
      section.nodes = nodes
    end
    total = total + (section.nodes and #section.nodes or 0)
  end
  return total
end

--- What one collapsed top-level row, one section header and one row group cost the window.
--- A header carries vanilla's headerRow1Height, which is taller than a data row of the same scale.
local function pagePitches()
  local pitch  = Helper.scaleY(eic.rowHeight) + Helper.borderSize
  local header = Helper.scaleY(math.max(eic.rowHeight, Helper.headerRow1Height)) + Helper.borderSize
  local group  = eic.isV9 and (2 * Helper.standardContainerOffset) or 0
  return pitch, header, group
end

--- The window left for the sliced rows: the rows already on the table are fixed, and a section
--- with nothing in it draws its header and its "none" row on every page.
local function pageBudget(ftable, sections, pitch, header, group)
  local budget = ftable.properties.maxVisibleHeight or 0

  for i = 1, #ftable.rows do
    budget = budget - rows.rowFullHeight(ftable, i)
  end
  for _, section in ipairs(sections) do
    if section.nodes and (#section.nodes == 0) then
      budget = budget - group - pitch - (section.name and header or 0)
    end
  end

  -- The page's last row draws no border below it, but pitch charges one; without the pixel back
  -- the window loses a whole row to it.
  return budget + Helper.borderSize
end

--- Where each page ends, walked over the whole list: a page takes as many top-level rows as its
--- window holds, paying only for the headers it really opens. The build queue is not sliced and
--- costs nothing here - it follows the last page and scrolls with it, as it did before paging.
local function pageBounds(sections, total, budget, pitch, header, group)
  local bounds, index = {}, 1

  while index <= total do
    local first, passed = index, 0
    ---@type number
    local used = 0

    for _, section in ipairs(sections) do
      local count = (section.nodes and #section.nodes) or 0
      if count > 0 then
        local last = passed + count
        if index <= last then
          local cost = group + (section.name and header or 0)
          -- A header with no room for a row under it belongs on the next page.
          if (index > first) and ((used + cost + pitch) > budget) then
            break
          end
          used = used + cost
          -- The first row of a page goes on it whatever the budget says, or nothing ever fits.
          while (index <= last) and (((used + pitch) <= budget) or (index == first)) do
            used  = used + pitch
            index = index + 1
          end
          if index <= last then
            break
          end
        end
        passed = last
      end
    end

    bounds[#bounds + 1] = index - 1
  end

  if #bounds == 0 then
    bounds[1] = 0
  end
  return bounds
end

-- The selection each tab's page was last steered by, so a page turned by hand stays where it
-- was put until the map's selection actually moves.
local followed = {}

--- Every top-level node's component, indexed the way the page bounds count them. A deployables
--- name group stands for its members rather than for an object and leaves its index empty.
local function nodeComponents(sections)
  local components, index = {}, 0
  for _, section in ipairs(sections) do
    for _, node in ipairs(section.nodes or {}) do
      index = index + 1
      components[index] = (section.kind == "deployables") and node.component or node
    end
  end
  return components
end

--- The node the map's selection stands under: its own row, or the commander or dock whose row
--- opens to show it. Each ancestor test asks the engine, so that pass runs only when no node is
--- the object itself.
local function selectionNode(instance, sections, total)
  local menu       = eic.menu
  local components = nodeComponents(sections)

  for i = 1, total do
    if components[i] and menu.isSelectedComponent(components[i]) then
      return i
    end
  end

  for i = 1, total do
    if components[i] then
      local id64 = data.getObjectInfo(instance, components[i]).id64
      if menu.isCommander(id64, 0) or menu.isDockContext(id64) then
        return i
      end
    end
  end
end

--- Turns the tab to the page its row stands on whenever the map's selection moves, so the row
--- the list is about to mark comes up on screen instead of off the paged-out end.
local function followSelection(instance, sections, bounds, total)
  local selected = eic.singleSelection()
  local previous = followed[eic.viewMode]
  followed[eic.viewMode] = selected

  if (selected == nil) or (selected == previous) then
    return
  end
  -- The list is player property alone, so nothing else on the map can hold a row in it.
  if not GetComponentData(ConvertStringTo64Bit(selected), "isplayerowned") then
    return
  end

  local index = selectionNode(instance, sections, total)
  if index == nil then
    return
  end

  for page, last in ipairs(bounds) do
    if index <= last then
      if eic.setCurrentPage(page) then
        rows.pageFollowed = true
        eic.Debug("page %d follows the map's selection on %s", page, eic.viewMode)
      end
      return
    end
  end
end

--- The window the current page opens on the whole list, and the page count behind it.
local function pageWindow(instance, ftable, sections, total)
  if not eic.pagingOn() then
    return 1, total
  end

  local pitch, header, group = pagePitches()
  local budget = pageBudget(ftable, sections, pitch, header, group)
  local bounds = pageBounds(sections, total, budget, pitch, header, group)

  eic.pageInfo = { size = bounds[1], count = #bounds, total = total }
  followSelection(instance, sections, bounds, total)

  local page = eic.currentPage()
  eic.pages[eic.viewMode] = page
  return ((page > 1) and (bounds[page - 1] + 1) or 1), bounds[page]
end

--endregion

--- The table alone, so the panel can state its geometry before the rows that have to fit it.
function rows.createInfoTable(frame, view, border)
  local layout = rows.resolve(view)
  if layout == nil then
    return nil
  end
  layout.view = view

  local properties = { tabOrder = 1, multiSelect = true }
  if border then
    properties.frameborder = border.id
    properties.x           = Helper.standardContainerOffset
    properties.width       = frame.properties.width - 2 * Helper.standardContainerOffset
  end

  local ftable = frame:addTable(layout.total, properties)
  ftable:setDefaultCellProperties("text", { minRowHeight = eic.rowHeight, fontsize = eic.fontSize })
  ftable:setDefaultCellProperties("button", { height = eic.rowHeight })
  ftable:setDefaultComplexCellProperties("button", "text", { fontsize = eic.fontSize })
  applyColumnWidths(ftable, layout)

  return ftable, layout
end

--- The rows, once the table knows how tall its window is: a page is counted against that.
function rows.fillInfoTable(ftable, layout, instance)
  local view = layout.view

  -- Ahead of the fixed rows: the sorter row's expand button is built from what it collects,
  -- and the filter row from the values the pass over those objects turns up.
  local sections = data.collect(instance, view)
  flt.prepare(instance, layout, sections)

  -- The table's only fixed rows, and numfixedrows is the index of the last of them.
  flt.createRow(ftable, layout)
  createSorterRow(ftable, layout, instance, sections)

  if #sections == 0 then
    local row = ftable:addRow(false, {})
    row[1]:setColSpan(layout.total):createText(ReadText(eic.PAGE, 1000), { halign = "center" })
    return
  end

  local total = collectNodes(instance, layout, sections)
  local first, last = pageWindow(instance, ftable, sections, total)

  local passed = 0
  for _, section in ipairs(sections) do
    if section.kind == "construction" then
      -- The build queue is the tail of the list, so it comes up under its last page.
      if (last >= total) and flt.showConstruction() then
        createConstructionSection(ftable, layout, section)
      end
    else
      local builder = (section.kind == "deployables") and createDeployableSection or createSection
      builder(ftable, layout, instance, section,
        math.max(first - passed, 1), math.min(last - passed, #section.nodes))
      passed = passed + #section.nodes
    end
  end

  eic.Trace("view %s: row(s) %d to %d of %d over %d columns",
    view.category, first, last, total, layout.total)
end

Register_Require_Response("extensions.enhanced_info_center.ui.eic_rows", rows)

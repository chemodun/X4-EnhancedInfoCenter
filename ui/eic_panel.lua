-- Info Center - panel assembly: the two sideBar entries, their frames and the row interaction.
-- The wide left frame replaces menu.infoFrame outright, since Helper.createFrameHandle only
-- builds a detached handle and the vanilla one is dropped before it is displayed.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C   = ffi.C

---@diagnostic disable-next-line: unresolved-require
local eic  = require("extensions.enhanced_info_center.ui.eic_config")
---@diagnostic disable-next-line: unresolved-require
local rows = require("extensions.enhanced_info_center.ui.eic_rows")

ffi.cdef [[
  typedef uint64_t UniverseID;
  typedef uint64_t MissionID;

  const char* GetComponentClass(UniverseID componentid);
  UniverseID GetContextByClass(UniverseID componentid, const char* classname, bool includeself);
  void SetFocusMapComponent(UniverseID holomapid, UniverseID componentid, bool resetplayerpan);
  uint32_t GetNumMapComponentMissions(UniverseID holomapid, UniverseID componentid);
  uint32_t GetMapComponentMissions(MissionID* result, uint32_t resultlen, UniverseID holomapid, UniverseID componentid);
  bool IsComponentClass(UniverseID componentid, const char* classname);
  const char* GetSubordinateGroupAssignment(UniverseID controllableid, int group);
]]

local panel = {
  leftBarDone   = false,
  rightBarDone  = false,
  scrollPatched = false,
}

function panel.createSideBar(mapConfig)
  if panel.leftBarDone then
    return
  end

  local sideBar = mapConfig.leftBar
  local anchor  = eic.isV9 and "objectlist" or "propertyowned"
  local index   = 0
  for i = 1, #sideBar do
    if sideBar[i].mode == eic.MODE then
      return
    end
    if sideBar[i].mode == anchor then
      index = i
    end
  end

  local entry = { name = ReadText(eic.PAGE, 100), icon = eic.icons.sideBar, mode = eic.MODE }
  if index > 0 then
    table.insert(sideBar, index + 1, entry)
  else
    sideBar[#sideBar + 1] = { spacing = true }
    sideBar[#sideBar + 1] = entry
  end

  panel.leftBarDone = true
  eic.Debug("left sideBar entry inserted after %s at %d", anchor, index + 1)
end

function panel.createRightBar(mapConfig)
  if panel.rightBarDone then
    return
  end

  local sideBar = mapConfig.rightBar
  local index   = 0
  for i = 1, #sideBar do
    if sideBar[i].mode == eic.RIGHTMODE then
      return
    end
    if sideBar[i].mode == "info" then
      index = i
    end
  end

  local entry = { name = ReadText(eic.PAGE, 101), icon = eic.icons.options, mode = eic.RIGHTMODE }
  if index > 0 then
    table.insert(sideBar, index, entry)
    table.insert(sideBar, index + 1, { spacing = true })
  else
    sideBar[#sideBar + 1] = { spacing = true }
    sideBar[#sideBar + 1] = entry
  end

  panel.rightBarDone = true
  eic.Debug("right sideBar entry inserted at %d", index)
end

--region Tab bar

-- The strips are our tables, not vanilla's infoTable2/3, so the cursor is ours to carry:
-- `tabs` holds each strip's outgoing position, `pending` the one a tab click demands.
local tabs    = {}
local pending = {}

local function carryTabSelection()
  for key, tab in pairs(tabs) do
    local id = tab.widget and tab.widget.id
    tabs[key] = {
      row = (id and Helper.currentTableRow[id]) or tab.row,
      col = (id and Helper.currentTableCol[id]) or tab.col,
    }
  end
end

--- Where a rebuilt table comes up: a click states the position, a refresh keeps the outgoing one.
local function applyTabSelection(ftable, key)
  local carry = tabs[key] or {}
  local set   = pending[key]
  pending[key] = nil
  ftable:setSelectedRow((set and set.row) or carry.row or 0)
  ftable:setSelectedCol((set and set.col) or carry.col or 0)
  carry.widget = ftable
  tabs[key]    = carry
end

--- Button size shared by every strip, counted in halves: two per tab, one per spacer, one for
--- the leading indent, plus a border between neighbouring columns and tables. `reserved` is
--- what the pager takes off the end of the same line, so the strips can never grow into it.
local function tabButtonWidth(frame, reserved)
  local halves  = 1
  local borders = eic.NUMSTRIPS - 1
  for strip = 1, eic.NUMSTRIPS do
    local entries = eic.stripEntries(strip)
    for _, entry in ipairs(entries) do
      halves = halves + (entry.spacer and 1 or 2)
    end
    borders = borders + #entries + eic.stripFirstColumn(strip) - 2
  end
  local available = frame.properties.width - reserved - borders * Helper.borderSize
  return math.min(eic.menu.sideBarWidth, math.floor(2 * available / halves))
end

--- Where the next strip starts. Floored the way the widget floors each column, or they drift apart.
local function stripWidth(strip, width)
  local entries = eic.stripEntries(strip)
  local first   = eic.stripFirstColumn(strip)
  local total   = (first > 1) and math.floor(width / 2) or 0
  for _, entry in ipairs(entries) do
    total = total + (entry.spacer and math.floor(width / 2) or width)
  end
  return total + (#entries + first - 2) * Helper.borderSize
end

--- The mod name on a table of its own, so the header band is not cut short by the strips' width.
function panel.createTitleBar(frame, border)
  local properties = { tabOrder = 0, reserveScrollBar = false }
  if border then
    properties.frameborder = border.id
  end

  local titleTable = frame:addTable(1, properties)
  local row = titleTable:addRow(false, {
    fixed = true, bgColor = Color["frame_background_black"], borderBelow = false,
  })
  row[1]:createText(ReadText(eic.PAGE, 100),
    eic.isV9 and Helper.tabTitleTextProperties or Helper.headerRowCenteredProperties)

  return titleTable
end

--- One piece of the tab strip. Seventeen cells are past Helper.maxTableCols in a single table,
--- so the strip is two tables side by side at the same y, reading as one unbroken icon row.
function panel.createTabBar(frame, border, strip, width, x, y)
  local entries  = eic.stripEntries(strip)
  local firstCol = eic.stripFirstColumn(strip)
  local numCols  = #entries + firstCol - 1
  if numCols > Helper.maxTableCols then
    eic.Error("tab bar %d needs %d columns, above the cap of %d", strip, numCols, Helper.maxTableCols)
    return nil
  end

  -- The indent before the very first tab, half a button as a group spacer is.
  local half    = math.floor(width / 2)
  local titleBg = Color["frame_background_black"]

  local properties = {
    tabOrder = 1 + strip, reserveScrollBar = false,
    x = x, y = y, width = stripWidth(strip, width),
  }
  if border then
    properties.frameborder = border.id
  end

  local tabTable = frame:addTable(numCols, properties)
  if firstCol > 1 then
    tabTable:setColWidth(1, half, false)
  end
  for i, entry in ipairs(entries) do
    tabTable:setColWidth(firstCol + i - 1, entry.spacer and half or width, false)
  end

  local row = tabTable:addRow("eic_tabs" .. strip, { fixed = true, bgColor = titleBg, borderBelow = false })
  row[1]:setBackgroundColSpan(numCols)
  -- A button cell only reaches the row's own height, so an empty cell carries the padding.
  local padCell
  for i, entry in ipairs(entries) do
    local col = firstCol + i - 1
    if entry.spacer then
      padCell = padCell or row[col]
    else
      local selected = (entry.category == eic.viewMode)
      row[col]:createButton({
        height = width, width = width, x = 0, y = Helper.standardContainerOffset, scaling = false,
        bgColor = selected and Color["row_background_selected"] or Color["row_title_background"],
        mouseOverText = entry.name, active = not entry.pending,
      }):setIcon(entry.icon, { color = Color["icon_normal"] })
      row[col].handlers.onClick = function() return panel.buttonSetView(entry.category) end
    end
  end
  if padCell then
    padCell:createText(" ", { minRowHeight = width + 2 * Helper.standardContainerOffset, scaling = false })
  end

  applyTabSelection(tabTable, strip)

  return tabTable
end

function panel.buttonSetView(category)
  if category == eic.viewMode then
    return
  end

  local menu = eic.menu
  eic.viewMode = category
  -- A sorter the new tab has no column for would keep sorting invisibly.
  if not eic.viewOffersSorter(eic.view(), eic.sorterType) then
    eic.sorterType = "name"
  end
  -- The icons are the strip's first row now that the title has a table of its own.
  local strip, col = eic.stripPosition(category)
  pending[strip] = { row = 1, col = col }

  AddUITriggeredEvent(menu.name, eic.MODE .. "_" .. category)
  eic.Debug("view switched to %s", category)
  menu.refreshInfoFrame()
end

--- Keyboard and gamepad tab scrolling, which vanilla cannot route to a modded panel.
function panel.scrollTab(direction)
  local category = eic.nextView(direction)
  if category then
    panel.buttonSetView(category)
  end
end

--endregion

--region Cursor

-- Vanilla carries row and scroll only for its own panel modes, so every tab's position is ours
-- to keep: `views` holds one cursor per category, restored when that tab comes back up.
local views      = {}
local builtView  = nil -- the view the data table now on screen was built for
local builtTable = nil -- that table, so its live cursor can be read back off it
local selection  = nil -- the map's single selection the list last scrolled to
local pageTurned = false -- the outgoing cursor belongs to the page left behind

--- The one component selected on the map, or nil when it holds none or several.
local function singleSelection()
  local found
  for key in pairs(eic.menu.selectedcomponents or {}) do
    if found then
      return nil
    end
    found = key
  end
  return found
end

--- The outgoing table's live position, kept under the view that built it.
local function carryViewState()
  local id = builtTable and builtTable.id
  if builtView and id and (id == eic.menu.infoTable) then
    if pageTurned then
      views[builtView] = nil
      return
    end
    local state = views[builtView] or {}
    state.row   = Helper.currentTableRow[id] or state.row
    state.top   = GetTopRow(id) or state.top
    views[builtView] = state
  end
end

--- The top row that brings `row` into view. It scrolls up to the row and down only as far as
--- the row needs, so a selection just past the edge does not jump to the top of the window.
local function visibleTopRow(ftable, top, row)
  local numRows = #ftable.rows
  if (row == nil) or (row < 1) or (row > numRows) then
    return top
  end

  -- The fixed rows are always drawn, so their height comes off the scrolling window first.
  local fixed, available = 0, ftable.properties.maxVisibleHeight
  while (fixed < numRows) and ftable.rows[fixed + 1].properties.fixed do
    fixed     = fixed + 1
    available = available - rows.rowFullHeight(ftable, fixed)
  end
  if row <= fixed then
    return top
  end

  top = math.max(top or 0, fixed + 1)
  if row <= top then
    return row
  end

  local height = 0
  for i = row, top, -1 do
    height = height + rows.rowFullHeight(ftable, i)
    if height > available then
      return math.min(i + 1, row)
    end
  end
  return top
end

--- Where the rebuilt list comes up. The row builder states a row when the map's own selection
--- is in the list; a tab click and the panel opening state a new view. Anything else is a plain
--- refresh, which keeps the outgoing position so a rebuild never fights the wheel.
local function applyViewState(ftable, reopened)
  local menu    = eic.menu
  local state   = views[eic.viewMode] or {}
  local row     = math.min(menu.sethighlightborderrow or menu.setrow or state.row or rows.firstDataRow(), #ftable.rows)
  local top     = state.top
  local current = singleSelection()

  if reopened or pageTurned or (builtView ~= eic.viewMode) or (menu.setrow and (current ~= selection)) then
    top = visibleTopRow(ftable, top, row)
  end
  pageTurned = false

  selection  = current
  builtView  = eic.viewMode
  builtTable = ftable
  views[eic.viewMode] = { row = row, top = top }

  ftable:setTopRow(top)
  ftable:setSelectedRow(row)
  eic.Trace("cursor on %s: row=%s top=%s", eic.viewMode, tostring(row), tostring(top))
end

--endregion

--region Pager

local pageEditBox = nil

local function pageText()
  return eic.currentPage() .. " / " .. eic.pageInfo.count
end

--- A page change lands at the top of the new page, so the outgoing cursor is dropped.
local function buttonSetPage(page)
  if not eic.setCurrentPage(page) then
    return false
  end
  pageTurned = true
  eic.Debug("page %d of %d on %s", eic.currentPage(), eic.pageInfo.count, eic.viewMode)
  eic.menu.refreshInfoFrame()
  return true
end

--- Vanilla's editing behaviour: the plain number while typing, the pair back once it is done.
local function pageEditActivated(widget)
  eic.menu.noupdate = true
  if pageEditBox and (widget == pageEditBox.id) then
    C.SetEditBoxText(pageEditBox.id, tostring(eic.currentPage()))
  end
end

local function pageEditDeactivated(_, text)
  local page = tonumber(text)
  eic.menu.noupdate = false
  if ((page == nil) or (not buttonSetPage(page))) and pageEditBox then
    C.SetEditBoxText(pageEditBox.id, pageText())
  end
end

--- One line, stated up front: the list below starts at a height counted before it is built.
--- An arrow row is never shorter than the edit box standing in it.
function panel.pagerHeight()
  local height = Helper.scaleY(eic.rowHeight)
  return (height < Helper.editboxMinHeight) and Helper.editboxMinHeight or height
end

--- The page number's own column, wide enough for the pair at four digits each.
local function pageColumnWidth()
  return math.floor(C.GetTextWidth(" 9999 / 9999 ", Helper.standardFont,
    Helper.scaleFont(Helper.standardFont, eic.fontSize)) + Helper.scaleX(Helper.standardTextOffsetx))
end

--- Stated before the pager is built, since the tab strips give up this much of their line for it.
function panel.pagerWidth()
  return 4 * panel.pagerHeight() + pageColumnWidth() + 4 * Helper.borderSize
end

--- Vanilla's page control - first, previous, the page, next, last - on a table of its own,
--- since a fixed row cannot follow the list's scrolling ones and none of its columns is an
--- arrow's width either. It shares the tab strips' line, flush with the frame's right edge.
function panel.createPager(frame, border, x, y)
  local page      = eic.currentPage()
  local count     = eic.pageInfo.count
  local height    = panel.pagerHeight()
  local width     = height
  local pageWidth = pageColumnWidth()

  local properties = {
    tabOrder = eic.NUMSTRIPS + 2, reserveScrollBar = false,
    x = x, y = y, width = panel.pagerWidth(),
  }
  if border then
    properties.frameborder = border.id
  end

  local pagerTable = frame:addTable(5, properties)
  for _, col in ipairs({ 1, 2, 4, 5 }) do
    pagerTable:setColWidth(col, width, false)
  end
  pagerTable:setColWidth(3, pageWidth, false)

  local row = pagerTable:addRow(true, { fixed = true, borderBelow = false })
  local function arrow(col, icon, active, target)
    row[col]:createButton({
      scaling = false, width = width, height = height,
      active = active, cellBGColor = Color["row_background"],
    }):setIcon(icon)
    row[col].handlers.onClick = function() return buttonSetPage(target) end
  end

  arrow(1, "widget_arrow_skip_left_01", page > 1, 1)
  arrow(2, "widget_arrow_left_01", page > 1, page - 1)
  pageEditBox = row[3]:createEditBox({
    description = ReadText(eic.PAGE, 315), scaling = false, height = height,
  }):setText(pageText(), { halign = "center", fontsize = eic.fontSize, scaling = true })
  row[3].handlers.onEditBoxActivated   = pageEditActivated
  row[3].handlers.onEditBoxDeactivated = pageEditDeactivated
  arrow(4, "widget_arrow_right_01", page < count, page + 1)
  arrow(5, "widget_arrow_skip_right_01", page < count, count)

  applyTabSelection(pagerTable, "pager")

  return pagerTable
end

--endregion

function panel.createInfoFrame()
  local menu = eic.menu
  if menu.infoTableMode ~= eic.MODE then
    return
  end

  -- The outgoing table is still up, so its cursor is read back before anything replaces it.
  -- A table that is not ours means another mode held the frame and the panel is coming back.
  local reopened = (menu.infoTable == nil) or (builtTable == nil) or (builtTable.id ~= menu.infoTable)
  carryViewState()

  local width  = eic.frameWidth(menu, eic.mapConfig)
  local height = Helper.viewHeight - menu.infoTableOffsetY - menu.borderOffset

  ---@diagnostic disable-next-line: assign-type-mismatch
  menu.infoFrame = Helper.createFrameHandle(menu, {
    x = menu.infoTableOffsetX,
    y = menu.infoTableOffsetY,
    width = width,
    height = height,
    layer = eic.mapConfig.infoFrameLayer,
    standardButtons = {},
    showBrackets = false,
    autoFrameHeight = true,
  })
  -- 9.x panels sit in a frame border; 8.x has no frameborder widget at all.
  local border
  if eic.isV9 then
    menu.infoFrame.properties.autoFrameHeightPadding = Helper.standardContainerOffset
    border = menu.infoFrame:addFrameBorder(eic.MODE, {
      offsetBottom = Helper.standardContainerOffset,
      active       = menu.panelState.leftmenu,
      color        = Helper.getFrameBorderColor(menu, menu.panelState.leftmenu, menu.panelPins.leftmenu),
      linewidth    = Helper.getFrameBorderLineWidth(menu, menu.panelState.leftmenu),
    })
    Helper.setFrameBorderIcon(menu, border, "left", menu.sideBarWidth / 2)
  end

  -- Vanilla's panels let their tables carry the background, but that flag is a local of
  -- createInfoFrame and unreachable here, so the frame keeps it and the tables add none.
  menu.infoFrame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

  -- Vanilla stated the margin for the standard panel width before this callback ran.
  if menu.holomap and (menu.holomap ~= 0) then
    C.SetMapStationInfoBoxMargin(menu.holomap, "left",
      menu.infoTableOffsetX + width + eic.mapConfig.contextBorder)
  end

  -- menu.infoTable is bound to the frame's first table, so the data table is created first
  -- even though the title, the strips and the pager sit above it; every y here is explicit.
  local ftable, layout = rows.createInfoTable(menu.infoFrame, eic.view(), border)
  if ftable == nil then
    return
  end

  local contentY = panel.createTitleBar(menu.infoFrame, border):getFullHeight()

  -- The strips share one line, so the data table clears the height of one rather than the sum.
  -- The pager shares it too, at the frame's right edge, and the strips are sized around it.
  carryTabSelection()
  local paging = eic.pagingOn()
  if not paging then
    tabs.pager = nil
  end

  local stripY, stripX = contentY, 0
  local strips = {}
  local buttonWidth = tabButtonWidth(menu.infoFrame, paging and (panel.pagerWidth() + Helper.borderSize) or 0)
  for strip = 1, eic.NUMSTRIPS do
    local tabTable = panel.createTabBar(menu.infoFrame, border, strip, buttonWidth, stripX, stripY)
    if tabTable then
      stripX = stripX + tabTable.properties.width + Helper.borderSize
      strips[#strips + 1] = tabTable
    end
  end

  -- The line is as tall as a strip, or as the pager on it if that is ever the taller of the two.
  local lineHeight = (#strips > 0) and strips[1]:getFullHeight() or 0
  if paging and (lineHeight < panel.pagerHeight()) then
    lineHeight = panel.pagerHeight()
  end
  if lineHeight > 0 then
    contentY = contentY + lineHeight + Helper.standardContainerOffset
  end

  ftable.properties.y = contentY
  ftable.properties.maxVisibleHeight = Helper.viewHeight - contentY - menu.infoFrame.properties.y - Helper.frameBorder

  -- Only the filled list knows its page count, so the pager is built last of all.
  rows.fillInfoTable(ftable, layout, "left")

  local pager
  if paging then
    -- Shorter than a tab button, so it centres on the strips' line, and flush with the
    -- frame's right edge - the strips gave up exactly this much of that line for it.
    local pagerY = stripY + math.floor((lineHeight - panel.pagerHeight()) / 2)
    pager = panel.createPager(menu.infoFrame, border, menu.infoFrame.properties.width - panel.pagerWidth(), pagerY)
  end
  menu.numFixedRows = ftable.numfixedrows

  if menu.infoTable then
    local result = GetShiftStartEndRow(menu.infoTable)
    if result then
      ftable:setShiftStartEnd(table.unpack(result))
    end
  end
  applyViewState(ftable, reopened)

  menu.setrow = nil
  menu.settoprow = nil
  menu.setcol = nil
  menu.sethighlightborderrow = nil

  -- Vanilla cleared the panel's navigation column before this callback ran.
  if menu.playerinfotable then
    menu.playerinfotable:addConnection(1, 2, true)
  end
  local connection = 1
  for _, tabTable in ipairs(strips) do
    connection = connection + 1
    tabTable:addConnection(connection, 2)
  end
  if pager then
    connection = connection + 1
    pager:addConnection(connection, 2)
  end
  ftable:addConnection(connection + 1, 2)

  eic.Trace("info frame built: width=%d height=%d view=%s", width, height, eic.viewMode)
end

--region Options panel

--- Every option is a row filter or geometry read at build time, so a change rebuilds both frames.
local function applyOption(id, value)
  eic.setOption(id, value)
  eic.Debug("option %s set to %s", id, tostring(value))
  eic.menu.refreshInfoFrame()
end

local function createSliderOption(ftable, option)
  local menu  = eic.menu
  local scale = option.scale
  local value = tonumber(eic.getOption(option.id)) or scale.min
  local row   = ftable:addRow(true, {})

  row[1]:setColSpan(2):createSliderCell({
    height = eic.rowHeight,
    min = scale.min, max = scale.max, step = scale.step, suffix = scale.suffix,
    start = math.max(scale.min, math.min(scale.max, value)),
    hideMaxValue = true,
  }):setText(option.name, { fontsize = eic.fontSize })

  -- The drag only stores: rebuilding the frame the slider sits in waits for the release,
  -- and noupdate keeps the map's own refresh off it meanwhile.
  row[1].handlers.onSliderCellActivated = function() menu.noupdate = true end
  row[1].handlers.onSliderCellChanged   = function(_, newValue) eic.setOption(option.id, newValue) end
  row[1].handlers.onSliderCellConfirm   = function(_, newValue, changed)
    menu.noupdate = false
    if changed then
      applyOption(option.id, newValue)
    end
  end
end

local function createCheckBoxOption(ftable, option)
  local size = Helper.scaleY(eic.rowHeight)
  local row  = ftable:addRow(true, {})
  -- A checkbox stretches over its cell without a fixed square size.
  row[1]:createCheckBox(eic.getOption(option.id) and true or false,
    { scaling = false, width = size, height = size, active = true })
  row[1].handlers.onClick = function(_, checked) return applyOption(option.id, checked) end
  row[2]:createText(option.name, { halign = "left" })
end

-- The bar is one info-panel width wide, so the label takes a row and the dropdown the pair below.
local function createDropDownOption(ftable, option)
  local label = ftable:addRow(false, {})
  label[1]:setColSpan(2):createText(option.name, { halign = "left" })

  local row = ftable:addRow(true, {})
  row[1]:setColSpan(2):createDropDown(option.choices, {
    startOption = tostring(eic.getOption(option.id)),
    height = Helper.standardButtonHeight,
    textOverride = "",
  })
  row[1].handlers.onDropDownConfirmed = function(_, id) return applyOption(option.id, id) end
end

function panel.createInfoFrame2(infoFrame2)
  local menu = eic.menu
  if menu.searchTableMode ~= eic.RIGHTMODE then
    return
  end

  local ftable = infoFrame2:addTable(2, {
    tabOrder = 1,
    highlightMode = "off",
    skipTabChange = true,
    multiSelect = false,
    backgroundID = "solid",
    backgroundColor = Helper.color.semitransparent,
  })
  ftable:setColWidth(1, Helper.scaleY(eic.rowHeight), false)
  ftable:setDefaultCellProperties("text", { minRowHeight = eic.rowHeight, fontsize = eic.fontSize })

  local title = ftable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  title[1]:setColSpan(2):createText(ReadText(eic.PAGE, 101), Helper.headerRowCenteredProperties)

  for _, section in ipairs(eic.OPTION_SECTIONS) do
    local header = ftable:addRow(false, { bgColor = Color["row_title_background"] })
    header[1]:setColSpan(2):createText(section.caption, Helper.subHeaderTextProperties)

    for _, option in ipairs(section) do
      if option.choices then
        createDropDownOption(ftable, option)
      elseif option.scale then
        createSliderOption(ftable, option)
      else
        createCheckBoxOption(ftable, option)
      end
    end
  end

  ftable.properties.maxVisibleHeight = Helper.viewHeight - (ftable.properties.y or 0)
      - infoFrame2.properties.y - Helper.frameBorder

  -- The panel rebuilds on every change, so cursor and scroll have to survive a click on its own row.
  ftable:setTopRow(menu.topRows.infotableright)
  ftable:setSelectedRow(menu.selectedRows.infotableright)
  ftable:setSelectedCol(menu.selectedCols.infotableright or 0)
  menu.topRows.infotableright      = nil
  menu.selectedRows.infotableright = nil
  menu.selectedCols.infotableright = nil

  eic.Trace("options frame built")
  -- Without this kuertee wipes the frame and appends an empty table.
  return true
end

--endregion

--region Row interaction

function panel.onRowChanged(row, rowData, uiTable, modified, input, source)
  local menu = eic.menu
  if (menu.infoTableMode ~= eic.MODE) or (uiTable ~= menu.infoTable) or (type(rowData) ~= "table") then
    return
  end

  local component = ConvertIDTo64Bit(rowData[2])
  if (source ~= "auto") and (component ~= 0) then
    local className = ffi.string(C.GetComponentClass(component))
    if className == "station" then
      AddUITriggeredEvent(menu.name, "selection_station", component)
    elseif (className == "ship_s") or (className == "ship_m") or (className == "ship_l") or (className == "ship_xl") then
      AddUITriggeredEvent(menu.name, "selection_ship", component)
    elseif className == "resourceprobe" then
      AddUITriggeredEvent(menu.name, "selection_resourceprobe", component)
    end

    if (menu.mode ~= "orderparam_object") and (input ~= "rightmouse") then
      menu.infoSubmenuObject = component
      if menu.searchTableMode == "info" then
        menu.refreshInfoFrame2(nil, 0)
      end
    end
  end

  menu.updateSelectedComponents(modified, source == "auto", component, row)
  menu.setSelectedMapComponents()
end

function panel.onSelectElement(uiTable, modified, _row, isDblClick, input)
  local menu = eic.menu
  if (menu.infoTableMode ~= eic.MODE) or (uiTable ~= menu.infoTable) then
    return
  end

  local rowData = Helper.getCurrentRowData(menu, uiTable)
  if type(rowData) ~= "table" then
    return
  end

  local component = ConvertIDTo64Bit(rowData[2])
  menu.setSelectedMapComponents()
  if (component == 0) or (not (isDblClick or (input ~= "mouse"))) then
    return
  end
  if ffi.string(C.GetComponentClass(component)) == "sector" then
    return
  end

  if string.find(rowData[1], "subordinates") then
    -- Focus the whole assignment group the row stands for.
    local subordinates = (menu.infoTableData.left.subordinates or {})[tostring(rowData[2])] or {}
    local group = {}
    for _, subordinate in ipairs(subordinates) do
      if subordinate.component and (GetComponentData(subordinate.component, "subordinategroup") == rowData[3]) then
        group[#group + 1] = subordinate
      end
    end
    if #group > 0 then
      C.SetFocusMapComponent(menu.holomap, ConvertIDTo64Bit(group[1].component), true)
      menu.addSelectedComponents(group, modified ~= "shift")
    end
    return
  end

  local isOnlineObject, isPlayerOwned = GetComponentData(rowData[2], "isonlineobject", "isplayerowned")
  if isPlayerOwned and isOnlineObject then
    local assignedDock = ConvertIDTo64Bit(GetComponentData(component, "assigneddock"))
    if assignedDock ~= 0 then
      local container = C.GetContextByClass(assignedDock, "container", false)
      if container ~= 0 then
        C.SetFocusMapComponent(menu.holomap, container, true)
      end
    end
  else
    C.SetFocusMapComponent(menu.holomap, component, true)
  end
end

function panel.onRenderTargetSelect(_modified)
  if eic.menu.infoTableMode == eic.MODE then
    eic.menu.refreshInfoFrame()
  end
end

function panel.onTableRightMouseClick(uiTable, row, posX, posY)
  local menu = eic.menu
  if menu.mode == "orderparam_position" then
    return
  end
  if (menu.infoTableMode ~= eic.MODE) or (uiTable ~= menu.infoTable) or (row <= (menu.numFixedRows or 0)) then
    return
  end

  local rowData = menu.rowDataMap[uiTable] and menu.rowDataMap[uiTable][row]
  if type(rowData) ~= "table" then
    return
  end
  local component = ConvertIDTo64Bit(rowData[2])
  if component == 0 then
    return
  end

  -- The pick modes answer with their own context frame instead of the interact menu.
  local x, y = GetLocalMousePosition()
  local function openSelectFrame()
    menu.contextMenuData = { component = component, xoffset = x + Helper.viewWidth / 2, yoffset = Helper.viewHeight / 2 - y }
    menu.contextMenuMode = "select"
    menu.createContextFrame(menu.selectWidth)
  end

  if menu.mode == "hire" then
    if GetComponentData(component, "isplayerowned") and C.IsComponentClass(component, "controllable") then
      openSelectFrame()
    end
    return
  elseif menu.mode == "selectCV" then
    openSelectFrame()
    return
  elseif menu.mode == "orderparam_object" then
    if menu.checkForOrderParamObject(component) then
      openSelectFrame()
    end
    return
  elseif menu.mode == "selectComponent" then
    if menu.checkForSelectComponent(component) then
      openSelectFrame()
    end
    return
  end

  local missions = {}
  Helper.ffiVLA(missions, "MissionID", C.GetNumMapComponentMissions, C.GetMapComponentMissions, menu.holomap, component)
  local playerShips, otherObjects, playerDeployables = menu.getSelectedComponentCategories()

  -- Helper.openInteractMenu reads vanilla's own key names off this table.
  local params = {
    component = component, playerships = playerShips, otherobjects = otherObjects,
    playerdeployables = playerDeployables, mouseX = posX, mouseY = posY, componentmissions = missions,
  }
  if rowData[1] == "construction" then
    params.construction = rowData[3]
  elseif string.find(rowData[1], "subordinates") then
    params.subordinategroup = rowData[3]
  end

  menu.interactMenuComponent = component
  Helper.openInteractMenu(menu, params)
end

--endregion

local function Init()
  local menu = Helper.getMenu("MapMenu")
  if menu == nil or type(menu.registerCallback) ~= "function" then
    eic.Error("MapMenu unavailable - kuertee UI Extensions not loaded?")
    return
  end

  eic.menu      = menu
  eic.mapConfig = menu.uix_getConfig()
  eic.rowHeight = eic.mapConfig.mapRowHeight or Helper.standardTextHeight
  eic.fontSize  = eic.mapConfig.mapFontSize or Helper.standardFontSize

  menu.registerCallback("createSideBar_on_start", panel.createSideBar)
  menu.registerCallback("createRightBar_on_start", panel.createRightBar)
  menu.registerCallback("createInfoFrame_on_menu_infoTableMode", panel.createInfoFrame)
  menu.registerCallback("createInfoFrame2_on_menu_infoModeRight", panel.createInfoFrame2)
  menu.registerCallback("ic_onRowChanged", panel.onRowChanged)
  menu.registerCallback("ic_onSelectElement", panel.onSelectElement)
  menu.registerCallback("ic_onTableRightMouseClick", panel.onTableRightMouseClick)
  menu.registerCallback("onRenderTargetSelect_on_leave", panel.onRenderTargetSelect)

  -- The one gap kuertee leaves: scrollPanelTab dispatches on a fixed list of infoTableMode values.
  if (not panel.scrollPatched) and (type(menu.scrollPanelTab) == "function") then
    panel.scrollPatched = true
    local vanillaScrollPanelTab = menu.scrollPanelTab
    menu.scrollPanelTab = function(direction)
      if menu.panelState.leftmenu and (menu.infoTableMode == eic.MODE) then
        return panel.scrollTab(direction)
      end
      return vanillaScrollPanelTab(direction)
    end
  end

  eic.Debug("panel init: rowHeight=%s fontSize=%s scrollPatched=%s",
    tostring(eic.rowHeight), tostring(eic.fontSize), tostring(panel.scrollPatched))
end

Register_OnLoad_Init(Init, "extensions.enhanced_info_center.ui.eic_panel")

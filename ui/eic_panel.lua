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

--- Where a rebuilt table comes up: a click states the position, a refresh keeps the outgoing
--- one. `buttons` names the columns the engine will take as the interactive cell - the window
--- moves under the cursor and an arrow goes inactive at the end of the strip, so a carried
--- column is pulled onto the nearest of them rather than onto whatever now stands there.
local function applyTabSelection(ftable, key, buttons)
  local carry = tabs[key] or {}
  local set   = pending[key]
  pending[key] = nil

  local col = (set and set.col) or carry.col or 0
  if (col > 0) and buttons then
    local nearest = 0
    for _, button in ipairs(buttons) do
      if (nearest == 0) or (math.abs(button - col) < math.abs(nearest - col)) then
        nearest = button
      end
    end
    col = nearest
  end

  -- Both tables this serves hold a single row, so a column without one would be a dead cursor.
  local row = (set and set.row) or carry.row or 0
  ftable:setSelectedRow(((col > 0) and (row < 1)) and 1 or row)
  ftable:setSelectedCol(col)
  carry.widget = ftable
  tabs[key]    = carry
end

-- The window over eic.VIEWS: `tabOffset` is the first cell on screen. The button keeps vanilla's
-- size whatever the frame width is, so a strip too long for the frame is reached with the two
-- arrow cells rather than by shrinking the button - and with it the strip's height.
local tabOffset       = 1
local ensureTabInView = true
local pendingCategory = nil

--- Half a button is what a group spacer, the leading indent and an arrow cell each take.
local function tabCellWidth(entry, width)
  return entry.spacer and math.floor(width / 2) or width
end

--- A group spacer never opens the window, so a step lands on the next tab in that direction.
local function tabCellStep(index, step)
  while eic.VIEWS[index] and eic.VIEWS[index].spacer do
    index = index + step
  end
  return index
end

--- What a window of cells costs. A scrolling strip carries two columns beyond its cells: the
--- trailing arrow, and the filler in front of it that has no width of its own. Every piece is
--- counted with a height cell even where a group spacer ends up carrying that, and N columns
--- cost N-1 borders however they are cut - both a few pixels to the good, never short.
local function windowWidth(layout, first, last, scroll)
  local content = 1 + (last - first + 1) + (scroll and 2 or 0)
  local tables  = math.ceil(content / (Helper.maxTableCols - 2))
  local total   = layout.half + (scroll and layout.half or 0) + tables * layout.pad
  for i = first, last do
    total = total + tabCellWidth(eic.VIEWS[i], layout.width)
  end
  return total + (content + tables - 1) * Helper.borderSize
end

--- Where the window sits at this frame width, and whether the arrows are needed at all.
local function tabLayout(frame)
  local count  = #eic.VIEWS
  local width  = math.floor(eic.menu.sideBarWidth)
  local layout = { width = width, half = math.floor(width / 2), pad = Helper.borderSize }
  local avail  = frame.properties.width

  -- Everything on screen: the leading half cell stays the plain indent it has always been.
  if windowWidth(layout, 1, count, false) <= avail then
    layout.first, layout.last = 1, count
    ensureTabInView = false
    return layout
  end
  layout.scroll = true

  -- At least one cell is shown even where none fits, so a narrow frame is a strip, not two arrows.
  local function fitFrom(first)
    local last = first
    while (last < count) and (windowWidth(layout, first, last + 1, true) <= avail) do
      last = last + 1
    end
    return last
  end

  -- The furthest the window may be scrolled; one step past it would show empty space.
  local lastStart = count
  while (lastStart > 1) and (fitFrom(lastStart - 1) >= count) do
    lastStart = lastStart - 1
  end
  lastStart = math.min(tabCellStep(lastStart, 1), count)

  local first = tabCellStep(math.max(1, math.min(tabOffset, lastStart)), 1)

  -- The tab the player just picked, or the one the panel opens on, is pulled into the window.
  local index = ensureTabInView and eic.viewIndex(eic.viewMode)
  if index then
    if index < first then
      first = index
    else
      while (first < index) and (fitFrom(first) < index) do
        first = tabCellStep(first + 1, 1)
      end
    end
  end
  ensureTabInView = false

  tabOffset    = first
  layout.first = first
  layout.last  = fitFrom(first)
  return layout
end

--- The window as columns: the leading half cell, the cells themselves and, when the strip
--- scrolls, the trailing arrow with a filler in front of it that states no width and so takes
--- whatever the cells left over. Cut into evenly sized pieces of at most Helper.maxTableCols
--- columns, so the arrow and its filler are never left as a piece of their own. The seam is a
--- plain border, the same the columns are set apart by, so where it falls does not show.
local function tabColumns(layout)
  local cols = { { lead = true } }
  for i = layout.first, layout.last do
    cols[#cols + 1] = { entry = eic.VIEWS[i] }
  end
  if layout.scroll then
    cols[#cols + 1] = { filler = true }
    cols[#cols + 1] = { arrow = "right" }
  end

  -- Only the leading indent may draw nothing; the engine refuses a table whose first column
  -- holds no widget, and the cursor lands there whenever the window has moved under it.
  local function opensPiece(col)
    return col.lead or col.arrow or (col.entry and (not col.entry.spacer))
  end

  -- Cut from the back, so the filler and the arrow behind it are always in the piece that is
  -- stretched to the frame - a piece without the filler has no column to give the slack to and
  -- the engine shrinks it to its content. Two columns of headroom each: the one a seam hands
  -- back, and a height cell where the piece has no group spacer to state it.
  local count  = math.ceil(#cols / (Helper.maxTableCols - 2))
  local starts = {}
  local ending = #cols
  for piece = count, 1, -1 do
    local start = (piece == 1) and 1 or math.max(1, ending - math.ceil(ending / piece) + 1)
    -- A piece opens on a cell that draws something, so an empty one closes the piece before it.
    while (start > 1) and (not opensPiece(cols[start])) do
      start = start - 1
    end
    starts[piece] = start
    ending = start - 1
  end

  local tables = {}
  for piece = 1, count do
    local first = starts[piece]
    local last  = (piece < count) and (starts[piece + 1] - 1) or #cols

    local part = {}
    for j = first, last do
      part[#part + 1] = cols[j]
    end

    -- A button cell only reaches the row's own height, so one empty cell of each piece states
    -- it: a group spacer, the filler, or the leading indent where no arrow stands on it. A
    -- piece holding none gets a narrow cell of its own, which is what keeps the seam clear.
    local carrier
    for _, col in ipairs(part) do
      if (col.entry and col.entry.spacer) or col.filler or (col.lead and (not layout.scroll)) then
        carrier = col
        break
      end
    end
    if carrier then
      carrier.rowHeight = true
    else
      part[#part + 1] = { pad = true, rowHeight = true }
    end

    tables[#tables + 1] = part
  end
  return tables
end

local function tabColWidth(layout, col)
  if col.filler then
    return 0
  elseif col.pad then
    return layout.pad
  elseif col.lead or col.arrow then
    return layout.half
  end
  return tabCellWidth(col.entry, layout.width)
end

--- A table's own width: its columns, plus a border between neighbouring ones.
local function stripWidth(layout, cols)
  local width = -Helper.borderSize
  for _, col in ipairs(cols) do
    width = width + tabColWidth(layout, col) + Helper.borderSize
  end
  return width
end

local function buttonScrollTabs(step)
  local first = tabCellStep(tabOffset + step, step)
  if (first < 1) or (first > #eic.VIEWS) then
    return
  end
  tabOffset = first
  eic.Debug("tab strip scrolled to cell %d", first)
  eic.menu.refreshInfoFrame()
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

--- One piece of the tab strip, drawn at the same y as its neighbour so the pieces read as one
--- unbroken icon row. A window wider than Helper.maxTableCols columns cannot be a single table.
function panel.createTabBar(frame, border, index, layout, cols, x, y, width)
  local properties = {
    tabOrder = 1 + index, reserveScrollBar = false,
    x = x, y = y, width = width,
  }
  if border then
    properties.frameborder = border.id
  end

  local tabTable = frame:addTable(#cols, properties)
  for i, col in ipairs(cols) do
    -- The filler states no width, so it is handed what the columns that do have one left over.
    if not col.filler then
      tabTable:setColWidth(i, tabColWidth(layout, col), false)
    end
  end

  local row = tabTable:addRow("eic_tabs" .. index, {
    fixed = true, bgColor = Color["frame_background_black"], borderBelow = false,
  })
  row[1]:setBackgroundColSpan(#cols)

  -- Every column the cursor may come up on: an inactive button is not one of them.
  local buttons = {}

  local function arrow(cell, icon, active, step)
    cell:createButton({
      height = layout.width, width = layout.half, x = 0, y = Helper.standardContainerOffset,
      scaling = false, bgColor = Color["row_title_background"], active = active,
    }):setIcon(icon, {
      color = Color["icon_normal"], scaling = false,
      width = layout.half, height = layout.half,
      y = math.floor((layout.width - layout.half) / 2),
    })
    cell.handlers.onClick = function() return buttonScrollTabs(step) end
  end

  for i, col in ipairs(cols) do
    if col.rowHeight then
      row[i]:createText(" ", {
        fontsize = 1, x = 0, scaling = false,
        minRowHeight = layout.width + 2 * Helper.standardContainerOffset,
      })
    elseif col.lead then
      if layout.scroll then
        local active = layout.first > 1
        arrow(row[i], "widget_arrow_left_01", active, -1)
        if active then
          buttons[#buttons + 1] = i
        end
      end
    elseif col.arrow then
      local active = layout.last < #eic.VIEWS
      arrow(row[i], "widget_arrow_right_01", active, 1)
      if active then
        buttons[#buttons + 1] = i
      end
    elseif col.entry and (not col.entry.spacer) then
      local entry    = col.entry
      local selected = (entry.category == eic.viewMode)
      row[i]:createButton({
        height = layout.width, width = layout.width, x = 0, y = Helper.standardContainerOffset,
        scaling = false,
        bgColor = selected and Color["row_background_selected"] or Color["row_title_background"],
        mouseOverText = entry.name, active = not entry.pending,
      }):setIcon(entry.icon, { color = Color["icon_normal"] })
      row[i].handlers.onClick = function() return panel.buttonSetView(entry.category) end
      if not entry.pending then
        buttons[#buttons + 1] = i
      end
      -- The tab a click asked for lands on whichever table ended up drawing it.
      if entry.category == pendingCategory then
        pending[index] = { row = 1, col = i }
      end
    end
  end

  applyTabSelection(tabTable, index, buttons)

  return tabTable
end

--- The whole strip: the window over the tab cells, cut into tables side by side at one y.
function panel.createTabBars(frame, border, y)
  local layout = tabLayout(frame)
  local pieces = tabColumns(layout)
  local strips = {}
  ---@type number
  local x = 0

  for index, cols in ipairs(pieces) do
    -- A scrolling strip is stretched to the frame's edge, so its arrow stands flush right and
    -- the filler in front of it swallows what the last tab that fitted left over.
    local width = stripWidth(layout, cols)
    if layout.scroll and (index == #pieces) then
      width = frame.properties.width - x
    end

    strips[#strips + 1] = panel.createTabBar(frame, border, index, layout, cols, x, y, width)
    x = x + width + Helper.borderSize
  end
  pendingCategory = nil

  -- A window that shrank leaves behind the cursor of a table that is no longer built.
  for key in pairs(tabs) do
    if (type(key) == "number") and (key > #strips) then
      tabs[key] = nil
    end
  end

  return strips
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
  pendingCategory = category
  ensureTabInView = true

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

--region View title and pager

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

--- Every page widget is built at this height, never at the row's, since the title sets that.
--- An arrow is never shorter than the edit box standing beside it.
function panel.pagerHeight()
  local height = Helper.scaleY(eic.rowHeight)
  return (height < Helper.editboxMinHeight) and Helper.editboxMinHeight or height
end

--- The page number's own column, wide enough for the pair at four digits each.
local function pageColumnWidth()
  return math.floor(C.GetTextWidth(" 9999 / 9999 ", Helper.standardFont,
    Helper.scaleFont(Helper.standardFont, eic.fontSize)) + Helper.scaleX(Helper.standardTextOffsetx))
end

--- The view name heads the list on a table of its own, between the strips and the list, since
--- a fixed row cannot follow scrolling ones in the list's table and none of the list's columns
--- is an arrow's width. The title takes the table when paging is off and gives up the five
--- right-hand columns to the page control when it is on.
function panel.createViewTitle(frame, border, y, paging, numStrips)
  local titleProperties = Helper.subTabTitleTextProperties or Helper.headerRowCenteredProperties
  local numCols         = paging and 6 or 1

  -- The scroll bar is reserved the way the list below reserves it, so the title centres over
  -- the same width the list's rows have and the page control ends on its last column.
  local properties = { tabOrder = paging and (numStrips + 2) or 0, y = y }
  if border then
    properties.frameborder = border.id
    properties.x           = Helper.standardContainerOffset
    properties.width       = frame.properties.width - 2 * Helper.standardContainerOffset
  end

  local titleTable = frame:addTable(numCols, properties)
  if paging then
    local arrowWidth = panel.pagerHeight()
    for _, col in ipairs({ 2, 3, 5, 6 }) do
      titleTable:setColWidth(col, arrowWidth, false)
    end
    titleTable:setColWidth(4, pageColumnWidth(), false)
  end

  -- The page cells are filled in once the list has been built, so the title has to state the
  -- row's height before them, and never under a page widget's. minRowHeight is a raw value,
  -- so the edit box's pixel floor is carried back through the scale to be compared with one.
  local title = {}
  for key, value in pairs(titleProperties) do
    ---@diagnostic disable-next-line: assign-type-mismatch
    title[key] = value
  end
  local floor = paging and math.ceil(Helper.editboxMinHeight / Helper.uiScale) or 0
  title.minRowHeight = math.max(title.minRowHeight or 0, paging and eic.rowHeight or 0, floor)

  local row = titleTable:addRow(paging, { fixed = true, bgColor = title.cellBGColor })
  row[1]:createText(eic.view().name, title)

  if paging then
    applyTabSelection(titleTable, "pager")
  end

  return titleTable, row
end

--- Vanilla's page control - first, previous, the page, next, last - in the columns the title
--- gave up. Built after the list, since only the filled list knows its page count.
function panel.fillPager(row)
  local page   = eic.currentPage()
  local count  = eic.pageInfo.count
  local height = panel.pagerHeight()
  -- The row stands at the title's height, which the title stated to be at least this one,
  -- so every page widget is centred on it by hand.
  local offsetY = math.max(0, math.floor((row:getHeight() - height) / 2))

  local function arrow(col, icon, active, target)
    row[col]:createButton({
      scaling = false, width = height, height = height, y = offsetY, active = active,
    }):setIcon(icon)
    row[col].handlers.onClick = function() return buttonSetPage(target) end
  end

  arrow(2, "widget_arrow_skip_left_01", page > 1, 1)
  arrow(3, "widget_arrow_left_01", page > 1, page - 1)
  pageEditBox = row[4]:createEditBox({
    description = ReadText(eic.PAGE, 315), scaling = false, height = height, y = offsetY,
  }):setText(pageText(), { halign = "center", fontsize = eic.fontSize, scaling = true })
  row[4].handlers.onEditBoxActivated   = pageEditActivated
  row[4].handlers.onEditBoxDeactivated = pageEditDeactivated
  arrow(5, "widget_arrow_right_01", page < count, page + 1)
  arrow(6, "widget_arrow_skip_right_01", page < count, count)
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
  -- even though the header band, the strips and the view title sit above it; every y is explicit.
  local ftable, layout = rows.createInfoTable(menu.infoFrame, eic.view(), border)
  if ftable == nil then
    return
  end

  local contentY = panel.createTitleBar(menu.infoFrame, border):getFullHeight()

  -- The strips share one line, so the data table clears the height of one rather than the sum.
  -- A panel coming back up shows the tab it is on, wherever the window was left standing.
  carryTabSelection()
  ensureTabInView = ensureTabInView or reopened
  local paging = eic.pagingOn()
  if not paging then
    tabs.pager = nil
  end

  local strips = panel.createTabBars(menu.infoFrame, border, contentY)

  local lineHeight = (#strips > 0) and strips[1]:getFullHeight() or 0
  if lineHeight > 0 then
    contentY = contentY + lineHeight + Helper.standardContainerOffset
  end

  -- The view name and the page control share the line right above the list, so the list's
  -- window is what is left under a row that is already standing at its full height.
  local titleTable, titleRow = panel.createViewTitle(menu.infoFrame, border, contentY, paging, #strips)
  contentY = contentY + titleTable:getFullHeight()

  ftable.properties.y = contentY
  ftable.properties.maxVisibleHeight = Helper.viewHeight - contentY - menu.infoFrame.properties.y - Helper.frameBorder

  rows.fillInfoTable(ftable, layout, "left")

  -- Only the filled list knows its page count, so the page control is the last thing built.
  if paging then
    panel.fillPager(titleRow)
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
  if paging then
    connection = connection + 1
    titleTable:addConnection(connection, 2)
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
  -- A cap is a live geometry limit; a stored value above it comes down with the slider's own ceiling.
  local top   = scale.cap and scale.cap() or scale.max
  local value = tonumber(eic.getOption(option.id)) or scale.min
  local start = math.max(scale.min, math.min(top, value))
  if start ~= value then
    eic.setOption(option.id, start)
  end
  local row = ftable:addRow(true, {})

  row[1]:setColSpan(2):createSliderCell({
    height = eic.rowHeight,
    min = scale.min, max = top, step = scale.step, suffix = scale.suffix,
    start = start,
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

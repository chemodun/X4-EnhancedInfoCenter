-- Info Center - object collection, row filters and per-refresh caches.
-- One pass over the player's property fills the buckets the row builder walks;
-- every per-object lookup is cached for the life of one refresh.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C   = ffi.C

---@diagnostic disable-next-line: unresolved-require
local eic = require("extensions.enhanced_info_center.ui.eic_config")

ffi.cdef [[
  typedef uint64_t UniverseID;
  typedef uint64_t BuildTaskID;
  typedef uint64_t AIOrderID;

  typedef struct {
    BuildTaskID id;
    UniverseID buildingcontainer;
    UniverseID component;
    const char* macro;
    const char* factionid;
    UniverseID buildercomponent;
    int64_t price;
    bool ismissingresources;
    uint32_t queueposition;
  } BuildTaskInfo;

  const char* GetComponentClass(UniverseID componentid);
  const char* GetComponentName(UniverseID componentid);
  const char* GetFleetName(UniverseID controllableid);
  const char* GetObjectIDCode(UniverseID objectid);
  const char* GetSubordinateGroupAssignment(UniverseID controllableid, int group);
  uint32_t GetNumDockedShips(UniverseID dockingbayorcontainerid, const char* factionid);
  uint32_t GetDockedShips(UniverseID* result, uint32_t resultlen, UniverseID dockingbayorcontainerid, const char* factionid);
  uint32_t GetNumPlayerShipBuildTasks(bool isinprogress, bool includeupgrade);
  uint32_t GetPlayerShipBuildTasks(BuildTaskInfo* result, uint32_t resultlen, bool isinprogress, bool includeupgrade);
  double GetBuildTaskDuration(UniverseID containerid, BuildTaskID id);
  double GetBuildProcessorEstimatedTimeLeft(UniverseID buildprocessorid);
  bool FilterComponentByText(UniverseID componentid, uint32_t numtexts, const char** textarray, bool includecontainedobjects);
  bool IsUICoverOverridden(void);
  UniverseID GetPlayerOccupiedShipID(void);
  bool IsRealComponentClass(UniverseID componentid, const char* classname);

  typedef struct {
    const char* name;
    const char* transport;
    uint32_t spaceused;
    uint32_t capacity;
  } StorageInfo;

  typedef struct {
    const char* id;
    const char* name;
    const char* icon;
    const char* description;
    const char* category;
    const char* categoryname;
    bool infinite;
    uint32_t requiredSkill;
  } OrderDefinition;

  typedef struct {
    size_t queueidx;
    const char* state;
    const char* statename;
    const char* orderdef;
    size_t actualparams;
    bool enabled;
    bool isinfinite;
    bool issyncpointreached;
    bool istemporder;
  } Order;

  typedef struct {
    size_t queueidx;
    const char* state;
    const char* statename;
    const char* orderdef;
    size_t actualparams;
    bool enabled;
    bool isinfinite;
    bool issyncpointreached;
    bool istemporder;
    bool isoverride;
  } Order2;

  typedef struct {
    uint32_t id;
    AIOrderID orderid;
    const char* orderdef;
    const char* message;
    double timestamp;
    bool wasdefaultorder;
    bool wasinloop;
  } OrderFailure;

  uint32_t GetNumCargoTransportTypes(UniverseID containerid, bool merge);
  uint32_t GetCargoTransportTypes(StorageInfo* result, uint32_t resultlen, UniverseID containerid, bool merge, bool aftertradeorders);
  int32_t GetShipCombinedSkill(UniverseID shipid);
  uint32_t GetNumOrders(UniverseID controllableid);
  uint32_t GetOrders2(Order2* result, uint32_t resultlen, UniverseID controllableid);
  size_t GetOrderQueueCurrentIdx(UniverseID controllableid);
  bool GetDefaultOrder(Order* result, UniverseID controllableid);
  bool GetOrderDefinition(OrderDefinition* result, const char* orderdef);
  uint32_t GetNumOrderFailures(UniverseID controllableid, bool includelooporders);
  uint32_t GetOrderFailures(OrderFailure* result, uint32_t resultlen, UniverseID controllableid, bool includelooporders);
  bool GetDefaultOrderFailure(OrderFailure* result, UniverseID controllableid);
]]

local data = {
  orderInfo      = {},
  sectorColors   = {},
  rowFilterScan  = {},
  -- Name groups start closed and stay as the player leaves them, the way vanilla's own
  -- expansion tables live for the UI session rather than for one opening of the map.
  expandedGroups = {},
}

-- Right-bar option that governs each kind of row.
local DEPLOYABLE_OPTION = {
  mine          = "mines",
  navbeacon     = "navBeacons",
  resourceprobe = "resourceProbes",
  satellite     = "satellites",
  lockbox       = "lockboxes",
}

-- A spacesuit is a class of its own, not a ship_xs, so it needs an entry of its own.
local SHIPCLASS_OPTION = {
  ship_s    = "classS",
  ship_m    = "classM",
  ship_l    = "classL",
  ship_xl   = "classXL",
  ship_xs   = "roleSpacesuit",
  spacesuit = "roleSpacesuit",
}

local ROLE_OPTION = {
  fight       = "roleFight",
  trade       = "roleTrade",
  mine        = "roleMine",
  build       = "roleBuild",
  auxiliary   = "roleResupply",
  salvage     = "roleTug",
  dismantling = "roleRecycling",
  racing      = "roleRacing",
}

-- Subordinate group assignment names, as the order menu titles them.
local ASSIGNMENTS = {
  defence              = ReadText(20208, 40301),
  positiondefence      = ReadText(20208, 41501),
  attack               = ReadText(20208, 40901),
  interception         = ReadText(20208, 41001),
  bombardment          = ReadText(20208, 41601),
  follow               = ReadText(20208, 41301),
  supplyfleet          = ReadText(20208, 40701),
  mining               = ReadText(20208, 40201),
  trade                = ReadText(20208, 40101),
  tradeforbuildstorage = ReadText(20208, 40801),
  assist               = ReadText(20208, 41201),
  salvage              = ReadText(20208, 41401),
}

function data.assignmentName(assignment)
  return ASSIGNMENTS[assignment] or ""
end

-- What one build asked the engine for, counted at the sites a cache miss costs a call. A frame
-- clock cannot time a build; these hold whatever the clock does.
data.counts = {}

local function tally(id)
  data.counts[id] = (data.counts[id] or 0) + 1
end
data.tally = tally

--- The tally as one line, heaviest first, for the trace.
function data.countsText()
  local ids = {}
  for id in pairs(data.counts) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b) return data.counts[a] > data.counts[b] end)

  local parts = {}
  for _, id in ipairs(ids) do
    parts[#parts + 1] = string.format("%s=%d", id, data.counts[id])
  end
  return table.concat(parts, " ")
end

-- A macro fact rather than an object one, so it is asked once per macro and kept for the session.
local laserTowerMacros = {}

local function isLaserTowerMacro(macro)
  if macro == nil then
    return false
  end
  local cached = laserTowerMacros[macro]
  if cached == nil then
    cached = GetMacroData(macro, "islasertower") and true or false
    laserTowerMacros[macro] = cached
  end
  return cached
end

-- What an object *is* cannot change while it lives, so that half of getObjectInfo is kept across
-- rebuilds and only the half that moves is asked again. Swept by generation: an entry survives a
-- build only if that build asked for it.
local staticInfo = {}
local staticGen  = 0

local function sweepStaticInfo()
  staticGen = staticGen + 1
  local kept, dropped = 0, 0
  for key, entry in pairs(staticInfo) do
    if entry.gen == staticGen - 1 then
      kept = kept + 1
    else
      staticInfo[key] = nil
      dropped = dropped + 1
    end
  end
  return kept, dropped
end

--- Drops an object from the caches that outlive a build.
local function forgetObject(key)
  staticInfo[key] = nil
end

local function getStaticInfo(component, key)
  local entry = staticInfo[key]
  if entry then
    entry.gen = staticGen
    return entry
  end

  tally("objStatic")
  local id64 = ConvertIDTo64Bit(component)
  local purpose, classId, realClassId, idCode, macro, isDeployable =
      GetComponentData(component, "primarypurpose", "classid", "realclassid", "idcode", "macro", "isdeployable")

  entry = {
    gen          = staticGen,
    id           = component,
    id64         = id64,
    objectid     = idCode,
    classid      = classId,
    realClassId  = realClassId,
    className    = ffi.string(C.GetComponentClass(id64)),
    macro        = macro,
    purpose      = purpose,
    isDeployable = isDeployable or false,
    isLaserTower = isLaserTowerMacro(macro),
  }
  staticInfo[key] = entry
  return entry
end

--- Per-refresh object data, keyed by component string. Only name, hull, whereabouts, fleet and
--- ownership are asked per build; what the object is comes off the cache that outlives it.
function data.getObjectInfo(instance, component)
  local infoTableData = eic.menu.infoTableData[instance]
  local cache = infoTableData.objectsInfo
  local key = tostring(component)
  if cache[key] then
    return cache[key]
  end

  local fixed = getStaticInfo(component, key)

  tally("object")
  local name, isPlayerOwned, hull, uiRelation, sector, sectorId, fleetName, subordinateGroup =
      GetComponentData(component, "name", "isplayerowned", "hullpercent", "uirelation", "sector", "sectorid",
        "fleetname", "subordinategroup")

  -- A table of its own per build, because everything derived - skill, cargo, orders, the filter
  -- verdict - is memoised onto it and must not outlive the build.
  -- These six keys keep vanilla's spelling because Helper's sorters read them
  -- straight off this table; every other key here is ours alone.
  local info = {
    id               = fixed.id,
    id64             = fixed.id64,
    name             = name,
    objectid         = fixed.objectid,
    fleetname        = fleetName,
    classid          = fixed.classid,
    realClassId      = fixed.realClassId,
    className        = fixed.className,
    macro            = fixed.macro,
    hull             = hull,
    purpose          = fixed.purpose,
    relation         = uiRelation,
    sector           = sector,
    sectorId         = sectorId,
    subordinateGroup = subordinateGroup,
    isPlayerOwned    = isPlayerOwned,
    isDeployable     = fixed.isDeployable,
    isLaserTower     = fixed.isLaserTower,
  }
  cache[key] = info
  return info
end

--- The unfilled command behind a ship's order, which is all the order filter groups by.
--- `false` is a settled "no order"; the formatted text costs a name lookup per parameter, so
--- it is left to getOrderText and paid only where a column draws it.
local function orderEntry(component)
  local key   = tostring(component)
  local entry = data.orderInfo[key]
  if entry then
    return entry
  end

  tally("orderCmd")
  entry = { command = false }
  -- Foreign ships docked at a player station keep their orders to themselves.
  if not GetComponentData(component, "isplayerowned") then
    entry.order, entry.action = "", ""
  else
    local entity = GetComponentData(component, "controlentity")
    if entity == nil then
      entry.order, entry.action = "-", "-"
    else
      entry.entity  = entity
      entry.command = GetComponentData(entity, "aicommand") or false
    end
  end

  data.orderInfo[key] = entry
  return entry
end

--- Current order and action text, as the order menu phrases them.
function data.getOrderText(component)
  local entry = orderEntry(component)
  if entry.order then
    return entry.order, entry.action
  end

  tally("orderText")
  local menu = eic.menu
  local command, commandParam, commandAction, commandActionParam =
      GetComponentData(entry.entity, "aicommand", "aicommandparam", "aicommandaction", "aicommandactionparam")

  local function paramText(param)
    if IsComponentClass(param, "ship") or IsComponentClass(param, "station") or IsComponentClass(param, "sector") then
      local name, color = menu.getContainerNameAndColors(param, 0, false, false)
      if IsComponentClass(param, "sector") then
        name = name:gsub(" %(%)", "")
      end
      return Helper.convertColorToText(color) .. name .. "\27X"
    end
    return GetComponentData(param, "name")
  end

  local orderText = command or ""
  if commandParam ~= nil then
    orderText = string.format(command, paramText(commandParam))
  end

  local actionText = commandAction or ""
  if commandActionParam ~= nil then
    actionText = string.format(commandAction, paramText(commandActionParam))
  end

  entry.order, entry.action = orderText, actionText
  return orderText, actionText
end

--- The kind of order alone - the command text with its parameter left out - so a filter list
--- holds one entry per kind rather than one per destination. nil where there is no order.
function data.getOrderKind(component)
  local command = orderEntry(component).command
  if (not command) or (command == "") then
    return nil
  end

  local text = command:gsub("%%s", ""):gsub("%s+", " ")
  text = text:match("^%s*(.-)%s*$")
  return command, (text ~= "") and text or command
end

function data.passesFilter(info)
  if info.isLaserTower then
    return eic.getOption("laserTowers") and true or false
  end

  local deployableOption = DEPLOYABLE_OPTION[info.className]
  if deployableOption then
    return eic.getOption(deployableOption) and true or false
  end

  local classOption = SHIPCLASS_OPTION[info.className]
  if classOption then
    if not eic.getOption(classOption) then
      return false
    end
    local roleOption = ROLE_OPTION[info.purpose]
    return (roleOption == nil) or (eic.getOption(roleOption) and true or false)
  end

  return true
end

--- The map's search box, which filters rows in every map panel.
function data.passesSearch(component64)
  local searchText = eic.menu.searchtext
  if #searchText == 0 then
    return true
  end
  return Helper.textArrayHelper(searchText, function(numTexts, texts)
    return C.FilterComponentByText(component64, numTexts, texts, true)
  end, "text")
end

--region Column data
--
-- What the columns ask the engine for, cached on the object's per-refresh info table.
-- A cached "nothing here" is false, since nil means "not asked yet".

--- Owner colour of a sector, cached on its own table since many rows share one sector.
function data.getSectorColor(sectorId)
  if sectorId == nil then
    return nil
  end
  local key = tostring(sectorId)
  local cached = data.sectorColors[key]
  if cached ~= nil then
    return cached or nil
  end

  local owner = GetComponentData(sectorId, "owner")
  local color = owner and GetFactionData(owner, "color") or nil
  data.sectorColors[key] = color or false
  return color
end

--- One cell of fleet-type icons, shared by the fleet column and the subordinate group rows.
--- defaultColor paints the entries that carry no colour of their own.
function data.fleetTypesText(fleetTypes, defaultColor)
  local parts = {}
  for _, entry in ipairs(fleetTypes) do
    local text = string.format("\027[%s]%s", entry.icon, entry.count and tostring(entry.count) or "")
    local color = entry.color or defaultColor
    if color then
      text = Helper.convertColorToText(color) .. text .. "\027X"
    end
    parts[#parts + 1] = text
  end
  return table.concat(parts, "  ")
end

--- The breakdown getPropertyOwnedFleetData returns, over one subordinate group.
function data.getGroupFleetTypes(instance, members)
  local ranks, byType = {}, {}
  for _, member in ipairs(members) do
    if member.component then
      local macro = member.macro or data.getObjectInfo(instance, member.component).macro
      eic.menu.getPropertyOwnedFleetDataInternal(instance, member.component, macro, ranks, byType)
    end
  end

  table.sort(ranks)
  local result = {}
  for _, rank in ipairs(ranks) do
    table.insert(result, 1, byType[rank])
  end
  return result
end

--- Combined skill 0-100 of a ship's pilot or a station's manager.
function data.skillValue(info)
  if info.skillValue == nil then
    tally("skill")
    local value = 0
    local npc
    if Helper.isComponentClass(info.realClassId, "station") then
      npc = GetComponentData(info.id, "tradenpc")
    elseif Helper.isComponentClass(info.realClassId, "ship") then
      npc = GetComponentData(info.id, "pilot")
    end
    if npc and (npc ~= 0) then
      value = GetComponentData(npc, "combinedskill") or 0
    end
    info.skillValue = value
  end
  return info.skillValue
end

function data.crewSkillValue(info)
  if info.crewSkillValue == nil then
    tally("crewSkill")
    info.crewSkillValue = Helper.isComponentClass(info.realClassId, "ship")
        and tonumber(C.GetShipCombinedSkill(info.id64)) or 0
  end
  return info.crewSkillValue
end

--- Vanilla floors before displaySkill; without it math.modf(skill / 3) lands
--- between the thirds it draws.
local function skillStars(value)
  if value <= 0 then
    return ""
  end
  return Helper.displaySkill(math.floor(value * 15 / 100))
end

--- Every ship in a fleet, leader included, filling the same subordinate cache vanilla fills.
local function collectFleetShips(instance, component, out)
  local infoTableData = eic.menu.infoTableData[instance]
  local key = tostring(component)
  local subordinates = infoTableData.subordinates[key]
  if subordinates == nil then
    local info = data.getObjectInfo(instance, component)
    subordinates = eic.menu.getSubordinates(component, info.id64, false, info.classid)
    infoTableData.subordinates[key] = subordinates
  end

  out[#out + 1] = component
  for _, subordinate in ipairs(subordinates) do
    if subordinate.component then
      collectFleetShips(instance, subordinate.component, out)
    end
  end
  return out
end

--- Mean captain and crew skill over a fleet. A ship with none is left out of the average
--- rather than dragging it to zero, so each mean carries the count it was taken over.
function data.fleetSkillAverages(ctx)
  local info = ctx.info
  if info.fleetSkill == nil then
    local pilotSum, pilotCount, crewSum, crewCount = 0, 0, 0, 0
    for _, member in ipairs(collectFleetShips(ctx.instance, ctx.component, {})) do
      local memberInfo = data.getObjectInfo(ctx.instance, member)
      local pilot = data.skillValue(memberInfo)
      if pilot > 0 then
        pilotSum, pilotCount = pilotSum + pilot, pilotCount + 1
      end
      local crew = data.crewSkillValue(memberInfo)
      if crew > 0 then
        crewSum, crewCount = crewSum + crew, crewCount + 1
      end
    end
    info.fleetSkill = {
      pilot      = (pilotCount > 0) and (pilotSum / pilotCount) or 0,
      pilotCount = pilotCount,
      crew       = (crewCount > 0) and (crewSum / crewCount) or 0,
      crewCount  = crewCount,
    }
  end
  return info.fleetSkill
end

--- "Fleet: Captain ***** (12 Ships)", composed from vanilla strings only.
local function fleetSkillMouseover(label, text, count)
  return string.format("%s%s %s \27Y%s\27X (%d %s)",
    ReadText(1001, 9919), ReadText(1001, 120), label, text, count, ReadText(1001, 6))
end

function data.getSkillText(ctx)
  local info = ctx.info
  if info.isLaserTower then
    return "", nil
  end

  if ctx.kind == "wing" then
    local averages = data.fleetSkillAverages(ctx)
    local text = skillStars(averages.pilot)
    if text == "" then
      return "", nil
    end
    return text, fleetSkillMouseover(ReadText(1001, 4848), text, averages.pilotCount)
  end

  local text = skillStars(data.skillValue(info))
  if text == "" then
    return "", nil
  end

  local position
  if ctx.kind == "station" then
    position = ReadText(20208, 30301)
  else
    position = Helper.isComponentClass(info.realClassId, "ship_s") and ReadText(1001, 4847) or ReadText(1001, 4848)
  end
  return text, position .. ReadText(1001, 120) .. " \27Y" .. text .. "\27X"
end

function data.getCrewSkillText(ctx)
  local info = ctx.info
  if info.isLaserTower then
    return "", nil
  end

  if ctx.kind == "wing" then
    local averages = data.fleetSkillAverages(ctx)
    local text = skillStars(averages.crew)
    if text == "" then
      return "", nil
    end
    return text, fleetSkillMouseover(ReadText(1001, 9427), text, averages.crewCount)
  end

  local text = skillStars(data.crewSkillValue(info))
  if text == "" then
    return "", nil
  end
  return text, ReadText(1001, 9427) .. ReadText(1001, 120) .. " \27Y" .. text .. "\27X"
end

function data.getCargo(info)
  if info.cargo == nil then
    tally("cargo")
    info.cargo = false
    local n = C.GetNumCargoTransportTypes(info.id64, true)
    if n > 0 then
      local buf = ffi.new("StorageInfo[?]", n)
      n = C.GetCargoTransportTypes(buf, n, info.id64, true, false)
      ---@type number, number
      local used, capacity = 0, 0
      for i = 0, n - 1 do
        used = used + tonumber(buf[i].spaceused)
        capacity = capacity + tonumber(buf[i].capacity)
      end
      if capacity > 0 then
        info.cargo = { used = used, capacity = capacity }
      end
    end
  end
  return info.cargo or nil
end

function data.cargoUsed(info)
  local cargo = data.getCargo(info)
  return cargo and cargo.used or 0
end

function data.cargoCapacity(info)
  local cargo = data.getCargo(info)
  return cargo and cargo.capacity or 0
end

local function shortNumber(value)
  return ConvertIntegerString(value, true, 0, false, true, true)
end

--- "1.2k / 5.0k", the exact figures in the mouseover.
local function cargoText(used, capacity)
  return shortNumber(used) .. " / " .. shortNumber(capacity),
      ReadText(1001, 63) .. ReadText(1001, 120) .. " " ..
      ConvertIntegerString(used, true, 0, false, true, false) .. " / " ..
      ConvertIntegerString(capacity, true, 0, false, true, false)
end

function data.getCargoText(ctx)
  local cargo = data.getCargo(ctx.info)
  if cargo == nil then
    return "", nil
  end
  return cargoText(cargo.used, cargo.capacity)
end

--- The same cell over several ships; a set with no hold at all reads empty, not 0 / 0.
local function cargoSumText(instance, components)
  local used, capacity = 0, 0
  for _, component in ipairs(components) do
    local cargo = data.getCargo(data.getObjectInfo(instance, component))
    if cargo then
      used, capacity = used + cargo.used, capacity + cargo.capacity
    end
  end
  if capacity == 0 then
    return "", nil
  end
  return cargoText(used, capacity)
end

function data.getFleetCargoText(ctx)
  local info = ctx.info
  if info.fleetCargo == nil then
    local text, mouseOver = cargoSumText(ctx.instance, collectFleetShips(ctx.instance, ctx.component, {}))
    info.fleetCargo = { text = text, mouseOver = mouseOver }
  end
  return info.fleetCargo.text, info.fleetCargo.mouseOver
end

function data.getGroupCargoText(instance, members)
  local components = {}
  for _, member in ipairs(members) do
    if member.component then
      components[#components + 1] = member.component
    end
  end
  return cargoSumText(instance, components)
end

function data.getMoneyText(ctx)
  local money = GetComponentData(ctx.component, "money")
  if money == nil then
    return ""
  end
  return ConvertMoneyString(money, false, true, nil, true) .. " " .. ReadText(1001, 101)
end

--- The order queue as plain tables, plus the 1-based index of the current order.
function data.getOrders(info)
  if info.orders == nil then
    local orders = {}
    local n = C.GetNumOrders(info.id64)
    if n > 0 then
      local buf = ffi.new("Order2[?]", n)
      n = C.GetOrders2(buf, n, info.id64)
      for i = 0, n - 1 do
        orders[#orders + 1] = { orderdef = ffi.string(buf[i].orderdef) }
      end
    end
    info.orders = orders
    info.orderIndex = tonumber(C.GetOrderQueueCurrentIdx(info.id64))
  end
  return info.orders, info.orderIndex
end

local function orderDefinition(orderDefId)
  if (orderDefId == nil) or (orderDefId == "") then
    return nil
  end
  local definition = ffi.new("OrderDefinition")
  if not C.GetOrderDefinition(definition, orderDefId) then
    return nil
  end
  return { id = ffi.string(definition.id), icon = ffi.string(definition.icon), name = ffi.string(definition.name) }
end

local function orderText(icon, name)
  if (icon == nil) or (icon == "") then
    return name or ""
  end
  return "\27[" .. icon .. "] " .. (name or "")
end

--- orders.base tests exactly this pair for a ship held at a player wait point.
function data.isSignalWaiting(info)
  if info.signalWaiting == nil then
    info.signalWaiting = false
    local orders, curIndex = data.getOrders(info)
    local order = orders[curIndex]
    if order and (order.orderdef == "WaitForSignal") then
      for _, param in ipairs(GetOrderParams(info.id64, curIndex) or {}) do
        if (param.name == "releasesignal") and (type(param.value) == "table") and (param.value[1] == "playerownedship_proceed") then
          info.signalWaiting = true
          break
        end
      end
    end
  end
  return info.signalWaiting
end

--- What the ship does once released: the next queued order, or its default behaviour.
function data.getNextOrder(info)
  if info.nextOrder == nil then
    info.nextOrder = false
    local orders, curIndex = data.getOrders(info)
    local entry = orders[curIndex + 1]
    local definition
    if entry then
      definition = orderDefinition(entry.orderdef)
    else
      local buf = ffi.new("Order")
      if C.GetDefaultOrder(buf, info.id64) then
        definition = orderDefinition(ffi.string(buf.orderdef))
      end
    end
    if definition then
      info.nextOrder = { icon = definition.icon, name = definition.name, isDefault = (entry == nil) }
    end
  end
  return info.nextOrder or nil
end

function data.getNextOrderText(ctx)
  local entry = data.getNextOrder(ctx.info)
  if entry == nil then
    return "", nil, nil
  end
  if entry.isDefault then
    return orderText(entry.icon, entry.name),
        ReadText(1001, 8320) .. ReadText(1001, 120) .. " " .. entry.name, Color["order_temp"]
  end
  return orderText(entry.icon, entry.name), nil, nil
end

--- The newest order failure on record, falling back to the default order's.
function data.getFailure(info)
  if info.failure == nil then
    tally("failure")
    info.failure = false

    local function entry(failure)
      local definition = orderDefinition(ffi.string(failure.orderdef))
      local message = ffi.string(failure.message)
      return {
        text      = orderText(definition and definition.icon, definition and definition.name),
        message   = message,
        mouseOver = Helper.getPassedTime(failure.timestamp) .. " - " .. message,
      }
    end

    local n = C.GetNumOrderFailures(info.id64, true)
    if n > 0 then
      local buf = ffi.new("OrderFailure[?]", n)
      n = C.GetOrderFailures(buf, n, info.id64, true)
      local newest
      for i = 0, n - 1 do
        if (newest == nil) or (buf[i].timestamp > buf[newest].timestamp) then
          newest = i
        end
      end
      if newest then
        info.failure = entry(buf[newest])
      end
    end
    if info.failure == false then
      local buf = ffi.new("OrderFailure")
      if C.GetDefaultOrderFailure(buf, info.id64) then
        info.failure = entry(buf)
      end
    end
  end
  return info.failure or nil
end

--- The ware the ship is on its way to trade; queue entries before the current one are done.
function data.getTradeWare(info)
  if info.tradeWare == nil then
    tally("trade")
    info.tradeWare = false
    local orders, curIndex = data.getOrders(info)
    for i = math.max(1, curIndex), #orders do
      local orderDefId = orders[i].orderdef
      if (orderDefId == "TradePerform") or (orderDefId == "TradeExchange") then
        local params = GetOrderParams(info.id64, i)
        if params and params[1] then
          local value = eic.menu.getParamValue(params[1].type, params[1].value)
          local tradeData = value and GetTradeData(ConvertStringToLuaID(value))
          if tradeData and tradeData.ware then
            info.tradeWare = { ware = tradeData.ware, amount = tradeData.amount,
              name = GetWareData(tradeData.ware, "name") }
          end
        end
        break
      end
    end
  end
  return info.tradeWare or nil
end

function data.getTradeWareText(ctx)
  local trade = data.getTradeWare(ctx.info)
  if trade == nil then
    return ""
  end
  return ConvertIntegerString(trade.amount, true, 0, false, true, true) .. " " .. (trade.name or "")
end

function data.isDamaged(info)
  if info.damaged == nil then
    info.damaged = (not IsComponentOperational(info.id64)) or ((info.hull > 0) and (info.hull < 100))
  end
  return info.damaged
end

--- Per-view row predicates, asked of one object's own values alone; what it holds is the
--- subtree's business, in data.passesRowFilter.
data.ROW_FILTERS = {
  damaged    = function(info) return data.isDamaged(info) end,
  signal     = function(info) return data.isSignalWaiting(info) end,
  failed     = function(info) return data.getFailure(info) ~= nil end,

  tradeCargo = function(info)
    if not eic.getOption("hideEmptyTradeRows") then
      return true
    end
    local cargo = data.getCargo(info)
    return ((cargo ~= nil) and (cargo.used > 0)) or (data.getTradeWare(info) ~= nil)
  end,
}

--- The node's own values or anything visible under it: a parent stands for what it holds, so a
--- fleet drops off the list only when every ship in it is hidden too.
function data.passesRowFilter(instance, view, component, info)
  local filter = view.filter and data.ROW_FILTERS[view.filter]
  if filter == nil then
    return true
  end
  if filter(info) then
    return true
  end

  local key  = tostring(component)
  local seen = data.rowFilterScan[key]
  if seen ~= nil then
    return seen
  end
  -- Claimed before the children are walked, so a cycle between a commander and a docked ship
  -- cannot run away.
  data.rowFilterScan[key] = false

  local infoTableData = eic.menu.infoTableData[instance]
  local passed        = false
  for _, child in ipairs(infoTableData.subordinates[key] or {}) do
    if child.component and data.isRowVisible(instance, view, child.component) then
      passed = true
      break
    end
  end
  if not passed then
    for _, docked in ipairs(infoTableData.dockedships[key] or {}) do
      if docked.component and data.isRowVisible(instance, view, docked.component) then
        passed = true
        break
      end
    end
  end

  data.rowFilterScan[key] = passed
  return passed
end

--- Whether an object gets a row at all: the option filters, the tab's own filter and the map
--- search. Cached for the refresh, since the pager counts the rows the builder then paints.
function data.isRowVisible(instance, view, component)
  local info = data.getObjectInfo(instance, component)
  if info.rowVisible == nil then
    info.rowVisible = (data.passesFilter(info) and data.passesSearch(info.id64)
      and data.passesRowFilter(instance, view, component, info)) and true or false
  end
  return info.rowVisible, info
end

--endregion

--region Sorting

local function sortSectorAndName(a, b, invert)
  if a.sector == b.sector then
    return Helper.sortName(a, b)
  end
  if invert then
    return a.sector > b.sector
  end
  return a.sector < b.sector
end

local function sortOrderAndName(a, b, invert)
  local orderA = data.getOrderText(a.id)
  local orderB = data.getOrderText(b.id)
  if orderA == orderB then
    return Helper.sortName(a, b)
  end
  if invert then
    return orderA > orderB
  end
  return orderA < orderB
end

local function sortNumberAndName(getter)
  return function(a, b, invert)
    local valueA, valueB = getter(a), getter(b)
    if valueA == valueB then
      return Helper.sortName(a, b)
    end
    if invert then
      return valueA > valueB
    end
    return valueA < valueB
  end
end

local sortSkillAndName     = sortNumberAndName(function(info) return data.skillValue(info) end)
local sortCrewAndName      = sortNumberAndName(function(info) return data.crewSkillValue(info) end)
local sortCargoAndName     = sortNumberAndName(function(info) return data.cargoCapacity(info) end)
local sortCargoUsedAndName = sortNumberAndName(function(info) return data.cargoUsed(info) end)

local SORTERS = {
  name         = function(a, b) return Helper.sortNameAndObjectID(a, b) end,
  nameInverse  = function(a, b) return Helper.sortNameAndObjectID(a, b, true) end,
  class        = function(a, b) return Helper.sortShipsByClassAndPurpose(a, b) end,
  classInverse = function(a, b) return Helper.sortShipsByClassAndPurpose(a, b, true) end,
  hull         = function(a, b) return Helper.sortHullAndName(a, b) end,
  hullInverse  = function(a, b) return Helper.sortHullAndName(a, b, true) end,
  sector        = function(a, b) return sortSectorAndName(a, b) end,
  sectorInverse = function(a, b) return sortSectorAndName(a, b, true) end,
  order         = function(a, b) return sortOrderAndName(a, b) end,
  orderInverse  = function(a, b) return sortOrderAndName(a, b, true) end,
  skill         = function(a, b) return sortSkillAndName(a, b) end,
  skillInverse  = function(a, b) return sortSkillAndName(a, b, true) end,
  crew          = function(a, b) return sortCrewAndName(a, b) end,
  crewInverse   = function(a, b) return sortCrewAndName(a, b, true) end,
  cargo         = function(a, b) return sortCargoAndName(a, b) end,
  cargoInverse  = function(a, b) return sortCargoAndName(a, b, true) end,
  cargoUsed        = function(a, b) return sortCargoUsedAndName(a, b) end,
  cargoUsedInverse = function(a, b) return sortCargoUsedAndName(a, b, true) end,
}

function data.sorter()
  return SORTERS[eic.sorterType] or SORTERS.name
end

function data.sortEntries(instance, list)
  local sorter = data.sorter()
  table.sort(list, function(a, b)
    return sorter(data.getObjectInfo(instance, a.component), data.getObjectInfo(instance, b.component))
  end)
end

--- The buckets hold plain components rather than entries. Sorted per bucket where the section is
--- built, so a tab pays the comparator on the rows it draws rather than on the whole property set.
local function sortComponents(instance, list)
  local sorter = data.sorter()
  table.sort(list, function(a, b)
    return sorter(data.getObjectInfo(instance, a), data.getObjectInfo(instance, b))
  end)
end

--endregion

--region Collection

--- Deployables test shared by both sources: towers, satellites, mines, beacons, probes, pickups.
local function isDeployable(info)
  return (info.isDeployable
    or Helper.isComponentClass(info.classid, "lockbox")
    or Helper.isComponentClass(info.classid, "collectablewares")) and true or false
end

--- Deployables of one name as a single node: what the player has, not each copy of it.
--- A name held by one object is no group and takes the plain object row.
--- Grouped after the row gates, so a count states what the tab actually lists.
local function groupByName(instance, items)
  local groups, byName = {}, {}
  for _, component in ipairs(items) do
    local info = data.getObjectInfo(instance, component)
    if data.passesFilter(info) and data.passesSearch(info.id64) then
      local name  = info.name or ""
      local group = byName[name]
      if group == nil then
        group = { name = name, items = {}, sector = info.sector, sectorId = info.sectorId }
        byName[name] = group
        groups[#groups + 1] = group
      elseif group.sector ~= info.sector then
        -- A shared sector is worth stating on the group row; a mixed one is false, not a name.
        group.sector = false
      end
      group.items[#group.items + 1] = component
    end
  end
  return groups
end

--- Whether a top-level object can reach a row on this tab at all, from the static half alone.
--- Both tests are safe to ask this early because neither object can be drawn under a parent:
--- passesFilter hides a row wherever it appears, and a deployable commands nothing and docks
--- nowhere, so it is never nested. The tab's own filter row is *not* asked here - the dropdown
--- lists are built from what survives every filter but their own.
local function tabCanDraw(fixed, flat, wantDeployables)
  if flat and (not Helper.isComponentClass(fixed.realClassId, "ship")) then
    return false
  end
  if isDeployable(fixed) ~= wantDeployables then
    return false
  end
  return data.passesFilter(fixed)
end

--- The owned objects this tab could draw, as info tables. Returns the engine's total beside
--- them, since the skipped ones never reach a bucket and the trace would otherwise lose them.
local function collectPlayerObjects(instance, flat, wantDeployables)
  local infoTableData = eic.menu.infoTableData[instance]

  local playerObjects
  if Helper.isPlayerCovered() and (not C.IsUICoverOverridden()) then
    playerObjects = { ConvertStringTo64Bit(tostring(C.GetPlayerOccupiedShipID())) }
  else
    playerObjects = GetContainedObjectsByOwner("player")
  end
  local owned = #playerObjects

  -- Filled rather than pruned: table.remove shifts the tail per call, and the gates below drop
  -- the majority of the list on most tabs.
  local kept = {}
  for i = 1, owned do
    local object = playerObjects[i]
    local key = tostring(object)
    -- Ahead of the volatile fetch and of isObjectValid, so an object the tab cannot draw costs
    -- nothing beyond the static half it already had.
    if tabCanDraw(getStaticInfo(object, key), flat, wantDeployables) then
      local info = data.getObjectInfo(instance, object)
      if eic.menu.isObjectValid(info.id64, info.classid, info.realClassId) then
        kept[#kept + 1] = info
      else
        infoTableData.objectsInfo[key] = nil
        forgetObject(key)
      end
    end
  end

  return kept, owned
end

local function collectDockedShips(object64)
  local dockedShips = {}
  Helper.ffiVLA(dockedShips, "UniverseID", C.GetNumDockedShips, C.GetDockedShips, object64, nil)
  for i = #dockedShips, 1, -1 do
    local docked = ConvertStringToLuaID(tostring(dockedShips[i]))
    if GetCommander(docked) then
      table.remove(dockedShips, i)
    else
      dockedShips[i] = { component = docked }
    end
  end
  return dockedShips
end

--- Player ship build tasks, with queued sister ships collapsed by macro.
local function collectConstructionShips()
  local constructions = {}

  local n = C.GetNumPlayerShipBuildTasks(true, false)
  local buf = ffi.new("BuildTaskInfo[?]", n)
  n = C.GetPlayerShipBuildTasks(buf, n, true, false)
  for i = 0, n - 1 do
    if ffi.string(buf[i].factionid) == "player" then
      constructions[#constructions + 1] = {
        id = buf[i].id, buildingcontainer = buf[i].buildingcontainer, component = buf[i].component,
        macro = ffi.string(buf[i].macro), buildercomponent = buf[i].buildercomponent,
        ismissingresources = buf[i].ismissingresources, queueposition = buf[i].queueposition, inprogress = true,
      }
    end
  end
  if #constructions > 0 then
    constructions[#constructions + 1] = { empty = true }
  end

  local byMacro = {}
  n = C.GetNumPlayerShipBuildTasks(false, false)
  buf = ffi.new("BuildTaskInfo[?]", n)
  n = C.GetPlayerShipBuildTasks(buf, n, false, false)
  for i = 0, n - 1 do
    if ffi.string(buf[i].factionid) == "player" then
      local component = buf[i].component
      local macro = ffi.string(buf[i].macro)
      local entry = {
        id = buf[i].id, buildingcontainer = buf[i].buildingcontainer, component = component,
        macro = macro, buildercomponent = buf[i].buildercomponent,
        ismissingresources = buf[i].ismissingresources, queueposition = buf[i].queueposition, inprogress = false,
      }
      if (component == 0) and (macro ~= "") then
        if byMacro[macro] then
          local queued = constructions[byMacro[macro]]
          queued.amount = queued.amount + 1
        else
          entry.amount = 1
          constructions[#constructions + 1] = entry
          byMacro[macro] = #constructions
        end
      else
        constructions[#constructions + 1] = entry
      end
    end
  end

  return constructions
end

--- Fills the per-refresh buckets and returns the sections the view asks for. Takes the layout
--- rather than the view alone: what the tab draws settles how much of the tree it has to gather.
function data.collect(instance, layout)
  local menu = eic.menu
  local view = layout.view
  local infoTableData = menu.infoTableData[instance]

  data.counts = {}
  data.orderInfo = {}
  data.sectorColors = {}
  data.rowFilterScan = {}
  local staticKept, staticDropped = sweepStaticInfo()
  infoTableData.objectsInfo           = {}
  infoTableData.maxIcons              = eic.MAXICONS
  infoTableData.stations              = {}
  infoTableData.fleetLeaderShips      = {}
  infoTableData.unassignedShips       = {}
  infoTableData.ships                 = {}
  infoTableData.deployables           = {}
  infoTableData.subordinates          = {}
  infoTableData.dockedships           = {}
  infoTableData.constructions         = {}
  infoTableData.constructionShips     = {}
  infoTableData.fleetUnitData         = {}
  infoTableData.fleetUnitSubordinates = {}
  infoTableData.fleetUnitReplacements = {}
  infoTableData.moduledata            = {}

  local flat = (view.source == "ships")
  -- A deployable commands nothing and docks nothing, so its tab gathers no tree at all - and
  -- with no tree there is no fleet cell to feed, which is what reads the fleet-unit counts.
  local tree       = (view.scope ~= "deployables")
  local fleetUnits = tree and (layout.byId.fleet ~= nil)

  local playerObjects, owned = collectPlayerObjects(instance, flat, not tree)

  for _, info in ipairs(playerObjects) do
    local object = info.id
    local key = tostring(object)

    if flat then
      -- The class and deployable tests are what got the object past collectPlayerObjects.
      infoTableData.ships[#infoTableData.ships + 1] = object
    else
      local baseStation
      if tree then
        local isFleetLead
        baseStation, isFleetLead = GetComponentData(object, "basestation", "isfleetlead")
        if fleetUnits and isFleetLead then
          -- Collect the whole fleet-unit tree once instead of recursing per row.
          tally("fleetUnits")
          menu.getFleetUnitSubordinates(instance, info.id64, false)
        end

        -- Only a controllable commands anything, and a lockbox or a floating ware is a
        -- container with no dock, so neither list is asked for where it could only come back empty.
        if Helper.isComponentClass(info.classid, "controllable") then
          tally("subs")
          infoTableData.subordinates[key] = menu.getSubordinates(object, info.id64, false, info.classid)
        end
        if Helper.isComponentClass(info.classid, "container") and (not isDeployable(info)) then
          tally("docked")
          infoTableData.dockedships[key] = collectDockedShips(info.id64)
        end
      end

      local subordinates = infoTableData.subordinates[key]
      local commander
      if Helper.isComponentClass(info.classid, "controllable") then
        commander = GetCommander(object)
      end
      -- collectPlayerObjects has already split deployables from the rest by tab, so the tree
      -- branches below cannot see one and the no-tree branch sees nothing else.
      if not commander then
        if not tree then
          -- Nothing was gathered to tell a fleet lead from an unassigned ship, so the tab that
          -- asked for no tree takes its own bucket and leaves the rest empty.
          infoTableData.deployables[#infoTableData.deployables + 1] = object
        elseif Helper.isComponentClass(info.realClassId, "station") then
          infoTableData.stations[#infoTableData.stations + 1] = object
        elseif Helper.isComponentClass(info.classid, "buildstorage") then
          if not baseStation then
            infoTableData.stations[#infoTableData.stations + 1] = object
          end
        elseif subordinates and (#subordinates > 0) then
          infoTableData.fleetLeaderShips[#infoTableData.fleetLeaderShips + 1] = object
        else
          infoTableData.unassignedShips[#infoTableData.unassignedShips + 1] = object
        end
      end
    end
  end

  -- A scoped view is one section under a tab that already names it, so it takes no header.
  local scope = view.scope
  local sections = {}
  if flat then
    sortComponents(instance, infoTableData.ships)
    sections[#sections + 1] = {
      id = "ownedships", items = infoTableData.ships,
      none = "-- " .. ReadText(1001, 34) .. " --",
    }
  else
    if (menu.mode ~= "selectCV") and ((scope == nil) or (scope == "stations")) then
      sortComponents(instance, infoTableData.stations)
      sections[#sections + 1] = {
        id = "ownedstations", name = (scope == nil) and ReadText(1001, 4) or nil,
        items = infoTableData.stations,
        none = "-- " .. ReadText(1001, 33) .. " --",
      }
    end
    if (scope == nil) or (scope == "fleets") then
      sortComponents(instance, infoTableData.fleetLeaderShips)
      sections[#sections + 1] = {
        id = "ownedfleets", name = (scope == nil) and ReadText(1001, 8326) or nil,
        items = infoTableData.fleetLeaderShips,
        none = "-- " .. ReadText(1001, 34) .. " --",
      }
    end
    if (scope == nil) or (scope == "unassigned") then
      sortComponents(instance, infoTableData.unassignedShips)
      sections[#sections + 1] = {
        id = "ownedships", name = (scope == nil) and ReadText(1001, 8327) or nil,
        items = infoTableData.unassignedShips,
        none = "-- " .. ReadText(1001, 34) .. " --",
      }
    end
    if scope == "deployables" then
      sortComponents(instance, infoTableData.deployables)
      sections[#sections + 1] = {
        id = "owneddeployables", kind = "deployables",
        items = infoTableData.deployables,
        groups = groupByName(instance, infoTableData.deployables),
        none = "-- " .. ReadText(1001, 34) .. " --",
      }
    end
    if scope == nil then
      infoTableData.constructionShips = collectConstructionShips()
      sections[#sections + 1] = {
        id = "constructionships", name = ReadText(1001, 8328), kind = "construction",
        items = infoTableData.constructionShips,
      }
    end
  end

  -- Every bucket holds top-level rows alone; a subordinate or a docked ship is reached through
  -- its commander and is counted in neither. The first total is what the tab could draw, the
  -- second what the player owns - the gap is what the option and scope gates dropped unasked.
  eic.Trace("collected %d of %d owned object(s) into %d station(s), %d fleet lead(s), %d unassigned, %d deployable(s), %d flat ship(s)",
    #playerObjects, owned, #infoTableData.stations, #infoTableData.fleetLeaderShips,
    #infoTableData.unassignedShips, #infoTableData.deployables, #infoTableData.ships)
  eic.Trace("  static cache: %d kept, %d dropped", staticKept, staticDropped)
  return sections
end

--endregion

--region Expansion

--- The subordinate groups a row draws, in the order createSubordinateSection walks them.
local function subordinateGroups(instance, key)
  local groups = {}
  for _, subordinate in ipairs(eic.menu.infoTableData[instance].subordinates[key] or {}) do
    if subordinate.component then
      local group = data.getObjectInfo(instance, subordinate.component).subordinateGroup
      if group and (group > 0) then
        groups[group] = groups[group] or {}
        table.insert(groups[group], subordinate.component)
      end
    end
  end
  return groups
end

--- Collected regardless of the current state, so a half-open list still has every node to set.
--- A row the builder does not draw is no target, so the same gates are repeated here.
local function walkNode(instance, view, component, deep, out)
  local key           = tostring(component)
  local visible, info = data.isRowVisible(instance, view, component)
  local infoTableData = eic.menu.infoTableData[instance]
  local subordinates  = infoTableData.subordinates[key] or {}
  local dockedShips   = infoTableData.dockedships[key] or {}

  if not visible then
    return
  end
  if not (subordinates.hasRendered or (#dockedShips > 0)) then
    return
  end
  out[#out + 1] = { kind = "property", key = key }
  if not deep then
    return
  end

  local groups = subordinateGroups(instance, key)
  for group = 1, 10 do
    if groups[group] then
      out[#out + 1] = { kind = "subordinates", key = key, group = group }
      for _, member in ipairs(groups[group]) do
        walkNode(instance, view, member, deep, out)
      end
    end
  end

  if #dockedShips > 0 then
    out[#out + 1] = { kind = "dockedships", key = key,
      isStation = Helper.isComponentClass(info.realClassId, "station") }
    for _, docked in ipairs(dockedShips) do
      walkNode(instance, view, docked.component, deep, out)
    end
  end
end

--- Every node the global expand button acts on: the top-level rows alone, or, under the full
--- scope, every expandable row, subordinate group and docked block beneath them.
function data.expandTargets(instance, view, sections)
  local deep    = (eic.getOption("expandScope") == "full")
  local targets = {}
  for _, section in ipairs(sections) do
    if section.kind == "deployables" then
      -- A group holds objects with nothing under them, so the scope makes no difference here.
      for _, group in ipairs(section.groups) do
        if #group.items > 1 then
          targets[#targets + 1] = { kind = "namegroup", key = group.name }
        end
      end
    elseif section.kind ~= "construction" then
      for _, component in ipairs(section.items) do
        walkNode(instance, view, component, deep, targets)
      end
    end
  end
  return targets
end

function data.isExpanded(target)
  local menu = eic.menu
  if target.kind == "namegroup" then
    return data.expandedGroups[target.key] and true or false
  elseif target.kind == "subordinates" then
    return menu.isSubordinateExtended(target.key, target.group)
  elseif target.kind == "dockedships" then
    return menu.isDockedShipsExtended(target.key, target.isStation)
  end
  return menu.isPropertyExtended(target.key)
end

function data.allExpanded(targets)
  for _, target in ipairs(targets) do
    if not data.isExpanded(target) then
      return false
    end
  end
  return true
end

--- The three vanilla tables read their absent value differently - a group and a docked ship
--- default to open, a property row and a station's dock to closed - so collapsing is nil in one
--- and false in the other, and setting the wrong one reads back as still expanded. A name group
--- is ours and absent means closed, which is how the deployables tab opens.
function data.setExpanded(target, expanded)
  local menu = eic.menu
  if target.kind == "namegroup" then
    data.expandedGroups[target.key] = expanded or nil
  elseif target.kind == "subordinates" then
    menu.extendedsubordinates[target.key .. target.group] = expanded or false
  elseif target.kind == "dockedships" then
    if expanded then
      menu.extendeddockedships[target.key] = true
    elseif target.isStation then
      menu.extendeddockedships[target.key] = nil
    else
      menu.extendeddockedships[target.key] = false
    end
  else
    menu.extendedproperty[target.key] = expanded or nil
  end
end

--endregion

Register_Require_Response("extensions.enhanced_info_center.ui.eic_data", data)

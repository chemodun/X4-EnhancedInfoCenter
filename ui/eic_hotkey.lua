-- Info Center - the open/close hotkey and its switch on hotkey_api's Hotkey Management page.
-- Optional: without hotkey_api, Register_Request never fires and nothing here runs.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C   = ffi.C

---@diagnostic disable-next-line: unresolved-require
local eic = require("extensions.enhanced_info_center.ui.eic_config")

local ACTION_ID        = "enhanced_info_center_toggle"
-- Must not match any page name gameoptions' submenuHandler resolves before its optionDefinitions fallback.
local SETTINGS_PAGE_ID = "eic_hotkey_settings"
local NAV_ROW_ID       = "eic_hotkey_settings_nav"

local optionsHooked = false

-- Same as a click on the sidebar entry; outside the map, opens it on the panel.
local function toggle()
  local menu = Helper.getMenu("MapMenu")
  if menu and menu.shown then
    if menu.showMultiverse then
      eic.Debug("hotkey: multiverse map shown, ignored")
      return
    end
    eic.Debug("hotkey: toggling the panel, infoTableMode=%s", tostring(menu.infoTableMode))
    menu.buttonToggleObjectList(eic.MODE)
  else
    eic.Debug("hotkey: opening the map on the panel")
    OpenMenu("MapMenu", { 0, 0, true, nil, nil, "infomode", { eic.MODE } }, nil)
  end
end

local function settingsPage()
  return {
    name = function() return ReadText(eic.PAGE, 1) end,
    {
      id        = "eic_hotkey_enabled",
      name      = function() return ReadText(eic.PAGE, 500) end,
      value     = function() return eic.getOption("hotkeyEnabled") and ReadText(1001, 4825) or ReadText(1001, 8942) end,
      valuetype = "button",
      callback  = function()
        local enabled = not eic.getOption("hotkeyEnabled")
        eic.setOption("hotkeyEnabled", enabled)
        C.SaveUIUserData()
        eic.Debug("hotkey: enabled set to %s", tostring(enabled))
        -- Every slot goes unconfirmed and hotkey_api frees the ones nobody registers again.
        HotkeyApi.BroadcastReloaded()
      end,
    },
  }
end

-- HotkeyApi.OnDisplayOptions first: the callback list runs in pairs() order. It is idempotent.
local function onDisplayOptions(options, config)
  if not (HotkeyApi and HotkeyApi.OnDisplayOptions and HotkeyApi.managementPageId) then
    return options
  end
  options = HotkeyApi.OnDisplayOptions(options, config)

  local definitions = config and config.optionDefinitions
  local page        = definitions and definitions[HotkeyApi.managementPageId]
  if not page then
    return options
  end

  -- Before the nav row, or a click on it does nothing.
  if not definitions[SETTINGS_PAGE_ID] then
    definitions[SETTINGS_PAGE_ID] = settingsPage()
  end

  for _, row in ipairs(page) do
    if (type(row) == "table") and (row.id == NAV_ROW_ID) then
      return options
    end
  end

  table.insert(page, { id = "line" })
  -- No callback: onSelectElement tests it before submenu.
  table.insert(page, { id = NAV_ROW_ID, name = function() return ReadText(eic.PAGE, 1) end, submenu = SETTINGS_PAGE_ID })
  eic.Debug("hotkey: settings row added to the Hotkey Management page")
  return options
end

local function hookOptions()
  if optionsHooked then
    return
  end
  local optionsMenu = Helper.getMenu("OptionsMenu")
  if not (optionsMenu and (type(optionsMenu.registerCallback) == "function")) then
    eic.Debug("hotkey: OptionsMenu unavailable")
    return
  end
  optionsMenu.registerCallback("displayOptions_modifyOptions", onDisplayOptions)
  optionsHooked = true
end

local function onRegisterRequest()
  if not (HotkeyApi and HotkeyApi.RegisterAction) then
    eic.Debug("hotkey: HotkeyApi.RegisterAction unavailable")
    return
  end
  hookOptions()

  if not eic.getOption("hotkeyEnabled") then
    eic.Debug("hotkey: disabled, %s not registered", ACTION_ID)
    return
  end
  HotkeyApi.RegisterAction({
    id               = ACTION_ID,
    area             = "map;pilot;fps",
    isObjectRequired = false,
    name             = ReadText(eic.PAGE, 100),
    version          = 1,
    actionLua        = toggle,
  })
  eic.Debug("hotkey: %s registered", ACTION_ID)
end

-- File scope: the loader's inits have no fixed order against hotkey_api's first request.
RegisterEvent("HotkeyApi.Register_Request", onRegisterRequest)

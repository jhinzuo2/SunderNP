-- SunderNP.lua
-- Tracks Sunder stacks on nameplates + Overpower (4s window + 5s cooldown).
-- Overpower icon appears on the specific mob that triggered the proc (via GUID).
-- Slash commands: /sundernp or /snp
--   opon  : enable Overpower on nameplates
--   opoff : disable Overpower on nameplates
--   help  : usage info

------------------------------------------------
-- 0) Saved Variables & Defaults
------------------------------------------------
SunderNPDB = SunderNPDB or {}

local SunderNP_Defaults = {
  overpowerEnabled = false,
}

local function SunderNP_Initialize()
  for k, v in pairs(SunderNP_Defaults) do
    if SunderNPDB[k] == nil then
      SunderNPDB[k] = v
    end
  end
end

------------------------------------------------
-- 1) Slash Command Handler
------------------------------------------------
local function SunderNP_SlashCommand(msg)
  if type(msg) ~= "string" then msg = "" end
  msg = string.lower(msg)

  if msg == "opon" then
    SunderNPDB.overpowerEnabled = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SunderNP]|r Overpower feature: |cff00ff00ENABLED|r.")
  elseif msg == "opoff" then
    SunderNPDB.overpowerEnabled = false
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SunderNP]|r Overpower feature: |cffff0000DISABLED|r.")
  elseif msg == "help" or msg == "" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SunderNP]|r usage:")
    DEFAULT_CHAT_FRAME:AddMessage("  /sundernp opon   -> enable Overpower icon on nameplates")
    DEFAULT_CHAT_FRAME:AddMessage("  /sundernp opoff  -> disable Overpower icon on nameplates")
    DEFAULT_CHAT_FRAME:AddMessage("  /sundernp help   -> show this help text")
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SunderNP]|r: Unrecognized command '"..msg.."'. Type '/sundernp help' for usage.")
  end
end

------------------------------------------------
-- 2) Register an Event for Initialization
------------------------------------------------
local SunderNPFrame = CreateFrame("Frame", "SunderNP_MainFrame")
SunderNPFrame:RegisterEvent("VARIABLES_LOADED")
SunderNPFrame:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    SunderNP_Initialize()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SunderNP]|r loaded. Type '/sundernp help' for options.")
  end
end)

SLASH_SUNDERNP1 = "/sundernp"
SLASH_SUNDERNP2 = "/snp"
SlashCmdList["SUNDERNP"] = SunderNP_SlashCommand

------------------------------------------------
-- 3) Overpower Logic
--
-- We track WHICH mob triggered the proc via its GUID so the icon
-- appears on that specific nameplate rather than always on "target".
--
-- Detection sources (in priority order):
--   A) COMBAT_TEXT_UPDATE "SPELL_ACTIVE" / "Overpower"  -- fires on dodge/parry
--      No mob info here, so we fall back to "target" GUID as best guess.
--   B) CHAT_MSG_COMBAT_SELF_MISSES  -- "<Mob> dodges your <Attack>."
--      Mob name is parseable, lets us resolve a GUID via WorldFrame scan.
--   C) CHAT_MSG_SPELL_SELF_DAMAGE   -- "Your Overpower hits..." (used => CD)
--
-- GUID resolution:
--   SuperWoW exposes GUIDs on UnitId tokens.  We scan all visible nameplate
--   guids (WorldFrame children for Blizzard, pfUI plate list for pfUI) and
--   compare UnitName(guid) to the parsed mob name.
------------------------------------------------

local OverpowerFrame = CreateFrame("Frame", "SunderNP_OverpowerFrame", UIParent)

local overpowerActive   = false
local overpowerEndTime  = 0
local overpowerGUID     = nil   -- GUID of mob whose dodge triggered the proc

local overpowerOnCooldown = false
local overpowerCdEndTime  = 0

local function IsOverpowerActive()
  return overpowerActive and (GetTime() < overpowerEndTime)
end

local function IsOverpowerOnCooldown()
  return overpowerOnCooldown and (GetTime() < overpowerCdEndTime)
end

-- Scan visible SuperWoW GUIDs to find one whose UnitName matches mobName.
-- Returns the GUID string (SuperWoW unit token), or nil if not found.
-- NOTE: vanilla 1.12 has no UnitGUID() — SuperWoW exposes GUIDs only via
--       frame:GetName(1) on nameplate WorldFrame children.
local function FindGUIDByName(mobName)
  if not mobName then return nil end

  local frames = { WorldFrame:GetChildren() }
  for _, frame in ipairs(frames) do
    if frame:IsVisible() and frame:GetName() == nil then
      local guid = frame:GetName(1)  -- SuperWoW extension
      if guid and UnitExists(guid) then
        if UnitName(guid) == mobName then
          return guid
        end
      end
    end
  end
  return nil
end

-- Get the GUID for the current target by scanning nameplates.
-- Falls back to nil if not found (no target or SuperWoW not active).
local function GetTargetGUID()
  if not UnitExists("target") then return nil end
  local targetName = UnitName("target")
  local frames = { WorldFrame:GetChildren() }
  for _, frame in ipairs(frames) do
    if frame:IsVisible() and frame:GetName() == nil then
      local guid = frame:GetName(1)
      if guid and UnitExists(guid) then
        if UnitIsUnit(guid, "target") then
          return guid
        end
      end
    end
  end
  return nil
end

-- Parse mob name from CHAT_MSG_COMBAT_SELF_MISSES dodge lines.
-- Vanilla pattern: "<Name> dodges your <Attack>."
-- Returns name string or nil.
local function ParseDodgerName(msg)
  -- string.match doesn't exist in Lua 5.0 (WoW 1.12); use string.find with capture
  local _, _, name = string.find(msg, "^(.+) dodges")
  return name
end

OverpowerFrame:RegisterEvent("COMBAT_TEXT_UPDATE")
OverpowerFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
OverpowerFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")

OverpowerFrame:SetScript("OnEvent", function()
  local msg = arg1 or ""

  -- ── A) COMBAT_TEXT_UPDATE fires when the game itself highlights Overpower ──
  if event == "COMBAT_TEXT_UPDATE" then
    if arg1 == "SPELL_ACTIVE" and arg2 == "Overpower" then
      -- We don't know which mob dodged from this event alone.
      -- Best effort: use current target GUID if proc not already active
      -- (CHAT_MSG_COMBAT_SELF_MISSES fires first in practice and sets the GUID,
      -- so this branch mostly fires for parry procs or when the chat event races).
      if not overpowerActive then
        overpowerGUID = GetTargetGUID()
      end
      overpowerActive  = true
      overpowerEndTime = GetTime() + 4
    end

  -- ── B) CHAT_MSG_COMBAT_SELF_MISSES — dodge by a specific mob ──
  elseif event == "CHAT_MSG_COMBAT_SELF_MISSES" then
    if string.find(msg, "dodges") then
      local name = ParseDodgerName(msg)
      local guid = FindGUIDByName(name)
      -- If we got a GUID, update (or start) the proc pinned to that mob.
      -- If we couldn't resolve it, fall back to target.
      if not guid then
        guid = GetTargetGUID()
      end
      overpowerGUID    = guid
      overpowerActive  = true
      overpowerEndTime = GetTime() + 4
    end

  -- ── C) CHAT_MSG_SPELL_SELF_DAMAGE — Overpower was used => start CD ──
  elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
    if string.find(msg, "^Your Overpower") then
      overpowerOnCooldown = true
      overpowerCdEndTime  = GetTime() + 5
      overpowerActive     = false
      overpowerGUID       = nil
    end
  end
end)

OverpowerFrame:SetScript("OnUpdate", function()
  local now = GetTime()
  if overpowerActive and now >= overpowerEndTime then
    overpowerActive = false
    overpowerGUID   = nil
  end
  if overpowerOnCooldown and now >= overpowerCdEndTime then
    overpowerOnCooldown = false
  end
end)

------------------------------------------------
-- 4) Sunder Tracking
------------------------------------------------
local SunderArmorTexture = "Interface\\Icons\\Ability_Warrior_Sunder"

local function GetSunderStacks(unit)
  for i = 1, 16 do
    local name, icon, count = UnitDebuff(unit, i)
    if name == SunderArmorTexture then
      return tonumber(icon) or 0
    end
  end
  return 0
end

------------------------------------------------
-- 5) Shared helper: apply overpower display to a plate
--    guid   : SuperWoW GUID for this nameplate's mob (may be nil)
--    icon   : texture widget
--    timer  : fontstring widget
------------------------------------------------
local function UpdateOverpowerDisplay(guid, icon, timer)
  if not SunderNPDB.overpowerEnabled then
    icon:Hide()
    timer:Hide()
    timer:SetText("")
    return
  end

  -- Show only on the mob whose dodge triggered the proc
  local showOnThis = false
  if IsOverpowerActive() and overpowerGUID and guid then
    showOnThis = (guid == overpowerGUID)
  end

  if showOnThis then
    icon:Show()
    timer:Show()
    if IsOverpowerOnCooldown() then
      local cdLeft = math.floor(overpowerCdEndTime - GetTime() + 0.5)
      if cdLeft < 0 then cdLeft = 0 end
      timer:SetText(cdLeft)
      timer:SetTextColor(1, 0, 0, 1)   -- red: proc available but on CD
    else
      local windowLeft = math.floor(overpowerEndTime - GetTime() + 0.5)
      if windowLeft < 0 then windowLeft = 0 end
      timer:SetText(windowLeft)
      timer:SetTextColor(1, 1, 1, 1)   -- white: free to use
    end
  else
    icon:Hide()
    timer:Hide()
    timer:SetText("")
  end
end

------------------------------------------------
-- 6) pfUI Nameplate Hook
------------------------------------------------
local OverpowerIconTexture = "Interface\\Icons\\Ability_MeleeDamage"

local function HookPfuiNameplates()
  if not pfUI or not pfUI.nameplates then return end

  local oldOnCreate = pfUI.nameplates.OnCreate
  pfUI.nameplates.OnCreate = function(frame)
    oldOnCreate(frame)

    local plate = frame.nameplate
    if not plate or not plate.health then return end

    local sunderText = plate.health:CreateFontString(nil, "OVERLAY")
    sunderText:SetFont("Fonts\\FRIZQT__.TTF", 25, "OUTLINE")
    sunderText:SetPoint("LEFT", plate.health, "RIGHT", 15, 0)
    plate.sunderText = sunderText

    local overpowerIcon = plate.health:CreateTexture(nil, "OVERLAY")
    overpowerIcon:SetTexture(OverpowerIconTexture)
    overpowerIcon:SetWidth(32)
    overpowerIcon:SetHeight(32)
    overpowerIcon:SetPoint("TOP", plate.health, "TOP", 0, 60)
    overpowerIcon:Hide()
    plate.overpowerIcon = overpowerIcon

    local overpowerTimer = plate.health:CreateFontString(nil, "OVERLAY")
    overpowerTimer:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    overpowerTimer:SetPoint("CENTER", overpowerIcon, "CENTER", 0, 0)
    overpowerTimer:SetText("")
    overpowerTimer:Hide()
    plate.overpowerTimer = overpowerTimer
  end

  local oldOnDataChanged = pfUI.nameplates.OnDataChanged
  pfUI.nameplates.OnDataChanged = function(self, plate)
    oldOnDataChanged(self, plate)
    if not plate or not plate.sunderText or not plate.overpowerIcon or not plate.overpowerTimer then
      return
    end

    local guid = plate.parent:GetName(1)

    -- Sunder
    if guid and UnitExists(guid) then
      local stacks = GetSunderStacks(guid)
      if stacks > 0 then
        plate.sunderText:SetText(stacks)
        if     stacks == 5 then plate.sunderText:SetTextColor(0,   1,   0,   1)
        elseif stacks == 4 then plate.sunderText:SetTextColor(0,   0.6, 0,   1)
        elseif stacks == 3 then plate.sunderText:SetTextColor(1,   1,   0,   1)
        elseif stacks == 2 then plate.sunderText:SetTextColor(1,   0.647, 0, 1)
        elseif stacks == 1 then plate.sunderText:SetTextColor(1,   0,   0,   1)
        end
      else
        plate.sunderText:SetText("")
      end
    else
      plate.sunderText:SetText("")
    end

    -- Overpower: show on the mob whose dodge triggered the proc
    UpdateOverpowerDisplay(guid, plate.overpowerIcon, plate.overpowerTimer)
  end
end

------------------------------------------------
-- 7) Default Blizzard Nameplates
------------------------------------------------
local nameplateCache = {}

local function CreatePlateElements(frame)
  local sunderText = frame:CreateFontString(nil, "OVERLAY")
  sunderText:SetFont("Fonts\\FRIZQT__.TTF", 25, "OUTLINE")
  sunderText:SetPoint("RIGHT", frame, "RIGHT", 15, 0)

  local overpowerIcon = frame:CreateTexture(nil, "OVERLAY")
  overpowerIcon:SetTexture(OverpowerIconTexture)
  overpowerIcon:SetWidth(32)
  overpowerIcon:SetHeight(32)
  overpowerIcon:SetPoint("TOP", frame, "TOP", 0, 60)
  overpowerIcon:Hide()

  local overpowerTimer = frame:CreateFontString(nil, "OVERLAY")
  overpowerTimer:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
  overpowerTimer:SetPoint("CENTER", overpowerIcon, "CENTER", 0, 0)
  overpowerTimer:SetText("")
  overpowerTimer:Hide()

  nameplateCache[frame] = {
    sunderText    = sunderText,
    overpowerIcon = overpowerIcon,
    overpowerTimer = overpowerTimer,
  }
end

local function UpdateDefaultNameplates()
  local frames = { WorldFrame:GetChildren() }
  for _, frame in ipairs(frames) do
    if frame:IsVisible() and frame:GetName() == nil then
      local healthBar = frame:GetChildren()
      if healthBar and healthBar:IsObjectType("StatusBar") then
        if not nameplateCache[frame] then
          CreatePlateElements(frame)
        end
        local cache = nameplateCache[frame]

        -- Resolve GUID for this nameplate via SuperWoW
        local guid = frame:GetName(1)

        -- Sunder: use GUID if available, fall back to target heuristic
        if guid and UnitExists(guid) then
          local stacks = GetSunderStacks(guid)
          if stacks > 0 then
            cache.sunderText:SetText(stacks)
            if     stacks == 5 then cache.sunderText:SetTextColor(0,   1,   0,   1)
            elseif stacks == 4 then cache.sunderText:SetTextColor(0,   0.6, 0,   1)
            elseif stacks == 3 then cache.sunderText:SetTextColor(1,   1,   0,   1)
            elseif stacks == 2 then cache.sunderText:SetTextColor(1,   0.647, 0, 1)
            elseif stacks == 1 then cache.sunderText:SetTextColor(1,   0,   0,   1)
            end
          else
            cache.sunderText:SetText("")
          end
        else
          -- No GUID: fall back to target-only display (non-SuperWoW behavior)
          if frame:GetAlpha() == 1 and UnitExists("target") then
            local stacks = GetSunderStacks("target")
            if stacks > 0 then
              cache.sunderText:SetText(stacks)
              cache.sunderText:SetTextColor(stacks == 5 and 0 or 1, stacks == 5 and 1 or 1, 0, 1)
            else
              cache.sunderText:SetText("")
            end
          else
            cache.sunderText:SetText("")
          end
        end

        -- Overpower: GUID-based, shows on the specific dodging mob
        UpdateOverpowerDisplay(guid, cache.overpowerIcon, cache.overpowerTimer)
      end
    end
  end
end

local function HookDefaultNameplates()
  local updater = CreateFrame("Frame", "SunderNP_DefaultFrame")
  updater.tick = 0
  updater:SetScript("OnUpdate", function()
    if (this.tick or 0) > GetTime() then return end
    this.tick = GetTime() + 0.5
    UpdateDefaultNameplates()
  end)
end

------------------------------------------------
-- 8) Decide Which Hook
------------------------------------------------
if pfUI and pfUI.nameplates then
  HookPfuiNameplates()
else
  HookDefaultNameplates()
end

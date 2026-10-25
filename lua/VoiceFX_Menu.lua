script_name('VoiceFX')
script_author('HEXED Studio')
script_version('7.0')

-- Menu for the voice changer mod (libvoicefx.so v6; the v5 library still loads but has no new effects). Open with /vfx (or /voicefx).  /vfx help = text commands.
-- v7.0: 23 new voices (filters, space, FX), effect rack pages (Voice / Tone / Modulate / Crunch / Space / Robot), scrolling voice grid,
--       CPU / dropout meters on the Status page, pitch engine choice (Auto / High / Lite). Needs libvoicefx.so v6.
-- v6.0: full restyle (Voicemod-like layout): icon sidebar, search bar, voice grid, side panel with sliders,
--       floating control pill. Every icon is a PNG you can replace (see ICON FILES below).
-- The mod saves its own settings (/storage/emulated/0/voicefx.cfg) and log (/storage/emulated/0/voicefx_log.txt).
--
-- ICONS: every ic_* icon EXCEPT ic_logo now comes from fAwesome6_solid (moonloader/lib). ic_logo.png and all v_*.png
--   voice avatars stay PNG files (notes below); the other ic_*.png are only a fallback if the lib is missing.
-- ICON FILES: put the PNGs in  <moonloader>/HEXED/Icons/VoiceFX/   (same folder style as the other HEXED scripts)
--   voice avatars (256x256, circular):  v_normal v_female v_deep v_child v_monster v_chipmunk v_robot
--                                       v_giant v_alien v_goblin v_demon v_narrator v_custom
--   new in v7:  v_telephone v_radio v_megaphone v_walkie v_muffled v_underwater v_studio v_host v_echo v_cave v_stadium
--               v_chorus v_jet v_drunk v_overlord v_cyborg v_arcade v_rocker v_whisper v_vocoder v_ghost v_oldman v_villain
--   UI glyphs (128x128, white on transparent - the menu tints them):
--     ic_logo ic_nav_voices ic_nav_apps ic_nav_heart ic_nav_potion ic_nav_gear ic_back ic_search ic_close
--     ic_tab_mic ic_tab_grid ic_power ic_sliders ic_mic ic_ear ic_reset ic_volume ic_wave ic_heart_fill
-- To swap an icon: overwrite the PNG with the same name (any size), then run  /vfx icons  and reopen the menu.
-- A missing PNG never breaks the menu: it falls back to a plain letter / colored circle.

local imgui = require 'mimgui'
local ffi   = require 'ffi'

local new = imgui.new
local V2, V4 = imgui.ImVec2, imgui.ImVec4
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local LN2 = math.log(2)

-- ---------------------------------------------------------------- link to the mod (same method as the tracer menu)
local P = { ENABLED = 0, PITCH = 1, FORMANT = 2, PRESERVE = 3, GAIN = 4, GATE = 5, MIX = 6, ROBOT = 7, ROBOT_HZ = 8, MON_VOL = 9, MONITOR = 10, QUALITY = 31 }

pcall(ffi.cdef, [[
    void* dlopen(const char* name, int flags);
    void* dlsym(void* handle, const char* symbol);
]])
local SYM = { get = 'vfx_get', set = 'vfx_set', save = 'vfx_save', stat = 'vfx_stat', statf = 'vfx_statf', retry = 'vfx_hook_retry' }
local SIG = { get = 'float(*)(int)', set = 'void(*)(int,float)', save = 'void(*)(void)',
              stat = 'int(*)(int)', statf = 'float(*)(int)', retry = 'int(*)(void)' }
local fn = nil
local linkErr = 'libvoicefx.so (v6) is not loaded. Put it in the AML mods folder, Modloader ON, restart the game.'

local function bind(handle)
  local t = {}
  for k, name in pairs(SYM) do
    local s = ffi.C.dlsym(handle, name)
    if s == nil then return nil end
    t[k] = ffi.cast(SIG[k], s)
  end
  return t
end

local function linkNative()
  if fn then return true end
  -- flag 6 = RTLD_NOW | RTLD_NOLOAD: only succeeds if AML already loaded the mod
  local ok, h = pcall(function() return ffi.C.dlopen('libvoicefx.so', 6) end)
  if ok and h ~= nil then fn = bind(h) if fn then return true end end
  -- fallback: find the mod's real path in the process maps (AML may load a renamed copy)
  local f = io.open('/proc/self/maps', 'r')
  if f then
    local seen = {}
    for line in f:lines() do
      local p = line:match('(/[^%s]+%.so)')
      if p and p:find('voicefx', 1, true) and not seen[p] then
        seen[p] = true
        local ok2, h2 = pcall(function() return ffi.C.dlopen(p, 6) end)
        if ok2 and h2 ~= nil then fn = bind(h2) if fn then f:close() return true end end
      end
    end
    f:close()
  end
  return false
end

-- ---------------------------------------------------------------- state
local H = {}                       -- helper functions live here (keeps the local/upvalue counts low)
local window   = new.bool(false)
local enabled  = new.bool(false)
local preserve = new.bool(false)
local robot    = new.bool(false)
local semi     = new.float(0)      -- pitch in semitones
local formant  = new.float(1)
local gain     = new.float(0)
local gate     = new.float(-80)
local mix      = new.float(1)
local robotHz  = new.float(80)
local monitor  = new.bool(false)   -- hear myself (never saved: always starts OFF)
local monVol   = new.float(1)
local presetIx = new.int(0)
local dirtyAt  = nil

local U = {
  page = 1,                        -- 1 Voices | 2 Status | 3 Favorites | 4 Effects | 5 Settings
  fxTab = 1, scroll = 0,           -- Effects sub page / voice-grid scroll offset (reference units)
  chip = 1,                        -- category filter (see CHIPS)
  sel  = 0,                        -- selected preset index (0-based), -1 = custom
  fav  = {},
  scale = new.float(0.9),          -- menu size (Settings page)
  scaleDrag = nil,
  search = new.char[48](''),
  tex = {}, tries = {},
}

-- v7 effect rack: native parameter ids 11..31 (see voicefx.cpp). One imgui float per entry, filled / saved / pushed generically.
local XK = { 'hp', 'lp', 'bass', 'treble', 'drive', 'bits', 'down', 'tremhz', 'tremdepth', 'modmode', 'modrate', 'moddepth',
            'echoms', 'echofb', 'echomix', 'revsize', 'revmix', 'robotamt', 'vocmode', 'vochz', 'quality' }
local XM = {
  hp        = { id = 11, def = 20,    lo = 20,   hi = 2000,  step = 1,    fmt = '%.0f',  label = 'High-pass Hz (20 = off)' },
  lp        = { id = 12, def = 20000, lo = 1000, hi = 20000, step = 50,   fmt = '%.0f',  label = 'Low-pass Hz (20000 = off)' },
  bass      = { id = 13, def = 0,     lo = -12,  hi = 12,    step = 0.5,  fmt = '%+.1f', label = 'Bass (dB)' },
  treble    = { id = 14, def = 0,     lo = -12,  hi = 12,    step = 0.5,  fmt = '%+.1f', label = 'Treble (dB)' },
  drive     = { id = 15, def = 0,     lo = 0,    hi = 1,     step = 0.01, fmt = '%.2f',  label = 'Drive / distortion' },
  bits      = { id = 16, def = 16,    lo = 4,    hi = 16,    step = 1,    fmt = '%.0f',  label = 'Bit depth (16 = off)' },
  down      = { id = 17, def = 1,     lo = 1,    hi = 32,    step = 1,    fmt = '%.0f',  label = 'Sample-rate divider (1 = off)' },
  tremhz    = { id = 18, def = 5,     lo = 0.5,  hi = 20,    step = 0.1,  fmt = '%.1f',  label = 'Tremolo speed (Hz)' },
  tremdepth = { id = 19, def = 0,     lo = 0,    hi = 1,     step = 0.01, fmt = '%.2f',  label = 'Tremolo depth' },
  modmode   = { id = 20, def = 0,     lo = 0,    hi = 3,     step = 1,    fmt = '%.0f',  label = 'Modulation' },
  modrate   = { id = 21, def = 1,     lo = 0.1,  hi = 10,    step = 0.1,  fmt = '%.1f',  label = 'Modulation speed (Hz)' },
  moddepth  = { id = 22, def = 0.5,   lo = 0,    hi = 1,     step = 0.01, fmt = '%.2f',  label = 'Modulation depth' },
  echoms    = { id = 23, def = 300,   lo = 40,   hi = 1000,  step = 10,   fmt = '%.0f',  label = 'Echo time (ms)' },
  echofb    = { id = 24, def = 0.35,  lo = 0,    hi = 0.85,  step = 0.01, fmt = '%.2f',  label = 'Echo repeats' },
  echomix   = { id = 25, def = 0,     lo = 0,    hi = 1,     step = 0.01, fmt = '%.2f',  label = 'Echo level' },
  revsize   = { id = 26, def = 0.5,   lo = 0,    hi = 1,     step = 0.01, fmt = '%.2f',  label = 'Reverb size' },
  revmix    = { id = 27, def = 0,     lo = 0,    hi = 1,     step = 0.01, fmt = '%.2f',  label = 'Reverb level' },
  robotamt  = { id = 28, def = 1,     lo = 0,    hi = 1,     step = 0.01, fmt = '%.2f',  label = 'Robot amount' },
  vocmode   = { id = 29, def = 0,     lo = 0,    hi = 2,     step = 1,    fmt = '%.0f',  label = 'Vocoder' },
  vochz     = { id = 30, def = 110,   lo = 50,   hi = 400,   step = 1,    fmt = '%.0f',  label = 'Cyber voice pitch (Hz)' },
  quality   = { id = 31, def = 0,     lo = 0,    hi = 2,     step = 1,    fmt = '%.0f',  label = 'Pitch engine' },
}
local X = {}
for _, k in ipairs(XK) do X[k] = new.float(XM[k].def) end

-- native library API version (v6 = 6, the old v5 library answers 0)
function H.api()
  if not fn then return 0 end
  local ok, v = pcall(fn.stat, 8)
  return ok and v or 0
end

-- name / pitch (semitones) / formant / preserve / robot / category / icon / fallback color / fx = effect-rack values (missing = default)
local presets = {
  { name = 'Normal',   semi =   0, formant = 1.00, preserve = false, robot = false, cat = 'Clean', icon = 'v_normal',   rgb = { 0.00, 0.80, 0.90 } },
  { name = 'Female',   semi =   4, formant = 1.15, preserve = false, robot = false, cat = 'High',  icon = 'v_female',   rgb = { 0.85, 0.30, 0.75 } },
  { name = 'Deep',     semi =  -4, formant = 0.85, preserve = false, robot = false, cat = 'Deep',  icon = 'v_deep',     rgb = { 0.25, 0.40, 0.65 } },
  { name = 'Child',    semi =   7, formant = 1.25, preserve = false, robot = false, cat = 'High',  icon = 'v_child',    rgb = { 1.00, 0.75, 0.30 } },
  { name = 'Monster',  semi =  -8, formant = 0.75, preserve = false, robot = false, cat = 'Deep',  icon = 'v_monster',  rgb = { 0.30, 0.65, 0.25 } },
  { name = 'Chipmunk', semi =  10, formant = 1.00, preserve = false, robot = false, cat = 'High',  icon = 'v_chipmunk', rgb = { 0.80, 0.45, 0.15 } },
  { name = 'Robot',    semi =   0, formant = 1.00, preserve = false, robot = true,  cat = 'FX',    icon = 'v_robot',    rgb = { 0.55, 0.60, 0.65 } },
  { name = 'Giant',    semi = -10, formant = 0.70, preserve = false, robot = false, cat = 'Deep',  icon = 'v_giant',    rgb = { 0.55, 0.35, 0.20 } },
  { name = 'Alien',    semi =   5, formant = 0.80, preserve = false, robot = false, cat = 'FX',    icon = 'v_alien',    rgb = { 0.35, 0.85, 0.55 } },
  { name = 'Goblin',   semi =   6, formant = 1.40, preserve = false, robot = false, cat = 'High',  icon = 'v_goblin',   rgb = { 0.60, 0.65, 0.20 } },
  { name = 'Demon',    semi = -12, formant = 0.65, preserve = true,  robot = false, cat = 'Deep',  icon = 'v_demon',    rgb = { 0.80, 0.20, 0.15 } },
  { name = 'Narrator', semi =  -3, formant = 0.92, preserve = true,  robot = false, cat = 'Deep',  icon = 'v_narrator', rgb = { 0.80, 0.60, 0.30 } },
  -- ---- v7: filters
  { name = 'Telephone', semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Filter', icon = 'v_telephone', rgb = { 0.55, 0.62, 0.70 }, new = true, fx = { hp = 380, lp = 3200, drive = 0.12 } },
  { name = 'Radio',     semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Filter', icon = 'v_radio',     rgb = { 0.85, 0.55, 0.25 }, new = true, fx = { hp = 520, lp = 2900, drive = 0.35, bits = 12 } },
  { name = 'Megaphone', semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Filter', icon = 'v_megaphone', rgb = { 0.90, 0.30, 0.25 }, new = true, fx = { hp = 700, lp = 3800, drive = 0.55 } },
  { name = 'Walkie',    semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Filter', icon = 'v_walkie',    rgb = { 0.35, 0.55, 0.30 }, new = true, fx = { hp = 450, lp = 2600, drive = 0.20, bits = 9, down = 3 } },
  { name = 'Muffled',   semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Filter', icon = 'v_muffled',   rgb = { 0.45, 0.40, 0.55 }, new = true, fx = { lp = 1000, bass = 4 } },
  { name = 'Underwater', semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Filter', icon = 'v_underwater', rgb = { 0.15, 0.50, 0.85 }, new = true, fx = { lp = 1400, modmode = 3, modrate = 3.5, moddepth = 0.7, revmix = 0.15, revsize = 0.4 } },
  { name = 'Studio',    semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Filter', icon = 'v_studio',    rgb = { 0.70, 0.70, 0.85 }, new = true, fx = { hp = 90, treble = 5, bass = 2 } },
  { name = 'Host',      semi = -2, formant = 0.95, preserve = false, robot = false, cat = 'Filter', icon = 'v_host',     rgb = { 0.80, 0.25, 0.45 }, new = true, fx = { hp = 70, bass = 8, treble = 2, drive = 0.08 } },
  -- ---- v7: space
  { name = 'Echo',      semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Space', icon = 'v_echo',      rgb = { 0.30, 0.55, 0.90 }, new = true, fx = { echomix = 0.45, echoms = 320, echofb = 0.45 } },
  { name = 'Cave',      semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Space', icon = 'v_cave',      rgb = { 0.40, 0.35, 0.30 }, new = true, fx = { revmix = 0.60, revsize = 0.90, lp = 6000, echomix = 0.20, echoms = 180, echofb = 0.30 } },
  { name = 'Stadium',   semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Space', icon = 'v_stadium',   rgb = { 0.25, 0.65, 0.45 }, new = true, fx = { revmix = 0.40, revsize = 0.75, echomix = 0.30, echoms = 450, echofb = 0.40, hp = 150 } },
  { name = 'Chorus',    semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Space', icon = 'v_chorus',    rgb = { 0.60, 0.40, 0.85 }, new = true, fx = { modmode = 1, modrate = 0.8, moddepth = 0.7 } },
  { name = 'Jet',       semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'Space', icon = 'v_jet',       rgb = { 0.35, 0.75, 0.85 }, new = true, fx = { modmode = 2, modrate = 0.35, moddepth = 0.9 } },
  -- ---- v7: FX
  { name = 'Drunk',     semi = -1, formant = 0.97, preserve = false, robot = false, cat = 'FX', icon = 'v_drunk',     rgb = { 0.85, 0.65, 0.20 }, new = true, fx = { modmode = 3, modrate = 1.6, moddepth = 1.0 } },
  { name = 'Overlord',  semi = -1, formant = 1.00, preserve = false, robot = true,  cat = 'FX', icon = 'v_overlord',     rgb = { 0.55, 0.55, 0.70 }, new = true, robothz = 30, fx = { lp = 5000, drive = 0.15 } },
  { name = 'Cyborg',    semi = -2, formant = 1.00, preserve = false, robot = true,  cat = 'FX', icon = 'v_cyborg',    rgb = { 0.25, 0.70, 0.75 }, new = true, robothz = 150, fx = { robotamt = 0.5, modmode = 2, modrate = 0.25, moddepth = 0.5, hp = 100 } },
  { name = 'Arcade',    semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'FX', icon = 'v_arcade',     rgb = { 0.90, 0.35, 0.65 }, new = true, fx = { bits = 6, down = 6, hp = 200, lp = 6500 } },
  { name = 'Rocker',    semi = -1, formant = 1.00, preserve = false, robot = false, cat = 'FX', icon = 'v_rocker',    rgb = { 0.80, 0.20, 0.20 }, new = true, fx = { drive = 0.75, lp = 5200, hp = 120 } },
  { name = 'Whisper',   semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'FX', icon = 'v_whisper',    rgb = { 0.65, 0.65, 0.75 }, new = true, fx = { vocmode = 1, hp = 200 } },
  { name = 'Vocoder',   semi = 0, formant = 1.00, preserve = false, robot = false, cat = 'FX', icon = 'v_vocoder',    rgb = { 0.30, 0.85, 0.95 }, new = true, fx = { vocmode = 2, vochz = 110 } },
  { name = 'Ghost',     semi = -2, formant = 0.90, preserve = false, robot = false, cat = 'FX', icon = 'v_ghost',     rgb = { 0.75, 0.80, 0.90 }, new = true, fx = { revmix = 0.55, revsize = 0.85, tremhz = 3, tremdepth = 0.35, lp = 3800, echomix = 0.22, echoms = 260, echofb = 0.35 } },
  { name = 'Old Man',   semi = -3, formant = 0.93, preserve = true,  robot = false, cat = 'Deep', icon = 'v_oldman',  rgb = { 0.60, 0.50, 0.40 }, new = true, fx = { tremhz = 6, tremdepth = 0.22, lp = 4800, hp = 100 } },
  { name = 'Villain',   semi = -6, formant = 0.85, preserve = true,  robot = false, cat = 'Deep', icon = 'v_villain', rgb = { 0.45, 0.15, 0.50 }, new = true, fx = { bass = 4, revmix = 0.15, drive = 0.15 } },
}
local presetNames = {}
for i, p in ipairs(presets) do presetNames[i] = p.name end

-- find which preset (if any) matches the current settings
function H.rematch()
  U.sel = -1
  for i, p in ipairs(presets) do
    if abs(semi[0] - p.semi) < 0.15 and abs(formant[0] - p.formant) < 0.02
       and preserve[0] == p.preserve and robot[0] == p.robot then
      local same = true
      for _, k in ipairs(XK) do
        if k ~= 'quality' then
          local m = XM[k]
          local want = (p.fx and p.fx[k]) or m.def
          if abs(X[k][0] - want) > (m.hi - m.lo) * 0.012 then same = false break end
        end
      end
      if same and robot[0] and abs(robotHz[0] - (p.robothz or 80)) > 3 then same = false end
      if same then U.sel = i - 1 return end
    end
  end
end

local function pull()
  if not linkNative() then return end
  enabled[0]  = fn.get(P.ENABLED) >= 0.5
  preserve[0] = fn.get(P.PRESERVE) >= 0.5
  robot[0]    = fn.get(P.ROBOT) >= 0.5
  local pv = fn.get(P.PITCH)
  semi[0]     = (pv and pv > 0) and (12 * math.log(pv) / LN2) or 0
  formant[0]  = fn.get(P.FORMANT)
  gain[0]     = fn.get(P.GAIN)
  gate[0]     = fn.get(P.GATE)
  mix[0]      = fn.get(P.MIX)
  robotHz[0]  = fn.get(P.ROBOT_HZ)
  monitor[0]  = fn.get(P.MONITOR) >= 0.5
  monVol[0]   = fn.get(P.MON_VOL)
  if H.api() >= 6 then for _, k in ipairs(XK) do X[k][0] = fn.get(XM[k].id) end end
  H.clampAll()
  H.rematch()
end

local function setp(id, v)
  if linkNative() then fn.set(id, v) end
  dirtyAt = os.clock()
end

local function applyPreset(i)
  local p = presets[i + 1]
  if not p then return end
  semi[0], formant[0], preserve[0], robot[0] = p.semi, p.formant, p.preserve, p.robot
  mix[0] = 1
  enabled[0] = true
  presetIx[0] = i
  setp(P.PITCH, 2 ^ (p.semi / 12)); setp(P.FORMANT, p.formant)
  setp(P.PRESERVE, p.preserve and 1 or 0); setp(P.ROBOT, p.robot and 1 or 0)
  for _, k in ipairs(XK) do
    if k ~= 'quality' then local v = (p.fx and p.fx[k]) or XM[k].def; X[k][0] = v; setp(XM[k].id, v) end
  end
  robotHz[0] = p.robothz or 80; setp(P.ROBOT_HZ, robotHz[0])
  setp(P.MIX, 1); setp(P.ENABLED, 1)
  U.sel = i
end

-- keeps every slider value inside its slider range (a stored/native value outside it pins the knob to an end)
function H.clampAll()
  local function c(a, lo, hi, def)
    local v = a[0]
    if v ~= v or v == math.huge or v == -math.huge then v = def end
    if v < lo then v = lo elseif v > hi then v = hi end
    a[0] = v
  end
  c(semi, -12, 12, 0); c(formant, 0.5, 2.0, 1); c(gain, -24, 24, 0); c(gate, -80, -20, -80)
  c(mix, 0, 1, 1); c(robotHz, 20, 500, 80); c(monVol, 0, 2, 1)
  for _, k in ipairs(XK) do local m = XM[k]; c(X[k], m.lo, m.hi, m.def) end
end

function H.resetAll()
  semi[0], formant[0], mix[0], gain[0], gate[0], robotHz[0], monVol[0] = 0, 1, 1, 0, -80, 80, 1
  preserve[0], robot[0], presetIx[0] = false, false, 0
  setp(P.PITCH, 1); setp(P.FORMANT, 1); setp(P.MIX, 1); setp(P.GAIN, 0); setp(P.GATE, -80)
  setp(P.ROBOT_HZ, 80); setp(P.MON_VOL, 1); setp(P.PRESERVE, 0); setp(P.ROBOT, 0)
  for _, k in ipairs(XK) do X[k][0] = XM[k].def; setp(XM[k].id, XM[k].def) end
  H.rematch()
end

-- ---------------------------------------------------------------- chat feedback + text commands
local function say(msg)
  if type(sampAddChatMessage) == 'function' then pcall(sampAddChatMessage, '{66CCFF}[VoiceFX]{FFFFFF} ' .. msg, -1) end
  print('[VoiceFX] ' .. msg)
end
local function onOff(v) return v == 'on' or v == '1' or v == 'true' end

local function cmd(param)
  param = (param or ''):gsub('^%s+', ''):gsub('%s+$', '')
  local a, b = param:match('^(%S+)%s*(.*)$')
  a = a and a:lower() or ''
  if not linkNative() then say(linkErr) if a == '' then window[0] = not window[0] end return end
  local n = tonumber(b)
  if a == '' or a == 'menu' then
    window[0] = not window[0]; pull()
  elseif a == 'on' or a == 'off' then
    enabled[0] = (a == 'on'); setp(P.ENABLED, enabled[0] and 1 or 0); say('voice changer ' .. a)
  elseif a == 'pitch' and n then semi[0] = n; setp(P.PITCH, 2 ^ (n / 12)); say(('pitch %.1f semitones'):format(n))
  elseif a == 'formant' and n then formant[0] = n; setp(P.FORMANT, n); say('formant ' .. n)
  elseif a == 'gain' and n then gain[0] = n; setp(P.GAIN, n); say('gain ' .. n .. ' dB')
  elseif a == 'gate' and n then gate[0] = n; setp(P.GATE, n); say('noise gate ' .. n .. ' dB (-80 = off)')
  elseif a == 'mix' and n then mix[0] = n; setp(P.MIX, n); say('dry/wet ' .. n)
  elseif a == 'preserve' then preserve[0] = onOff(b); setp(P.PRESERVE, preserve[0] and 1 or 0); say('preserve formants ' .. b)
  elseif a == 'robot' then robot[0] = onOff(b); setp(P.ROBOT, robot[0] and 1 or 0); say('robot ' .. b)
  elseif a == 'robothz' and n then robotHz[0] = n; setp(P.ROBOT_HZ, n); say('robot ' .. n .. ' Hz')
  elseif a == 'hear' then
    monitor[0] = onOff(b); setp(P.MONITOR, monitor[0] and 1 or 0)
    say('hear myself ' .. b .. (monitor[0] and ' (use headphones! only plays while your mic is recording)' or ''))
  elseif a == 'hearvol' and n then monVol[0] = n; setp(P.MON_VOL, n); say('monitor volume ' .. n)
  elseif a == 'preset' then
    local hit
    for i, p in ipairs(presets) do if p.name:lower() == b:lower() then hit = i - 1 end end
    if hit then applyPreset(hit); say('preset ' .. presets[hit + 1].name .. ' (enabled)')
    else say('presets: ' .. table.concat(presetNames, ', '):lower()) end
  elseif a == 'set' then
    local key, val = b:match('^(%S+)%s+(%S+)$')
    key = key and key:lower(); val = tonumber(val)
    if key and val and XM[key] then
      X[key][0] = val; H.clampAll(); setp(XM[key].id, X[key][0]); say(key .. ' = ' .. X[key][0])
    else say('/vfx set <name> <value>   names: ' .. table.concat(XK, ' ')) end
  elseif a == 'quality' then
    local qv = ({ auto = 0, high = 1, lite = 2 })[b:lower()]
    if qv then X.quality[0] = qv; setp(XM.quality.id, qv); say('pitch engine: ' .. b:lower()) else say('/vfx quality auto|high|lite') end
  elseif a == 'icons' then
    U.tex, U.tries = {}, {}
    say('icons will be reloaded from HEXED/Icons/VoiceFX when the menu opens')
  elseif a == 'status' then
    say(('enabled=%s pitch=%.1fst formant=%.2f hook=%d sessions=%d dspCalls=%d in=%.2f out=%.2f'):format(
      tostring(fn.get(P.ENABLED) >= 0.5), 12 * math.log(fn.get(P.PITCH)) / LN2, fn.get(P.FORMANT),
      fn.stat(0), fn.stat(1), fn.stat(2), fn.statf(0), fn.statf(1)))
    say(('api=%d engine=%d cpu=%.0f%% (peak %.0f%%) underruns=%d gap-resets=%d slow-calls=%d'):format(H.api(), fn.stat(12), fn.statf(3), fn.statf(4), fn.stat(9), fn.stat(10), fn.stat(11)))
    say('hear myself: ' .. (fn.stat(7) == 1 and 'playing' or (fn.stat(7) == -1 and 'FAILED (see voicefx_log.txt)' or 'off')))
  elseif a == 'sdebug' then U.sdbg = not U.sdbg; U.dbgLine = nil; say('slider debug ' .. (U.sdbg and 'ON (drag a slider, read the red line at the top of the menu)' or 'OFF'))
  elseif a == 'hook' then say('hook state ' .. fn.retry())
  elseif a == 'save' then fn.save(); say('saved')
  else
    say('/vfx [menu] | on | off | pitch <-12..12> | formant <0.5..2> | gain <dB> | gate <-80..-20> | mix <0..1>')
    say('/vfx hear on|off | hearvol <0..2> | preserve on|off | robot on|off | robothz <Hz> | preset <name> | set <name> <v> | quality auto|high|lite | status | hook | save | icons')
  end
  H.rematch()
end

-- ---------------------------------------------------------------- UI toolkit
-- Everything below is laid out in a 1000x620 "reference space" and scaled to the window, so the menu keeps
-- its proportions on any screen. Menu size can be changed on the Settings page (gear icon).
local RW, RH = 1000, 620
local F = { ox = 0, oy = 0, k = 1, fs = 1, base = 13, dl = nil }

-- corner flag for rounded rects (differs between mimgui/imgui versions)
local RC = 0
pcall(function()
  if imgui.DrawFlags and imgui.DrawFlags.RoundCornersAll then RC = imgui.DrawFlags.RoundCornersAll
  elseif imgui.DrawCornerFlags and imgui.DrawCornerFlags.All then RC = imgui.DrawCornerFlags.All end
end)

local function rgba(r, g, b, a)
  a = a or 1
  return floor(a * 255 + 0.5) * 16777216 + floor(b * 255 + 0.5) * 65536 + floor(g * 255 + 0.5) * 256 + floor(r * 255 + 0.5)
end

local COL = {
  white = rgba(1, 1, 1, 1),         text  = rgba(0.93, 0.95, 0.97, 1), dim   = rgba(0.52, 0.55, 0.60, 1),
  dim2  = rgba(0.34, 0.37, 0.41, 1), cyan  = rgba(0.00, 0.90, 1.00, 1), cyanD = rgba(0.00, 0.50, 0.58, 1),
  dark  = rgba(0.02, 0.025, 0.03, 1), bg1  = rgba(0.030, 0.034, 0.038, 1), bg2 = rgba(0.085, 0.090, 0.098, 1),
  bg3   = rgba(0.115, 0.122, 0.132, 1), bg4 = rgba(0.16, 0.17, 0.185, 1), panel = rgba(0.075, 0.078, 0.086, 1),
  pill  = rgba(0.060, 0.064, 0.070, 1), line = rgba(0.140, 0.150, 0.165, 1), fill = rgba(0.19, 0.205, 0.225, 1),
  good  = rgba(0.25, 0.90, 0.45, 1), bad   = rgba(1.00, 0.35, 0.30, 1), badge = rgba(0.10, 0.32, 1.00, 1),
}

local WORKDIR = (type(getWorkingDirectory) == 'function') and getWorkingDirectory() or '.'
local ICON_DIR = WORKDIR .. '/HEXED/Icons/VoiceFX/'
local FAVFILE  = WORKDIR .. '/config/VoiceFX_favorites.txt'
local CFGFILE  = WORKDIR .. '/config/VoiceFX_settings.cfg'   -- auto-saved menu + voice settings

local ICON_LIST = {
  'ic_logo', 'ic_nav_voices', 'ic_nav_apps', 'ic_nav_heart', 'ic_nav_potion', 'ic_nav_gear', 'ic_back', 'ic_search',
  'ic_close', 'ic_tab_mic', 'ic_tab_grid', 'ic_power', 'ic_sliders', 'ic_mic', 'ic_ear', 'ic_reset', 'ic_volume',
  'ic_wave', 'ic_heart_fill', 'v_custom',
}
for _, p in ipairs(presets) do ICON_LIST[#ICON_LIST + 1] = p.icon end

-- load a PNG once (nil if the file is missing -> callers draw a fallback)
function H.icon(name)
  local t = U.tex[name]
  if t ~= nil then return t end
  local tries = U.tries[name] or 0
  if tries >= 3 then return nil end
  local path = ICON_DIR .. name .. '.png'
  local f = io.open(path, 'rb')
  if not f then U.tries[name] = 3 return nil end
  f:close()
  U.tries[name] = tries + 1
  local ok, tex = pcall(imgui.CreateTextureFromFile, path)
  if ok and tex ~= nil then U.tex[name] = tex return tex end
  return nil
end

-- ---------------------------------------------------------------- Font Awesome icons (same method as the HEXED HUD)
-- All ic_* icons except ic_logo (stays PNG) are drawn from Font Awesome 6 glyphs. Same setup as HEXED_FIVEMSTYLEHUD:
--   require 'fAwesome6_solid'  ->  fa.Init(14.0) in OnInitialize (builds the merged font in _G.icon)
--   -> imgui.PushFont(_G.icon) around the window  ->  glyphs are fa.NAME constants.
-- If only the plain fAwesome6.lua is installed, the glyph font is merged manually instead.
-- If neither lib exists the menu falls back to the old PNG files / plain letters, so nothing breaks.
local okFa, fa = pcall(require, 'fAwesome6_solid')
if not okFa then okFa, fa = pcall(require, 'fAwesome6') end
H.faReady = false
local FA_MAP = {
  ic_nav_voices = 'MASKS_THEATER', ic_nav_apps = 'SIGNAL', ic_nav_heart = 'HEART',
  ic_nav_potion = 'FLASK', ic_nav_gear = 'GEAR', ic_back = 'ARROW_LEFT', ic_search = 'MAGNIFYING_GLASS',
  ic_close = 'XMARK', ic_tab_mic = 'MICROPHONE', ic_tab_grid = 'TABLE_CELLS_LARGE', ic_power = 'POWER_OFF',
  ic_sliders = 'SLIDERS', ic_mic = 'MICROPHONE', ic_ear = 'EAR_LISTEN', ic_reset = 'ROTATE_LEFT',
  ic_volume = 'VOLUME_HIGH', ic_wave = 'WAVE_SQUARE', ic_heart_fill = 'HEART',
}

-- menu font: Arial_Bold.ttf (first match wins). Put it in  <moonloader>/resource/HEXED/  (or any folder below)
local FONT_FILE = 'Arial_Bold.ttf'
local FONT_DIRS = { '/resource/HEXED/', '/resource/fonts/', '/resource/', '/HEXED/Fonts/', '/HEXED/', '/lib/', '/config/', '/' }
function H.findFont()
  for _, d in ipairs(FONT_DIRS) do
    local p = WORKDIR .. d .. FONT_FILE
    local f = io.open(p, 'rb')
    if f then f:close() return p end
  end
end

imgui.OnInitialize(function()
  -- 1) menu text font (added first so it is the font the whole menu is drawn with)
  local fp = H.findFont()
  if fp then
    local ok, font = pcall(function()
      local fonts = imgui.GetIO().Fonts
      return fonts:AddFontFromFileTTF(fp, 14.0, nil, fonts:GetGlyphRangesCyrillic())
    end)
    if ok and font then H.textFont = font else print('[VoiceFX] could not load ' .. fp) end
  else
    print('[VoiceFX] ' .. FONT_FILE .. ' not found in ' .. WORKDIR .. '/resource/HEXED/ - using the default font')
  end
  -- 2) Font Awesome glyph font
  if not (okFa and type(fa) == 'table') then
    print('[VoiceFX] fAwesome6 lib not found - using PNG icons')
    return
  end
  local ok, err = pcall(function()
    if type(fa.Init) == 'function' then
      fa.Init(14.0)                                   -- fAwesome6_solid: builds _G.icon (base font + FA glyphs)
      H.iconFont = _G.icon
    else
      local cfg = imgui.ImFontConfig()                -- plain fAwesome6: merge the solid font by hand
      cfg.MergeMode = true
      cfg.PixelSnapH = true
      H.faRanges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0)   -- kept alive on purpose
      imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), 14, cfg, H.faRanges)
    end
  end)
  H.faReady = ok
  if not ok then print('[VoiceFX] fAwesome6 font failed: ' .. tostring(err)) end
end)

imgui.OnInitialize(function()
  for _, name in ipairs(ICON_LIST) do
    if not (H.faReady and FA_MAP[name] and rawget(fa, FA_MAP[name])) then H.icon(name) end   -- Font Awesome replaces the ic_* PNGs
  end
end)

function H.loadFavs()
  local f = io.open(FAVFILE, 'r')
  if not f then return end
  for line in f:lines() do
    line = line:gsub('%s+$', '')
    if line ~= '' then U.fav[line] = true end
  end
  f:close()
end

function H.saveFavs()
  local f = io.open(FAVFILE, 'w')
  if not f then return end
  for _, p in ipairs(presets) do if U.fav[p.name] then f:write(p.name, '\n') end end
  f:close()
end

-- ---------------------------------------------------------------- auto save / auto load
-- Everything (menu size, voice, effects, sliders, on/off) is written to VoiceFX_settings.cfg a moment after
-- any change, and restored + pushed to the mod the next time the game starts. "Hear myself" always starts OFF.
function H.cfgSnapshot()
  local t = {
    'ver=3',
    ('scale=%.2f'):format(U.scale[0]),
    ('enabled=%d'):format(enabled[0] and 1 or 0),
    ('preserve=%d'):format(preserve[0] and 1 or 0),
    ('robot=%d'):format(robot[0] and 1 or 0),
    ('semi=%.4f'):format(semi[0]),
    ('formant=%.4f'):format(formant[0]),
    ('gain=%.4f'):format(gain[0]),
    ('gate=%.4f'):format(gate[0]),
    ('mix=%.4f'):format(mix[0]),
    ('robothz=%.4f'):format(robotHz[0]),
    ('monvol=%.4f'):format(monVol[0]),
  }
  for _, k in ipairs(XK) do t[#t + 1] = ('%s=%.4f'):format(k, X[k][0]) end
  return table.concat(t, '\n') .. '\n'
end

H.lastCfg = nil

function H.saveCfg()
  local snap = H.cfgSnapshot()
  if snap == H.lastCfg then return end
  local f = io.open(CFGFILE, 'w')
  if not f then return end
  f:write(snap)
  f:close()
  H.lastCfg = snap
end

-- reads the file into the UI variables; returns true if a file was found
function H.loadCfg()
  local f = io.open(CFGFILE, 'r')
  if not f then return false end
  local t = {}
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.+)$')
    if k and tonumber(v) then t[k] = tonumber(v) end
  end
  f:close()
  if t.scale then U.scale[0] = max(0.5, min(0.9, t.scale)) end
  if t.enabled  then enabled[0]  = t.enabled  >= 0.5 end
  if t.preserve then preserve[0] = t.preserve >= 0.5 end
  if t.robot    then robot[0]    = t.robot    >= 0.5 end
  if t.semi     then semi[0]     = t.semi end
  if t.formant  then formant[0]  = t.formant end
  if t.gain     then gain[0]     = t.gain end
  if t.gate     then gate[0]     = t.gate end
  if t.mix      then mix[0]      = t.mix end
  if t.robothz  then robotHz[0]  = t.robothz end
  if t.monvol   then monVol[0]   = t.monvol end
  for _, k in ipairs(XK) do if t[k] then X[k][0] = t[k] end end
  -- v6.2 migration: files written by v6.1 (no 'ver=' line) hold slider values that the broken v6.1 sliders pinned to
  -- their minimum/maximum (gain -24, mix 0, robot Hz 20, monitor 0 ...). Reset those once; pitch/formant/toggles stay.
  if (t.ver or 1) < 2 then
    gain[0], gate[0], mix[0], robotHz[0], monVol[0] = 0, -80, 1, 80, 1
  end
  H.clampAll()
  H.rematch()
  H.lastCfg = nil                    -- forces the next saveCfg() to write the new 'ver=2' file
  return true
end

-- pushes the loaded values into the native mod
function H.pushAll()
  fn.set(P.PITCH, 2 ^ (semi[0] / 12)); fn.set(P.FORMANT, formant[0])
  fn.set(P.PRESERVE, preserve[0] and 1 or 0); fn.set(P.ROBOT, robot[0] and 1 or 0)
  fn.set(P.GAIN, gain[0]); fn.set(P.GATE, gate[0]); fn.set(P.MIX, mix[0])
  fn.set(P.ROBOT_HZ, robotHz[0]); fn.set(P.MON_VOL, monVol[0])
  for _, k in ipairs(XK) do fn.set(XM[k].id, X[k][0]) end
  fn.set(P.ENABLED, enabled[0] and 1 or 0)
  fn.save()
end

function onScriptTerminate(scr)
  if scr == script.this and H.ready then pcall(H.saveCfg) end
end

-- primitives (all positions in reference units)
function H.R(x, y, w, h, col, r)
  local k = F.k
  F.dl:AddRectFilled(V2(F.ox + x * k, F.oy + y * k), V2(F.ox + (x + w) * k, F.oy + (y + h) * k), col, (r or 0) * k, RC)
end

function H.RO(x, y, w, h, col, r, th)
  local k = F.k
  F.dl:AddRect(V2(F.ox + x * k, F.oy + y * k), V2(F.ox + (x + w) * k, F.oy + (y + h) * k), col, (r or 0) * k, RC, (th or 1) * k)
end

function H.CI(cx, cy, rad, col)
  F.dl:AddCircleFilled(V2(F.ox + cx * F.k, F.oy + cy * F.k), rad * F.k, col, 48)
end

function H.CIO(cx, cy, rad, col, th)
  F.dl:AddCircle(V2(F.ox + cx * F.k, F.oy + cy * F.k), rad * F.k, col, 48, (th or 1) * F.k)
end

-- text: y is the vertical centre; al = 'l' | 'c' | 'r'; sc is relative size (1 = 14 reference units)
function H.T(x, y, str, col, sc, al)
  imgui.SetWindowFontScale(F.fs * (sc or 1))
  local sz = imgui.CalcTextSize(str)
  local px = F.ox + x * F.k
  if al == 'c' then px = px - sz.x / 2 elseif al == 'r' then px = px - sz.x end
  F.dl:AddText(V2(px, F.oy + y * F.k - sz.y / 2), col, str)
end

function H.TW(str, sc)
  imgui.SetWindowFontScale(F.fs * (sc or 1))
  return imgui.CalcTextSize(str).x / F.k
end

function H.IMG(name, cx, cy, size, tint)
  local tex = H.icon(name)
  if tex == nil then return false end
  local h, k = size / 2, F.k
  F.dl:AddImage(tex, V2(F.ox + (cx - h) * k, F.oy + (cy - h) * k), V2(F.ox + (cx + h) * k, F.oy + (cy + h) * k),
    V2(0, 0), V2(1, 1), tint or COL.white)
  return true
end

-- icon with a plain-text fallback when the PNG is missing
function H.IC(name, cx, cy, size, tint, fb)
  local fname = FA_MAP[name]
  local glyph = H.faReady and fname and rawget(fa, fname)   -- fa.NAME constant (rawget: the lib's __index recurses on unknown names)
  if glyph then
    local pushed = H.textFont and H.iconFont
    if pushed then imgui.PushFont(H.iconFont) end          -- glyphs live in the Font Awesome font, text in Arial
    H.T(cx, cy, glyph, tint or COL.white, size / 14, 'c')
    if pushed then imgui.PopFont() end
    return
  end
  if not H.IMG(name, cx, cy, size, tint) and fb then H.T(cx, cy, fb, tint or COL.white, size / 14, 'c') end
end

-- invisible touch area -> clicked, held
function H.hit(id, x, y, w, h)
  local k = F.k
  imgui.SetCursorScreenPos(V2(F.ox + x * k, F.oy + y * k))
  local clicked = imgui.InvisibleButton('##' .. id, V2(w * k, h * k))
  return clicked, imgui.IsItemActive()
end

function H.avatar(name, rgb, cx, cy, d, label)
  if not H.IMG(name, cx, cy, d, COL.white) then
    H.CI(cx, cy, d / 2, rgba(rgb[1], rgb[2], rgb[3], 1))
    H.CIO(cx, cy, d / 2, COL.line, 2)
    H.T(cx, cy, label:sub(1, 1), COL.white, d / 30, 'c')
  end
end

-- Voicemod-style slider: label top-left, small rounded number badge top-right (READ-ONLY - pure indicator),
-- and a thin FULL-WIDTH track underneath (cyan fill + round knob).
-- TOUCH AREA = the WHOLE control (label row + badge row + track). Press anywhere and drag left/right: the knob goes
-- under your finger 1:1. For precision keep holding and slide your finger far UP or DOWN, away from the slider
-- -> x0.25 (far) / x0.05 (farther). Back near the slider = normal again.
-- v6.2: the knob position is ALWAYS computed from the value (t = (v-lo)/(hi-lo)), the touch maths uses the exact
--       rectangle ImGui hit-tests (GetItemRectMin/Max), the track is inset by the knob radius so the knob is never
--       clipped at either end, and NaN / out-of-range values can no longer pin the knob to 0 or to the end.
function H.slider(id, x, y, w, h, v, lo, hi, step, fmt, label, ic)
  local k = F.k
  local range = hi - lo
  if range <= 0 then return nil end

  v = tonumber(v) or lo
  if v ~= v then v = lo end                         -- NaN guard
  if v < lo then v = lo elseif v > hi then v = hi end

  -- label + value badge
  local textY = y + h * 0.26
  local lx = x
  if ic then
    H.IC(ic, x + 7, textY, 13, COL.dim, '')
    lx = x + 18
  end
  H.T(lx, textY, label, COL.dim2, .78, 'l')
  local bw, bh = 50, max(16, h * 0.46)
  local bx, by = x + w - bw, textY - bh / 2
  H.R(bx, by, bw, bh, COL.cyanD, bh / 2)

  -- geometry (reference units). The track is inset by the knob radius so the knob stays fully inside the control.
  local trackH = max(3, h * 0.12)
  local trackY = y + h - max(trackH + 7, h * 0.26)
  local kr = max(trackH * 1.6, h * 0.17)

  -- ONE stable ImGui item for the whole control
  local _, active = H.hit(id, x, y, w, h)

  -- screen-space rectangle of that item (exactly what ImGui hit-tests); fall back to our own maths
  local x0, x1 = F.ox + x * k, F.ox + (x + w) * k
  local okR, rmin, rmax = pcall(function() return imgui.GetItemRectMin(), imgui.GetItemRectMax() end)
  if okR and rmin and rmax and (rmax.x - rmin.x) > 4 then x0, x1 = rmin.x, rmax.x end
  local tx0 = x0 + kr * k                           -- screen x of the track start (value = lo)
  local tw  = (x1 - x0) - 2 * kr * k                -- screen width of the usable track
  if tw < 1 then tw = 1 end
  local trackCenterY = F.oy + (trackY + trackH / 2) * k

  local D = U.drag
  local changed = nil

  if active then
    -- Read the finger only while it is held (a plain tap is "active" on its press frame too).
    local mp = imgui.GetMousePos()
    local mx, my = mp.x, mp.y
    if mx == mx and my == my and mx > -1e5 and mx < 1e5 and my > -1e5 and my < 1e5 then
      if not D or D.id ~= id then D = { id = id }; U.drag = D end

      local dy = abs(my - trackCenterY) / k
      local sens = (dy > 150) and 0.05 or ((dy > 90) and 0.25 or 1)
      if D.sens ~= sens then D.sens, D.ax, D.av = sens, mx, v end   -- re-anchor when the precision mode changes

      local raw
      if sens == 1 then
        local t = (mx - tx0) / tw
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        raw = lo + t * range
      else
        raw = D.av + (mx - D.ax) / tw * range * sens
      end

      if step and step > 0 then raw = floor((raw - lo) / step + 0.5) * step + lo end
      if raw < lo then raw = lo elseif raw > hi then raw = hi end
      raw = tonumber(('%.6f'):format(raw)) or v
      if abs(raw - v) > 1e-6 then changed, v = raw, raw end

      if U.sdbg then
        U.dbgLine = ('%s  v=%.3f  t=%.2f  mx=%.0f  x0=%.0f  w=%.0f  sens=%s'):format(id, v, (v - lo) / range, mx, tx0, tw, tostring(sens))
      end
    end
  elseif D and D.id == id then
    U.drag = nil
  end

  -- badge text + knob use the (possibly just updated) value
  H.T(bx + bw / 2, by + bh / 2, fmt:format(v), COL.cyan, .76, 'c')

  local t = (v - lo) / range
  if t ~= t then t = 0 end
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local trX  = x + kr                                -- reference-space track start
  local trW  = w - 2 * kr
  local kx   = trX + trW * t
  H.R(x, trackY, w, trackH, COL.dim2, trackH / 2)
  if t > 0.002 then H.R(x, trackY, (kx - x) + 1, trackH, COL.cyan, trackH / 2) end
  H.CI(kx, trackY + trackH / 2, kr + 1.5, COL.dark)   -- thin dark ring so the knob reads on the cyan fill
  H.CI(kx, trackY + trackH / 2, kr, COL.cyan)

  return changed
end

function H.switch(id, x, y, on)
  local clicked = H.hit(id, x - 4, y - 6, 48, 34)
  H.R(x, y, 40, 22, on and COL.cyanD or COL.bg3, 11)
  H.CI(on and (x + 29) or (x + 11), y + 11, 8, on and COL.cyan or COL.dim)
  return clicked
end

function H.btn(id, x, y, w, h, label, ic, on, sc)
  local clicked, act = H.hit(id, x, y, w, h)
  sc = sc or .85
  H.R(x, y, w, h, act and COL.bg4 or COL.bg3, h / 2.5)
  if on then H.RO(x, y, w, h, COL.cyan, h / 2.5, 1.5) end
  local tint = on and COL.cyan or COL.text
  if ic then
    local sx = x + (w - (24 + H.TW(label, sc))) / 2
    H.IC(ic, sx + 9, y + h / 2, 16, on and COL.cyan or COL.dim, '')
    H.T(sx + 24, y + h / 2, label, tint, sc, 'l')
  else
    H.T(x + w / 2, y + h / 2, label, tint, sc, 'c')
  end
  return clicked
end

function H.circ(id, cx, cy, d, bg, ic, tint, fb)
  local clicked, act = H.hit(id, cx - d / 2, cy - d / 2, d, d)
  H.CI(cx, cy, d / 2, act and COL.bg4 or bg)
  H.IC(ic, cx, cy, d * 0.5, tint, fb)
  return clicked
end

function H.wrap(str, n)
  local lines, cur = {}, ''
  for word in str:gmatch('%S+') do
    if #cur + #word + 1 > n and cur ~= '' then lines[#lines + 1] = cur; cur = word
    else cur = (cur == '') and word or (cur .. ' ' .. word) end
  end
  if cur ~= '' then lines[#lines + 1] = cur end
  return lines
end

-- ---------------------------------------------------------------- window theme (no PushStyleVar, same approach as before)
local NCOL = 7
local saved = nil
local function pushTheme(k)
  local CL = imgui.Col
  imgui.PushStyleColor(CL.WindowBg, V4(0.043, 0.047, 0.052, 0.98))
  imgui.PushStyleColor(CL.Border, V4(0.14, 0.15, 0.165, 1))
  imgui.PushStyleColor(CL.Text, V4(0.93, 0.95, 0.97, 1))
  imgui.PushStyleColor(CL.FrameBg, V4(0, 0, 0, 0))
  imgui.PushStyleColor(CL.FrameBgHovered, V4(0, 0, 0, 0))
  imgui.PushStyleColor(CL.FrameBgActive, V4(0, 0, 0, 0))
  imgui.PushStyleColor(CL.PopupBg, V4(0.06, 0.065, 0.07, 1))

  local st = imgui.GetStyle()
  saved = {
    WindowRounding = st.WindowRounding, WindowBorderSize = st.WindowBorderSize,
    FrameRounding = st.FrameRounding, FrameBorderSize = st.FrameBorderSize,
    WindowPadding = V2(st.WindowPadding.x, st.WindowPadding.y),
    ItemSpacing = V2(st.ItemSpacing.x, st.ItemSpacing.y),
    FramePadding = V2(st.FramePadding.x, st.FramePadding.y),
  }
  st.WindowRounding = 14 * k
  st.WindowBorderSize = 1
  st.FrameRounding = 8 * k
  st.FrameBorderSize = 0
  st.WindowPadding = V2(0, 0)
  st.ItemSpacing = V2(0, 0)
  st.FramePadding = V2(6 * k, 4 * k)
end
local function popTheme()
  imgui.PopStyleColor(NCOL)
  if saved then
    local st = imgui.GetStyle()
    for key, v in pairs(saved) do st[key] = v end
    saved = nil
  end
end

-- ---------------------------------------------------------------- sidebar / header / tabs
local NAV = {
  { 'ic_nav_voices', 1, 'V' }, { 'ic_nav_apps', 2, 'S' }, { 'ic_nav_heart', 3, 'F' },
  { 'ic_nav_potion', 4, 'E' }, { 'ic_nav_gear', 5, 'G' },
}
local TABS = { { 'Voices', 1, 'ic_tab_mic', 'M' }, { 'Favorites', 3, 'ic_nav_heart', 'F' }, { 'Effects', 4, 'ic_tab_grid', 'E' } }
local CHIPS = { 'All', 'High', 'Deep', 'FX', 'Filter', 'Space' }

function H.drawSidebar()
  H.IC('ic_logo', 30, 50, 30, COL.white, 'VFX')
  for i, n in ipairs(NAV) do
    local cy = 112 + (i - 1) * 52
    local clicked = H.hit('nav' .. i, 10, cy - 20, 40, 40)
    local sel = (U.page == n[2])
    if sel then H.R(11, cy - 19, 38, 38, COL.cyan, 9) end
    H.IC(n[1], 30, cy, 20, sel and COL.dark or COL.dim, n[3])
    if clicked then U.page = n[2] end
  end
end

function H.drawHeader()
  local k = F.k
  -- back
  local c1 = H.hit('back', 72, 40, 36, 36)
  H.R(72, 40, 36, 36, COL.bg2, 8)
  H.IC('ic_back', 90, 58, 16, COL.text, '<')
  if c1 then U.page = 1; ffi.fill(U.search, ffi.sizeof(U.search), 0) end
  -- search field
  H.R(116, 40, 622, 36, COL.bg2, 8)
  H.IC('ic_search', 136, 58, 16, COL.dim, '?')
  imgui.SetWindowFontScale(F.fs * .9)
  local st = imgui.GetStyle()
  st.FramePadding = V2(6 * k, max(0, (36 * k - F.fs * .9 * F.base) / 2))
  imgui.SetCursorScreenPos(V2(F.ox + 158 * k, F.oy + 40 * k))
  imgui.PushItemWidth(570 * k)
  imgui.InputText('##vfxsearch', U.search, ffi.sizeof(U.search))
  imgui.PopItemWidth()
  if ffi.string(U.search) == '' and not imgui.IsItemActive() then
    H.T(162, 58, 'Search voices', COL.dim2, .9, 'l')
  end
  -- close
  local c2 = H.hit('close', 960, 6, 30, 30)
  H.IC('ic_close', 975, 21, 13, COL.dim, 'x')
  if c2 then window[0] = false end
end

function H.drawTabs()
  if U.page == 2 or U.page == 5 then
    H.T(72, 112, U.page == 2 and 'Status' or 'Settings', COL.text, 1.3, 'l')
    return
  end
  H.R(72, 128, 666, 1, COL.line, 0)
  local x = 72
  for _, t in ipairs(TABS) do
    local w = 30 + H.TW(t[1], 1.0)
    local sel = (U.page == t[2])
    local c = H.hit('tab' .. t[2], x - 4, 94, w + 8, 34)
    H.IC(t[3], x + 10, 112, 18, sel and COL.cyan or COL.dim, t[4])
    H.T(x + 26, 112, t[1], sel and COL.white or COL.dim, 1.0, 'l')
    if sel then H.R(x, 126, w, 3, COL.cyan, 1) end
    if c then U.page = t[2] end
    x = x + w + 28
  end
end

function H.drawChips()
  H.R(72, 140, 30, 30, COL.bg2, 8)
  H.IC('ic_wave', 87, 155, 16, COL.dim, '~')
  local x = 112
  for i, name in ipairs(CHIPS) do
    local w = 26 + H.TW(name, .85)
    local c = H.hit('chip' .. i, x, 141, w, 28)
    local sel = (U.chip == i)
    H.R(x, 141, w, 28, sel and COL.text or COL.bg2, 14)
    H.T(x + w / 2, 155, name, sel and COL.dark or COL.dim, .85, 'c')
    if c then U.chip = i end
    x = x + w + 8
  end
end

-- ---------------------------------------------------------------- pages
function H.drawGrid()
  local k = F.k
  local q = ffi.string(U.search):lower()
  local list = {}
  for i, p in ipairs(presets) do
    if (U.chip == 1 or p.cat == CHIPS[U.chip])
       and (U.page ~= 3 or U.fav[p.name])
       and (q == '' or p.name:lower():find(q, 1, true)) then
      list[#list + 1] = i
    end
  end
  local X0, X1, Y0, Y1 = 72, 738, 176, 500
  local rows = math.ceil(#list / 6)
  local maxScroll = max(0, rows * 134 - (Y1 - Y0) + 6)
  local gkey = U.page .. '|' .. U.chip .. '|' .. q
  if U.gkey ~= gkey then U.gkey = gkey; U.scroll = 0 end

  -- touch / mouse drag scrolls the grid; a drag never selects a voice
  local mp = imgui.GetMousePos()
  local mx, my = (mp.x - F.ox) / k, (mp.y - F.oy) / k
  local inView = mx >= X0 and mx <= X1 and my >= Y0 and my <= Y1
  local down = imgui.IsMouseDown(0)
  local G = U.gdrag
  if inView and imgui.IsMouseClicked(0) then G = { y0 = my, s0 = U.scroll, moved = false }; U.gdrag = G end
  if G and down then
    local dy = my - G.y0
    if abs(dy) > 8 then G.moved = true end
    if G.moved then U.scroll = G.s0 - dy end
  end
  local wheel = imgui.GetIO().MouseWheel
  if inView and wheel ~= 0 then U.scroll = U.scroll - wheel * 60 end
  if U.scroll ~= U.scroll or U.scroll < 0 then U.scroll = 0 elseif U.scroll > maxScroll then U.scroll = maxScroll end
  local dragged = G and G.moved

  local clipOn = pcall(imgui.PushClipRect, V2(F.ox + X0 * k, F.oy + Y0 * k), V2(F.ox + X1 * k, F.oy + Y1 * k), true)
  for n, i in ipairs(list) do
    local p = presets[i]
    local col, row = (n - 1) % 6, floor((n - 1) / 6)
    local x, y = 87 + col * 106, 182 + row * 134 - U.scroll
    if y > Y0 - 130 and y < Y1 then
      local sel = (U.sel == i - 1)
      local clicked, act = H.hit('v' .. i, x, y, 106, 124)
      local cx, cy = x + 53, y + 46
      if sel then
        for g = 3, 1, -1 do H.CI(cx, cy, 40 + g * 5, rgba(0, 0.9, 1, 0.10 / g * 2)) end
      end
      H.avatar(p.icon, p.rgb, cx, cy, act and 74 or 80, p.name)
      if sel then H.CIO(cx, cy, 43, COL.cyan, 3) end
      if p.new then
        H.R(cx - 16, y - 2, 32, 13, COL.badge, 3)
        H.T(cx, y + 4.5, 'NEW', COL.white, .5, 'c')
      end
      if U.fav[p.name] then H.IC('ic_heart_fill', cx + 32, y + 14, 15, COL.cyan, '') end
      H.T(cx, y + 100, p.name, sel and COL.white or COL.text, .88, 'c')
      local sub = p.sub
      if not sub then
        if p.robot then sub = 'Robot'
        elseif p.semi ~= 0 then sub = ('%+.0f st'):format(p.semi)
        elseif p.fx then sub = (p.cat == 'FX') and 'Effect' or p.cat
        else sub = 'Original' end
      end
      H.T(cx, y + 116, sub, COL.dim, .68, 'c')
      if clicked and not dragged then applyPreset(i - 1) end
    end
  end
  if clipOn then imgui.PopClipRect() end
  if G and not down then U.gdrag = nil end

  if maxScroll > 0 then                                   -- thin scroll bar on the right edge
    local th = Y1 - Y0
    local bh = max(24, th * th / (rows * 134))
    H.R(734, Y0 + (U.scroll / maxScroll) * (th - bh), 3, bh, COL.dim2, 1.5)
  end
  if #list == 0 then
    H.T(405, 300, U.page == 3 and 'No favorites yet - tap the heart on a voice' or 'No voices found', COL.dim, 1.0, 'c')
  end
end

function H.row(y, label, val, col)
  H.R(72, y, 666, 26, COL.bg2, 6)
  H.T(86, y + 13, label, COL.dim, .88, 'l')
  H.T(724, y + 13, val, col or COL.text, .88, 'r')
end

function H.drawStatus()
  local hook = fn.stat(0)
  local starts, calls = fn.stat(1), fn.stat(2)
  local api = H.api()
  local y = 140
  H.row(y, 'Engine', api >= 6 and 'libvoicefx.so v6 connected' or 'old libvoicefx.so (v5) - install the v6 library',
    api >= 6 and COL.good or COL.bad); y = y + 28
  H.row(y, 'BASS hook', hook == 1 and 'OK' or (hook == -1 and 'FAILED (see voicefx_log.txt)' or 'not installed'),
    hook == 1 and COL.good or COL.bad)
  if hook ~= 1 and H.btn('rhook', 560, y - 1, 90, 28, 'Retry', nil, false, .8) then fn.retry() end
  y = y + 28
  H.row(y, 'Mic sessions / DSP calls', ('%d / %d'):format(starts, calls)); y = y + 28
  H.row(y, 'Chunk / rate / block', ('%d B / %d Hz / %d'):format(fn.stat(3), fn.stat(4), fn.stat(6))); y = y + 28
  local eng = fn.stat(12)
  local engName = (eng == 1 and 'RubberBand') or (eng == 2 and 'Lite') or 'none (direct)'
  if fn.stat(13) == 1 then engName = engName .. ' (auto-switched)' end
  H.row(y, 'Pitch engine / latency', ('%s / %.0f ms'):format(engName, fn.statf(2))); y = y + 28
  local ld = fn.statf(3)
  H.row(y, 'CPU load avg / peak', ('%.0f%% / %.0f%%'):format(ld, fn.statf(4)), ld > 70 and COL.bad or COL.text); y = y + 28
  local bad = fn.stat(9) + fn.stat(11)
  H.row(y, 'Underruns / gap resets / slow calls', ('%d / %d / %d'):format(fn.stat(9), fn.stat(10), fn.stat(11)), bad > 0 and COL.bad or COL.text); y = y + 28
  H.row(y, 'Format', fn.stat(5) == 1 and 'OK (mono 16-bit)' or '?'); y = y + 28
  local hm = fn.stat(7)
  H.row(y, 'Hear myself', hm == 1 and 'playing' or (hm == -1 and 'FAILED (see voicefx_log.txt)' or 'off'),
    hm == -1 and COL.bad or COL.text); y = y + 28
  H.row(y, 'Mic level in / out', ('%.2f / %.2f'):format(fn.statf(0), fn.statf(1)))
  if hook == 1 and starts == 0 then
    H.T(72, 450, 'Hook ready. Hold your voice-chat mic once to start recording.', COL.dim, .8, 'l')
  elseif starts > 0 and calls == 0 then
    H.T(72, 450, 'Mic records but BASS never called the effect.', COL.bad, .8, 'l')
  elseif api >= 6 and (bad > 0 or ld > 70) then
    H.T(72, 450, 'Dropouts or high CPU: set Effects > Voice > Pitch engine to Lite, or send voicefx_log.txt.', COL.bad, .8, 'l')
  end
end

local FXTABS = { 'Voice', 'Tone', 'Modulate', 'Crunch', 'Space', 'Robot' }

-- one slider for an effect-rack parameter (value is pushed to the mod right away)
function H.xs(key, y)
  local m, a = XM[key], X[key]
  local v = H.slider('x_' .. key, 72, y, 666, 38, a[0], m.lo, m.hi, m.step, m.fmt, m.label)
  if v then a[0] = v; setp(m.id, v); H.rematch() end
end

-- a row of exclusive buttons for an integer parameter (0, 1, 2 ...)
function H.xmode(key, y, names, label)
  local a, m = X[key], XM[key]
  H.T(72, y + 4, label, COL.dim2, .78, 'l')
  for i, nm in ipairs(names) do
    if H.btn('xm_' .. key .. i, 72 + (i - 1) * 152, y + 16, 140, 32, nm, nil, floor(a[0] + 0.5) == i - 1, .85) then
      a[0] = i - 1; setp(m.id, i - 1); H.rematch()
    end
  end
end

function H.drawEffects()
  local x = 72
  for i, nm in ipairs(FXTABS) do
    local w = 26 + H.TW(nm, .85)
    local c = H.hit('fxt' .. i, x, 141, w, 28)
    local sel = (U.fxTab == i)
    H.R(x, 141, w, 28, sel and COL.text or COL.bg2, 14)
    H.T(x + w / 2, 155, nm, sel and COL.dark or COL.dim, .85, 'c')
    if c then U.fxTab = i end
    x = x + w + 8
  end
  local t = U.fxTab
  if t == 1 then
    H.R(72, 184, 666, 40, COL.bg2, 8)
    H.T(90, 204, 'Preserve formants', COL.text, .95, 'l')
    if H.switch('sw_pres', 676, 193, preserve[0]) then
      preserve[0] = not preserve[0]; setp(P.PRESERVE, preserve[0] and 1 or 0); H.rematch()
    end
    H.xmode('quality', 232, { 'Auto', 'High', 'Lite' }, 'Pitch engine  (Auto drops to Lite by itself if the CPU cannot keep up)')
    local v = H.slider('s_mix2', 72, 296, 666, 38, mix[0], 0, 1, 0.01, '%.2f', 'Mix (dry/wet)')
    if v then mix[0] = v; setp(P.MIX, v) end
    v = H.slider('s_gain2', 72, 342, 666, 38, gain[0], -24, 24, 0.1, '%.1f', 'Mic gain (dB)')
    if v then gain[0] = v; setp(P.GAIN, v) end
    v = H.slider('s_gate2', 72, 388, 666, 38, gate[0], -80, -20, 1, '%.0f', 'Noise gate (dB)')
    if v then gate[0] = v; setp(P.GATE, v) end
    v = H.slider('s_mon2', 72, 434, 666, 38, monVol[0], 0, 2, 0.01, '%.2f', 'Monitor volume')
    if v then monVol[0] = v; setp(P.MON_VOL, v) end
  elseif t == 2 then
    H.xs('hp', 184); H.xs('lp', 232); H.xs('bass', 280); H.xs('treble', 328)
  elseif t == 3 then
    H.xmode('modmode', 184, { 'Off', 'Chorus', 'Flanger', 'Vibrato' }, 'Modulation')
    H.xs('modrate', 250); H.xs('moddepth', 298); H.xs('tremhz', 346); H.xs('tremdepth', 394)
  elseif t == 4 then
    H.xs('drive', 184); H.xs('bits', 232); H.xs('down', 280)
  elseif t == 5 then
    H.xs('echoms', 184); H.xs('echofb', 232); H.xs('echomix', 280); H.xs('revsize', 328); H.xs('revmix', 376)
  else
    H.R(72, 184, 666, 40, COL.bg2, 8)
    H.T(90, 204, 'Robot voice', COL.text, .95, 'l')
    if H.switch('sw_robot', 676, 193, robot[0]) then
      robot[0] = not robot[0]; setp(P.ROBOT, robot[0] and 1 or 0); H.rematch()
    end
    local v = H.slider('s_rhz', 72, 232, 666, 38, robotHz[0], 20, 500, 1, '%.0f', 'Robot Hz')
    if v then robotHz[0] = v; setp(P.ROBOT_HZ, v); H.rematch() end
    H.xs('robotamt', 280)
    H.xmode('vocmode', 328, { 'Off', 'Whisper', 'Cyber' }, 'Vocoder  (keeps what you say, replaces the voice)')
    H.xs('vochz', 392)
  end
  if H.api() < 6 then
    H.T(72, 486, 'Old libvoicefx.so: the new effects need the v6 library (see README).', COL.bad, .8, 'l')
  end
end

function H.drawSettings()
  H.T(72, 166, 'Menu size', COL.text, .95, 'l')
  local sizes = { 0.50, 0.60, 0.70, 0.80, 0.90 }
  local bw, gap = 118, 19
  for i, sv in ipairs(sizes) do
    local on = math.abs(U.scale[0] - sv) < 0.001
    if H.btn('sz' .. i, 72 + (i - 1) * (bw + gap), 184, bw, 36, ('%.2f'):format(sv), nil, on, .9) then
      U.scale[0] = sv
    end
  end
  H.T(72, 240, 'Tap a size to apply it.', COL.dim, .75, 'l')
  local path = ICON_DIR
  if #path > 78 then path = '...' .. path:sub(-75) end
  H.T(72, 280, 'Icons folder (replace any PNG, then /vfx icons):', COL.dim, .8, 'l')
  H.T(72, 302, path, COL.text, .72, 'l')
  H.T(72, 336, 'Mod settings: /storage/emulated/0/voicefx.cfg', COL.dim, .78, 'l')
  H.T(72, 358, 'Mod log: /storage/emulated/0/voicefx_log.txt', COL.dim, .78, 'l')
  if H.btn('save', 72, 390, 150, 36, 'Save now', nil, false, .88) then fn.save(); say('saved') end
  if H.btn('closem', 234, 390, 150, 36, 'Close menu', nil, false, .88) then window[0] = false end
  H.T(72, 450, 'VoiceFX menu v7.0 - HEXED Studio', COL.dim2, .78, 'l')
end

-- ---------------------------------------------------------------- right panel (selected voice + sliders)
function H.drawPanel()
  local p = presets[U.sel + 1]
  local name = p and p.name or 'Custom'
  H.R(748, 40, 244, 566, COL.panel, 12)
  H.T(764, 62, name, COL.text, 1.15, 'l')
  if H.hit('reset1', 950, 48, 28, 28) then H.resetAll() end
  H.IC('ic_reset', 964, 62, 18, COL.dim, 'R')

  -- big avatar with a glow while the changer is on
  if enabled[0] then
    for g = 3, 1, -1 do H.CI(870, 150, 62 + g * 6, rgba(0, 0.9, 1, 0.12 / g * 2)) end
  end
  H.avatar(p and p.icon or 'v_custom', p and p.rgb or { 0.2, 0.25, 0.3 }, 870, 150, 124, name)

  -- on/off pill + favorite heart
  local on = enabled[0]
  if H.hit('en1', 804, 230, 132, 28) then
    enabled[0] = not enabled[0]; setp(P.ENABLED, enabled[0] and 1 or 0)
  end
  H.R(804, 230, 132, 28, COL.bg3, 8)
  if on then H.RO(804, 230, 132, 28, COL.cyan, 8, 1.5) end
  H.IC('ic_power', 822, 244, 16, on and COL.cyan or COL.dim, 'O')
  H.T(836, 244, on and 'Voice ON' or 'Voice OFF', on and COL.cyan or COL.text, .85, 'l')
  if p then
    if H.hit('fav', 948, 231, 26, 26) then U.fav[p.name] = (not U.fav[p.name]) or nil; H.saveFavs() end
    if U.fav[p.name] then H.IC('ic_heart_fill', 961, 244, 18, COL.cyan, '')
    else H.IC('ic_nav_heart', 961, 244, 18, COL.dim, '') end
  end
  H.T(870, 276, 'by HEXED Studio', COL.dim2, .7, 'c')

  -- sliders
  local v = H.slider('s_gain', 760, 296, 220, 32, gain[0], -24, 24, 0.1, '%.1f', 'Mic gain', 'ic_volume')
  if v then gain[0] = v; setp(P.GAIN, v) end
  v = H.slider('s_pitch', 760, 342, 220, 32, semi[0], -12, 12, 0.1, '%+.1f', 'Pitch')
  if v then semi[0] = v; setp(P.PITCH, 2 ^ (v / 12)); H.rematch() end
  v = H.slider('s_form', 760, 376, 220, 32, formant[0], 0.5, 2.0, 0.01, '%.2f', 'Formant')
  if v then formant[0] = v; setp(P.FORMANT, v); H.rematch() end
  v = H.slider('s_mix', 760, 410, 220, 32, mix[0], 0, 1, 0.01, '%.2f', 'Mix')
  if v then mix[0] = v; setp(P.MIX, v) end
  v = H.slider('s_gate', 760, 456, 220, 32, gate[0], -80, -20, 1, '%.0f', 'Noise gate')
  if v then gate[0] = v; setp(P.GATE, v) end

  if H.btn('t_pres', 760, 500, 110, 30, 'Preserve', nil, preserve[0], .8) then
    preserve[0] = not preserve[0]; setp(P.PRESERVE, preserve[0] and 1 or 0); H.rematch()
  end
  if H.btn('t_robot', 876, 500, 110, 30, 'Robot', nil, robot[0], .8) then
    robot[0] = not robot[0]; setp(P.ROBOT, robot[0] and 1 or 0); H.rematch()
  end
  if monitor[0] then
    v = H.slider('s_mon', 760, 540, 220, 32, monVol[0], 0, 2, 0.01, '%.2f', 'Monitor vol')
    if v then monVol[0] = v; setp(P.MON_VOL, v) end
  end
end

-- ---------------------------------------------------------------- floating control pill + footer
function H.drawPill()
  H.R(255, 510, 300, 58, COL.pill, 29)
  H.RO(255, 510, 300, 58, COL.line, 29, 1)
  local on = enabled[0]
  if H.circ('pw', 285, 539, 34, on and COL.cyan or COL.bg3, 'ic_power', on and COL.dark or COL.dim, 'O') then
    enabled[0] = not enabled[0]; setp(P.ENABLED, enabled[0] and 1 or 0)
  end
  if H.circ('fx', 336, 539, 34, COL.bg3, 'ic_sliders', COL.text, 'E') then U.page = 4 end
  local mon = monitor[0]
  if H.circ('ear', 474, 539, 34, mon and COL.cyan or COL.bg3, 'ic_ear', mon and COL.dark or COL.dim, 'H') then
    monitor[0] = not monitor[0]; setp(P.MONITOR, monitor[0] and 1 or 0)
  end
  if H.circ('rs', 525, 539, 34, COL.bg3, 'ic_reset', COL.dim, 'R') then H.resetAll() end

  -- big mic: re-applies the selected voice and turns the changer on; glows with your mic level
  local lvl = max(0, min(1, fn and fn.statf(0) or 0))
  local clicked = H.hit('bigmic', 373, 500, 64, 64)
  if on then
    for g = 3, 1, -1 do H.CI(405, 532, 32 + g * 7, rgba(0, 0.9, 1, (0.16 + 0.25 * lvl) / g)) end
  end
  H.CI(405, 532, 32, on and COL.cyan or COL.bg3)
  H.IC('ic_mic', 405, 532, 30, on and COL.dark or COL.text, 'M')
  if clicked then
    if U.sel >= 0 then applyPreset(U.sel) else enabled[0] = true; setp(P.ENABLED, 1) end
  end
end

function H.drawFooter()
  local hook = fn.stat(0)
  local ver = 'v' .. (H.api() >= 6 and H.api() or 5)
  local txt = hook == 1 and ('Connected to libvoicefx ' .. ver .. ' - BASS hook OK')
    or (hook == -1 and ('libvoicefx ' .. ver .. ' loaded - hook FAILED') or ('libvoicefx ' .. ver .. ' loaded - hook not installed'))
  local w = 30 + H.TW(txt, .7)
  local x = 405 - w / 2
  H.R(x, 582, w, 20, COL.pill, 10)
  H.CI(x + 12, 592, 3.5, hook == 1 and COL.good or COL.bad)
  H.T(x + 22, 592, txt, COL.dim, .7, 'l')
end

function H.drawOffline()
  H.R(170, 190, 500, 220, COL.bg2, 14)
  H.T(420, 224, 'Engine not found', COL.bad, 1.3, 'c')
  local y = 262
  for _, line in ipairs(H.wrap(linkErr, 52)) do
    H.T(420, y, line, COL.text, .88, 'c')
    y = y + 22
  end
  if H.btn('retry', 330, 350, 180, 36, 'Retry', 'ic_reset', false, .9) then
    if linkNative() then pull() end
  end
end

function H.drawAll()
  H.drawSidebar()
  H.drawHeader()
  if not linkNative() then
    H.drawOffline()
    return
  end
  H.drawTabs()
  if U.page == 1 or U.page == 3 then
    H.drawChips(); H.drawGrid()
  elseif U.page == 2 then
    H.drawStatus()
  elseif U.page == 4 then
    H.drawEffects()
  else
    H.drawSettings()
  end
  H.drawPanel()
  H.drawPill()
  H.drawFooter()
  if U.sdbg and U.dbgLine then H.T(72, 14, U.dbgLine, COL.bad, .7, 'l') end
end

imgui.OnFrame(function() return window[0] end, function()
  local io = imgui.GetIO()
  local ds = io.DisplaySize
  local hh = ds.y * 0.90
  local ww = hh * RW / RH
  if ww > ds.x * 0.96 then ww = ds.x * 0.96; hh = ww * RH / RW end
  ww, hh = ww * U.scale[0], hh * U.scale[0]
  local k = ww / RW

  imgui.SetNextWindowSize(V2(ww, hh), imgui.Cond.Always)
  imgui.SetNextWindowPos(V2(ds.x / 2, ds.y / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))

  pushTheme(k)
  imgui.Begin('##voicefx', window, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoScrollbar
    + imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)
  local pushedIcon = false
  local wfont = H.textFont or (H.faReady and _G.icon) or nil     -- Arial Bold, else the merged FA6 base font
  if wfont then imgui.PushFont(wfont); pushedIcon = true end
  imgui.SetWindowFontScale(1.0)
  local wp = imgui.GetWindowPos()
  F.ox, F.oy, F.k, F.dl = wp.x, wp.y, k, imgui.GetWindowDrawList()
  F.base = imgui.GetFontSize()
  F.fs = 14 * k / F.base

  local ok, err = pcall(H.drawAll)
  if pushedIcon then imgui.PopFont() end
  imgui.End()
  popTheme()
  if not ok then
    print('[VoiceFX] menu error: ' .. tostring(err))
    window[0] = false
  end
end)

-- ---------------------------------------------------------------- main
function main()
  while not isSampAvailable() do wait(100) end
  sampRegisterChatCommand('vfx', cmd)
  sampRegisterChatCommand('voicefx', cmd)
  H.loadFavs()
  local hadCfg = H.loadCfg()        -- restores menu size + all voice settings from the last session
  H.ready = hadCfg                  -- auto-save only starts once real values are loaded (never overwrites with defaults)
  local synced = false
  while true do
    if not synced and linkNative() then
      if hadCfg then H.pushAll() else pull(); H.ready = true end
      synced = true
    end
    wait(500)
    if dirtyAt and os.clock() - dirtyAt > 1.0 and fn then fn.save(); dirtyAt = nil end
    if H.ready then H.saveCfg() end
  end
end

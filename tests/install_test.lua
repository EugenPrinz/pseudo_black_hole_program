-- Тест установщика install.lua на моках OpenOS (Lua 5.3, вне Minecraft).
--   lua5.3 tests/install_test.lua
-- Проверяет: полная установка с автоопределением сторон, нестандартная раскладка,
-- режим update (бэкап, стороны не трогаются), режим sides.

local unpack = table.unpack
local SIDES = { down = 0, up = 1, north = 2, south = 3, west = 4, east = 5 }
-- как настоящая таблица sides в OpenOS: число → первое имя (bottom/top/back/front/right/left)
local SIDES_FULL = {
  [0] = "bottom", [1] = "top", [2] = "back", [3] = "front", [4] = "right", [5] = "left",
  bottom = 0, top = 1, back = 2, front = 3, right = 4, left = 5,
  down = 0, up = 1, north = 2, south = 3, west = 4, east = 5,
}

local failures = 0
local function check(cond, msg)
  print((cond and "  [ok] " or "  [FAIL] ") .. msg)
  if not cond then failures = failures + 1 end
end

local function sh(cmd) return os.execute(cmd) end
local function readAll(path) local f = io.open(path) if not f then return nil end local d = f:read("*a") f:close() return d end

-- ---------------- сборка окружения под сценарий ----------------
local function makeEnv(world)
  local T = 0
  local inputs = {}
  for s = 0, 5 do inputs[s] = 0 end
  for s, v in pairs(world.inputs or {}) do inputs[s] = v end
  local queue = {}

  local comps = {
    internet = {},
    gt_machine = {}, screen = {},
    gpu = { maxResolution = function() return 160, 50 end },
    redstone = {
      address = "rs-1",
      getInput = function(side) return inputs[side] end,
    },
    transposer = {
      getInventorySize = function(side) local inv = world.inv[side] return inv and inv.size or nil end,
      getStackInSlot = function(side, slot)
        local inv = world.inv[side]
        if not inv then return nil end
        local it = inv.slots[slot]
        if not it then return nil end
        return { size = 16, label = it, name = "gregtech:gt.metaitem.01" }
      end,
      getFluidInTank = function(side)
        if side == world.stocker then return { amount = 1000, name = "molten.spacetime", label = "Molten SpaceTime" } end
        return nil
      end,
    },
  }
  if world.noInternet then comps.internet = nil end
  local env = {}
  env.component = setmetatable({ isAvailable = function(n) return comps[n] ~= nil end }, { __index = comps })
  env.computer = { uptime = function() return T end }
  env.event = {
    pull = function(timeout, filter)
      local steps = math.floor((timeout or 1) * 20 + 0.5)
      for _ = 1, math.max(1, steps) do
        T = T + 0.05
        local tick = math.floor(T * 20 + 0.5)
        if world.pulseSide and tick % 20 == 0 then
          return "redstone_changed", "rs-1", world.pulseSide, 0, 15
        end
      end
      return nil
    end,
  }
  env.toggleReceiver = function() local s = world.receiverToggle if s then inputs[s] = inputs[s] > 0 and 0 or 15 end end
  return env
end

local function runInstaller(root, world, answers, mode)
  local env = makeEnv(world)
  package.loaded.component, package.loaded.computer, package.loaded.event = nil, nil, nil
  package.preload.component = function() return env.component end
  package.preload.computer = function() return env.computer end
  package.preload.event = function() return env.event end
  package.preload.sides = function() return SIDES_FULL end
  package.preload.serialization = function()
    local function ser(v)
      if type(v) == "table" then
        local p = {}
        for k, x in pairs(v) do p[#p + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
        table.sort(p)
        return "{" .. table.concat(p, ",") .. "}"
      elseif type(v) == "string" then return string.format("%q", v) end
      return tostring(v)
    end
    return { serialize = ser, unserialize = function(s) return load("return " .. s)() end }
  end
  package.preload.filesystem = function()
    return {
      exists = function(p) return os.execute("test -e '" .. p .. "'") == true end,
      path = function(p) return p:match("^(.*)/[^/]*$") or "" end,
      makeDirectory = function(p) return os.execute("mkdir -p '" .. p .. "'") end,
      rename = function(a, b) return os.rename(a, b) end,
      remove = function(p) return os.remove(p) end,
    }
  end
  package.preload.internet = function()
    return {
      request = function(url)
        local path = url:match("/main/(.+)$")
        local data = readAll(path)
        if not data then error("404 " .. url) end
        local i = 0
        return function()
          if i >= #data then return nil end
          local chunk = data:sub(i + 1, i + 4096)
          i = i + 4096
          return chunk
        end
      end,
    }
  end
  for _, m in ipairs({ "sides", "serialization", "filesystem", "internet" }) do package.loaded[m] = nil end

  local out = {}
  local realWrite, realRead = io.write, io.read
  local ai = 0
  io.write = function(...) for _, v in ipairs({ ... }) do out[#out + 1] = tostring(v) end end
  io.read = function()
    ai = ai + 1
    local a = answers[ai]
    if a == "<toggle>" then env.toggleReceiver(); a = "" end
    out[#out + 1] = (a or "<EOF>") .. "\n"
    return a
  end
  BHC_ROOT = root
  local chunk = assert(loadfile("install.lua"))
  local ok, err = pcall(chunk, mode)
  io.write, io.read = realWrite, realRead
  BHC_ROOT = nil
  return table.concat(out), ok, err, ai
end

local function readHw(root)
  local d = readAll(root .. "/home/bhc-hw.cfg")
  return d and load("return " .. d)() or nil
end

-- ======================== сценарий 1: стандартная раскладка ========================
print("1) Полная установка, раскладка как на вики")
local root = os.tmpname(); os.remove(root); sh("mkdir -p " .. root .. "/home")
local world = {
  inv = {
    [5] = { size = 9, slots = { "Black Hole Seed", "Black Hole Collapser" } },   -- east: ME interface
    [0] = { size = 4, slots = {} },                                              -- down: input bus
  },
  stocker = 1, receiverToggle = 4, pulseSide = 0,
}
-- ответы: 5 вопросов transposer'а по умолчанию, Enter после переключения рычага (<toggle>),
-- 3 стороны redstone по умолчанию, автозапуск «да»
local answers = { "", "", "", "", "", "<toggle>", "", "", "", "д" }
local out, ok, err, used = runInstaller(root, world, answers, nil)
check(ok, "установщик отработал без ошибок " .. tostring(err or ""))
check(readAll(root .. "/home/bhc.lua") == readAll("bhc.lua"), "bhc.lua скачан и совпадает с репозиторием")
check(readAll(root .. "/home/bhc-install.lua") ~= nil, "установщик сохранил себя в /home/bhc-install.lua")
local hw = readHw(root)
check(hw and hw.interfaceSide == 5 and hw.seedSlot == 1 and hw.collapserSlot == 2, "interface east, слоты 1/2")
check(hw and hw.stockerSide == 1 and hw.busSide == 0, "стокер up, bus down")
check(hw and hw.receiverSide == 4, "receiver west найден по переключению")
check(hw and hw.hatchSide == 0, "hatch down найден по импульсам")
check(hw and hw.transmitterSide == 5, "transmitter east (по умолчанию)")
check((readAll(root .. "/home/.shrc") or ""):find("/home/bhc.lua", 1, true) ~= nil, "автозапуск добавлен в .shrc")
check(used == #answers, ("использованы все ответы (%d/%d)"):format(used, #answers))
if failures > 0 then print(out) end

-- ======================== сценарий 2: update ========================
print("2) Режим update: бэкап, стороны не трогаются")
local hwBefore = readAll(root .. "/home/bhc-hw.cfg")
local f = io.open(root .. "/home/bhc.lua", "w"); f:write("-- old version"); f:close()
out, ok, err = runInstaller(root, world, {}, "update")
check(ok, "update без ошибок")
check(readAll(root .. "/home/bhc.lua.bak") == "-- old version", "старая версия → bhc.lua.bak")
check(readAll(root .. "/home/bhc.lua") == readAll("bhc.lua"), "новая версия установлена")
check(readAll(root .. "/home/bhc-hw.cfg") == hwBefore, "bhc-hw.cfg не изменён")

-- ======================== сценарий 3: своя раскладка, режим sides ========================
print("3) Режим sides: нестандартная раскладка, ручной ввод transmitter")
local world3 = {
  inv = {
    [2] = { size = 9, slots = { nil, nil, "Black Hole Seed", "Black Hole Collapser" } },  -- north: interface, слоты 3/4
    [4] = { size = 16, slots = {} },                                                      -- west: bus
  },
  stocker = 3, receiverToggle = 3, pulseSide = 2,
}
answers = { "", "", "", "", "", "<toggle>", "", "", "up" }
out, ok, err, used = runInstaller(root, world3, answers, "sides")
hw = readHw(root)
check(ok, "sides без ошибок")
check(hw and hw.interfaceSide == 2 and hw.seedSlot == 3 and hw.collapserSlot == 4, "interface north, слоты 3/4")
check(hw and hw.stockerSide == 3 and hw.busSide == 4, "стокер south, bus west")
check(hw and hw.receiverSide == 3 and hw.hatchSide == 2, "receiver south, hatch north")
check(hw and hw.transmitterSide == 1, "transmitter up (введено вручную)")
if failures > 0 then print(out) end

-- ======================== сценарий 4: без интернет-карты ========================
print("4) Без интернет-карты")
local root4 = os.tmpname(); os.remove(root4); sh("mkdir -p " .. root4 .. "/home")
out, ok, err = runInstaller(root4, { inv = {}, noInternet = true }, {}, nil)
check(ok and out:find("нет интернет-карты", 1, true) ~= nil, "понятное сообщение об отсутствии интернет-карты")
if not (ok and out:find("нет интернет-карты", 1, true)) then print(out, err) end

-- ======================== сценарий 5: bhc.lua читает bhc-hw.cfg ========================
print("5) bhc.lua подхватывает bhc-hw.cfg")
local src = readAll("bhc.lua")
check(src:find('HW_PATH  = BHC_HW_PATH  or "/home/bhc-hw.cfg"', 1, true) ~= nil, "путь bhc-hw.cfg в программе")

sh("rm -rf " .. root .. " " .. root4)
print(failures == 0 and "\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" or ("\nПРОВАЛЕНО: " .. failures))
os.exit(failures == 0 and 0 or 1)

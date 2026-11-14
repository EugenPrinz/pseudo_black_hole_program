-- =====================================================================
--  Установщик BHC Control (OpenComputers / OpenOS)
--
--  Первая установка (нужна интернет-карта):
--    wget -f https://raw.githubusercontent.com/EugenPrinz/pseudo_black_hole_program/main/install.lua /home/bhc-install.lua
--    bhc-install
--
--  Потом:
--    bhc-install          полная установка: скачать, проверить железо, настроить стороны, автозапуск
--    bhc-install update   только обновить программу (стороны и настройки сохраняются)
--    bhc-install sides    заново настроить стороны
-- =====================================================================

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local sides     = require("sides")
local serial    = require("serialization")
local fs        = require("filesystem")

local args = { ... }
local MODE = args[1] or "full"

local REPO   = "https://raw.githubusercontent.com/EugenPrinz/pseudo_black_hole_program/"
local BRANCH = BHC_BRANCH or "main"                       -- luacheck: ignore (глобал для тестов)
local ROOT   = BHC_ROOT or ""                             -- luacheck: ignore (глобал для тестов)

local P = {
  prog      = ROOT .. "/home/bhc.lua",
  installer = ROOT .. "/home/bhc-install.lua",
  hw        = ROOT .. "/home/bhc-hw.cfg",
  shrc      = ROOT .. "/home/.shrc",
}

-- Значения по умолчанию — Method 1 с вики (должны совпадать с HW в bhc.lua)
local DEFAULT_HW = {
  receiverSide = sides.west, transmitterSide = sides.east, hatchSide = sides.down,
  interfaceSide = sides.east, stockerSide = sides.up, busSide = sides.down,
  seedSlot = 1, collapserSlot = 2,
}

-- ============================== ВВОД/ВЫВОД ==============================
local function say(s) io.write(s .. "\n") end
local function title(s) say(""); say("== " .. s .. " ==") end

local function ask(q, default)
  io.write(q .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local a = io.read()
  if a == nil then error("interrupted", 0) end
  a = a:gsub("^%s+", ""):gsub("%s+$", "")
  if a == "" then return default end
  return a
end

local function yes(q, default)
  while true do
    local a = ask(q .. (default and " (Д/н)" or " (д/Н)"), nil)
    if a == nil then return default end
    a = a:lower()
    if a == "y" or a == "yes" or a == "д" or a == "да" then return true end
    if a == "n" or a == "no" or a == "н" or a == "нет" then return false end
  end
end

local SIDE_ALIASES = {
  down = 0, bottom = 0, ["низ"] = 0, ["вниз"] = 0,
  up = 1, top = 1, ["верх"] = 1, ["вверх"] = 1,
  north = 2, ["север"] = 2, south = 3, ["юг"] = 3,
  west = 4, ["запад"] = 4, east = 5, ["восток"] = 5,
  -- имена из таблицы sides OpenOS (для transposer'а и Redstone I/O они абсолютные)
  back = 2, front = 3, right = 4, left = 5, negy = 0, posy = 1, negz = 2, posz = 3, negx = 4, posx = 5,
}
local SIDE_EN = { [0] = "down", "up", "north", "south", "west", "east" }
local SIDE_RU = { [0] = "down (низ)", "up (верх)", "north (север)", "south (юг)", "west (запад)", "east (восток)" }
local function sideName(n) return SIDE_RU[n] or tostring(n) end

local function askSide(q, default)
  while true do
    local a = ask(q .. " — сторона", SIDE_EN[default] or tostring(default))
    local n = tonumber(a)
    if n and n >= 0 and n <= 5 then return math.floor(n) end
    n = SIDE_ALIASES[tostring(a):lower()]
    if n then return n end
    say("  Не понял. Варианты: down, up, north, south, west, east (или 0–5).")
  end
end

-- ============================== ЗАГРУЗКА ==============================
local function download(path)
  if not component.isAvailable("internet") then
    return nil, "нет интернет-карты"
  end
  local internet = require("internet")
  local url = REPO .. BRANCH .. "/" .. path
  local ok, handle = pcall(internet.request, url)
  if not ok or not handle then return nil, tostring(handle) end
  local parts = {}
  local ok2, err = pcall(function()
    for chunk in handle do parts[#parts + 1] = chunk end
  end)
  if not ok2 then return nil, tostring(err) end
  local data = table.concat(parts)
  if #data == 0 then return nil, "пустой ответ" end
  return data
end

local function writeFile(path, data)
  local dir = fs.path(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDirectory(dir) end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(data)
  f:close()
  return true
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function installProgram()
  title("Загрузка программы")
  local code, err = download("bhc.lua")
  if not code then
    say("Не удалось скачать bhc.lua: " .. tostring(err))
    return false
  end
  local version = code:match('local VERSION = "([^"]+)"') or "?"
  if not code:find("BHC Control", 1, true) or #code < 10000 then
    say("Скачанный файл не похож на bhc.lua (" .. #code .. " байт). Установка прервана.")
    return false
  end
  local fn, cerr = load(code, "=bhc.lua")
  if not fn then
    say("Файл не компилируется: " .. tostring(cerr))
    return false
  end
  local tmp = P.prog .. ".new"
  local ok, werr = writeFile(tmp, code)
  if not ok then say("Не удалось записать " .. tmp .. ": " .. tostring(werr)); return false end
  if fs.exists(P.prog) then
    if fs.exists(P.prog .. ".bak") then fs.remove(P.prog .. ".bak") end
    fs.rename(P.prog, P.prog .. ".bak")
    say("Старая версия сохранена: " .. P.prog .. ".bak")
  end
  fs.rename(tmp, P.prog)
  say(("Установлен %s — версия %s, %d байт"):format(P.prog, version, #code))

  -- обновить и сам установщик (для следующих `bhc-install update`)
  local inst = download("install.lua")
  if inst and load(inst, "=install.lua") then writeFile(P.installer, inst) end
  return true
end

-- ============================ ПРОВЕРКА ЖЕЛЕЗА ============================
local function checkHardware()
  title("Проверка железа")
  local okAll = true
  local function line(name, ok, hint)
    say(("  %s %-11s %s"):format(ok and "[ok]" or "[!!]", name, ok and "" or hint))
    if not ok then okAll = false end
  end
  line("gt_machine", component.isAvailable("gt_machine"), "adapter + MFU на контроллер BHC (до 16 блоков)")
  line("redstone", component.isAvailable("redstone"), "Redstone I/O рядом с компьютером/кабелем")
  line("transposer", component.isAvailable("transposer"), "transposer у ME interface, стокера и input bus")
  local gpuOk, scrOk = component.isAvailable("gpu"), component.isAvailable("screen")
  line("gpu", gpuOk, "видеокарта T3 или APU T3")
  line("screen", scrOk, "экран T3")
  if gpuOk then
    local w, h = component.gpu.maxResolution()
    line("разрешение", w >= 128 and h >= 24, ("нужно 128×24, есть %d×%d — нужны GPU и экран T3"):format(w, h))
  end
  return okAll
end

-- ============================ МАСТЕР СТОРОН ============================
local function lower(s) return string.lower(tostring(s or "")) end

local function scanTransposer()
  local tp = component.transposer
  local res = { inventories = {}, interface = nil, stocker = nil, seedSlot = nil, collapserSlot = nil }
  for side = 0, 5 do
    local okS, size = pcall(tp.getInventorySize, side)
    if okS and type(size) == "number" and size > 0 then
      local inv = { side = side, size = size, seeds = {}, colls = {} }
      for slot = 1, math.min(size, 36) do
        local okI, st = pcall(tp.getStackInSlot, side, slot)
        if okI and type(st) == "table" then
          local l = lower(st.label) .. " " .. lower(st.name)
          if l:find("seed") or l:find("opener") then inv.seeds[#inv.seeds + 1] = slot end
          if l:find("collaps") or l:find("closer") then inv.colls[#inv.colls + 1] = slot end
        end
      end
      res.inventories[#res.inventories + 1] = inv
    end
    local okF, f = pcall(tp.getFluidInTank, side, 1)
    if okF and type(f) == "table" then
      local fl = f.amount and f or f[1]
      if type(fl) == "table" and (lower(fl.name):find("spacetime") or lower(fl.label):find("spacetime")) then
        res.stocker = side
      end
    end
  end
  -- ME interface: инвентарь, где и seed, и collapser (иначе — где хотя бы один из них)
  local best, bestScore = nil, 0
  for _, inv in ipairs(res.inventories) do
    local score = (#inv.seeds > 0 and 1 or 0) + (#inv.colls > 0 and 1 or 0)
    if score > bestScore then best, bestScore = inv, score end
  end
  if best then
    res.interface = best.side
    res.seedSlot = best.seeds[1]
    res.collapserSlot = best.colls[1]
  end
  return res
end

local function readInputs(rs)
  local t = {}
  for side = 0, 5 do
    local ok, v = pcall(rs.getInput, side)
    t[side] = ok and tonumber(v) or 0
  end
  return t
end

local function detectReceiver(rs)
  say("  Receiver: переключи рычаг ручного управления (из схемы с вики) или положи/убери")
  say("  предметы в подсети BHC, чтобы сигнал входов изменился. Enter — пропустить.")
  local before = readInputs(rs)
  ask("  Сначала запомнил текущие сигналы. Переключи и нажми Enter", "")
  local after = readInputs(rs)
  local changed = {}
  for side = 0, 5 do
    if (before[side] or 0) ~= (after[side] or 0) then changed[#changed + 1] = side end
  end
  if #changed == 1 then
    say("  Найдено: сигнал изменился на стороне " .. sideName(changed[1]))
    return changed[1]
  elseif #changed > 1 then
    say("  Сигнал изменился на нескольких сторонах — укажи вручную.")
  end
  return nil
end

local function detectHatch(rs, seconds)
  say(("  Utility hatch: слушаю импульсы %d с (сработает, только если дыра сейчас открыта)…"):format(seconds))
  local deadline = computer.uptime() + seconds
  local counts = {}
  while computer.uptime() < deadline do
    local ev, addr, side, old, new = event.pull(deadline - computer.uptime(), "redstone_changed")
    if ev and addr == rs.address and (old or 0) == 0 and (new or 0) > 0 then
      counts[side] = (counts[side] or 0) + 1
    end
  end
  for side, n in pairs(counts) do
    if n >= 2 then
      say("  Найдено: импульсы на стороне " .. sideName(side))
      return side
    end
  end
  say("  Импульсов нет — укажи вручную (hatch в режиме PULSE, смотрит в Redstone I/O).")
  return nil
end

local function setupSides()
  title("Настройка сторон")
  local hw = {}
  local old = readFile(P.hw)
  if old then
    local ok, t = pcall(serial.unserialize, old)
    if ok and type(t) == "table" then hw = t end
  end
  for k, v in pairs(DEFAULT_HW) do if hw[k] == nil then hw[k] = v end end

  -- Transposer
  if component.isAvailable("transposer") then
    say("Сканирую transposer…")
    local r = scanTransposer()
    for _, inv in ipairs(r.inventories) do
      say(("  %s: инвентарь, %d слотов%s%s"):format(sideName(inv.side), inv.size,
        #inv.seeds > 0 and (", seed в слоте " .. inv.seeds[1]) or "",
        #inv.colls > 0 and (", collapser в слоте " .. inv.colls[1]) or ""))
    end
    if r.stocker then say("  " .. sideName(r.stocker) .. ": spacetime → стокер") end
    if r.interface then hw.interfaceSide = r.interface end
    if r.seedSlot then hw.seedSlot = r.seedSlot end
    if r.collapserSlot then hw.collapserSlot = r.collapserSlot end
    if r.stocker then hw.stockerSide = r.stocker end
    local others = {}
    for _, inv in ipairs(r.inventories) do
      if inv.side ~= hw.interfaceSide and inv.side ~= hw.stockerSide then others[#others + 1] = inv.side end
    end
    if #others == 1 then hw.busSide = others[1] end
    for _, inv in ipairs(r.inventories) do
      if inv.side == hw.busSide and inv.size > 17 then
        say(("  ВНИМАНИЕ: у %s %d слотов — обычный Input Bus столько не имеет (максимум 16 + схема)."):format(sideName(inv.side), inv.size))
        say("  Под transposer'ом должен стоять обычный Input Bus, встроенный в стену BHC (не ME-шина и не buffer).")
      end
    end
    if not r.interface then say("  ME interface не найден: положи в него seed (слот 1) и collapser (слот 2) или укажи вручную.") end
    if not r.stocker then say("  Стокер со spacetime не найден: проверь, что в нём есть spacetime, или укажи вручную.") end
  else
    say("Transposer не найден — стороны transposer'а укажи вручную.")
  end
  hw.interfaceSide = askSide("Transposer → ME interface (seed/collapser)", hw.interfaceSide)
  hw.seedSlot = tonumber(ask("  Слот seed в ME interface", hw.seedSlot)) or hw.seedSlot
  hw.collapserSlot = tonumber(ask("  Слот collapser в ME interface", hw.collapserSlot)) or hw.collapserSlot
  hw.stockerSide = askSide("Transposer → Super Stock Replenisher (spacetime)", hw.stockerSide)
  hw.busSide = askSide("Transposer → обычный input bus BHC", hw.busSide)

  -- Redstone I/O
  if component.isAvailable("redstone") then
    local rs = component.redstone
    local recv = detectReceiver(rs)
    if recv then hw.receiverSide = recv end
    local hatch = detectHatch(rs, 3)
    if hatch then hw.hatchSide = hatch end
  end
  hw.receiverSide = askSide("Redstone I/O ← wireless receiver (сигнал «есть входы»)", hw.receiverSide)
  hw.hatchSide = askSide("Redstone I/O ← Black Hole Utility Hatch (PULSE)", hw.hatchSide)
  hw.transmitterSide = askSide("Redstone I/O → wireless transmitter (spacetime-хэтч)", hw.transmitterSide)

  -- проверка конфликтов
  if hw.interfaceSide == hw.busSide or hw.interfaceSide == hw.stockerSide or hw.busSide == hw.stockerSide then
    say("  ВНИМАНИЕ: у transposer'а совпадают стороны — проверь interface/стокер/bus.")
  end
  if hw.transmitterSide == hw.receiverSide or hw.transmitterSide == hw.hatchSide then
    say("  ВНИМАНИЕ: transmitter на той же стороне, что и вход — так работать не будет.")
  end

  local ok, err = writeFile(P.hw, serial.serialize(hw))
  if not ok then say("Не удалось записать " .. P.hw .. ": " .. tostring(err)); return false end
  say("Сохранено в " .. P.hw)
  say(("  receiver %s · transmitter %s · hatch %s"):format(sideName(hw.receiverSide),
    sideName(hw.transmitterSide), sideName(hw.hatchSide)))
  say(("  interface %s (seed %d, collapser %d) · стокер %s · bus %s"):format(sideName(hw.interfaceSide),
    hw.seedSlot, hw.collapserSlot, sideName(hw.stockerSide), sideName(hw.busSide)))
  return true
end

-- ============================== АВТОЗАПУСК ==============================
local function setupAutostart()
  title("Автозапуск")
  local shrc = readFile(P.shrc) or ""
  local present = false
  for l in shrc:gmatch("[^\r\n]+") do
    if l:match("^%s*bhc%s*$") or l:match("^%s*/home/bhc") then present = true end
  end
  if present then
    if not yes("bhc уже запускается при загрузке. Оставить?", true) then
      local out = {}
      for l in (shrc .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if not (l:match("^%s*bhc%s*$") or l:match("^%s*/home/bhc")) then out[#out + 1] = l end
      end
      writeFile(P.shrc, table.concat(out, "\n"))
      say("Автозапуск убран.")
    end
    return
  end
  if yes("Запускать bhc автоматически при загрузке компьютера?", true) then
    if #shrc > 0 and shrc:sub(-1) ~= "\n" then shrc = shrc .. "\n" end
    writeFile(P.shrc, shrc .. "/home/bhc.lua\n")
    say("Добавлено в " .. P.shrc)
  end
end

-- ================================ MAIN ================================
local function main()
  say("Установщик BHC Control · режим: " .. MODE)
  if MODE == "update" then
    if installProgram() then say("\nГотово. Стороны и настройки не тронуты. Запуск: bhc") end
    return
  end
  if MODE == "sides" then
    if setupSides() then say("\nГотово. Перезапусти bhc, чтобы применить стороны.") end
    return
  end
  if MODE ~= "full" then
    say("Неизвестный режим «" .. MODE .. "». Варианты: (пусто), update, sides")
    return
  end

  if not installProgram() then
    if fs.exists(P.prog) then
      say("Продолжаю с уже установленной версией.")
    else
      say("Без интернет-карты положи bhc.lua в /home вручную и запусти «bhc-install sides».")
      return
    end
  end
  checkHardware()
  if fs.exists(P.hw) and not yes("\nСтороны уже настроены (" .. P.hw .. "). Перенастроить?", false) then
    say("Стороны оставлены как есть.")
  else
    setupSides()
  end
  setupAutostart()
  say("\nГотово. Запуск: bhc   · обновление: bhc-install update   · стороны: bhc-install sides")
end

local ok, err = pcall(main)
if not ok then
  if tostring(err):find("interrupted") then say("\nПрервано.") else say("\nОшибка: " .. tostring(err)) end
end

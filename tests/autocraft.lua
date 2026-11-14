-- Симуляция автокрафта AE2 через BHC + bhc.lua (Lua 5.3, вне Minecraft).
--   lua5.3 tests/autocraft.lua <сценарий> [early=0|10] [target=18] [runtime=200]
--   сценарии: stream, small, big, long, mixed
--
-- Модель (по коду GT5-Unofficial 5.09.54.265 и вики):
--  * паттерны AE2 проталкивают ингредиенты в подсеть BHC (скорость push — PUSH_PER_TICK крафтов/тик);
--  * advanced stocking bus видит подсеть с обновлением раз в 20 тиков; новые предметы → немедленная
--    проверка рецепта; простаивающая машина ещё и проверяет раз в 100 тиков (useStackWatcher=false);
--  * level emitter → NOT → wireless ch1 → receiver: «в подсети есть входы», задержка 7 тиков;
--  * параллели: база 120 (лазерный хэтч 256A UIV ≈ MAX), ×2 ниже 50%, ×4 ниже 20%; рецепты без
--    черной дыры ниже 20% — без лимита; рецепты с дырой ограничены питанием 390 (0,65 A на параллель);
--  * машина: seed/collapser между рецептами, импульс в тике распада, слив 2^floor((k-1)/30),
--    рецепт на нестабильной дыре войдится — как в MTEBlackHoleCompressor;
--  * spacetime-хэтч включается через 5 тиков после сигнала (toggle bus / cover).

local unpack = table.unpack
local scenario = arg[1] or "stream"
local opts = {}
for i = 2, #arg do local k, v = arg[i]:match("^(%w+)=(.+)$"); if k then opts[k] = tonumber(v) or v end end

-- ------------------------------ рецепты ------------------------------
-- длительность при UIV-хэтче, обычный режим (таблица на вики); bh=true — требует чёрную дыру
local R = {
  block   = { name = "Блоки (схема 20)",                    ticks = 1,   bh = false, bus = 20 },
  sdtrans = { name = "SD Transcendent Metal (20)",          ticks = 156, bh = true,  bus = 20 },
  sdspace = { name = "SD Spacetime (20)",                   ticks = 313, bh = true,  bus = 20 },
  sdogan  = { name = "SD Metastable Oganesson (20)",        ticks = 940, bh = true,  bus = 20 },
  gangue  = { name = "Gangue Singularity (21)",             ticks = 240, bh = true,  bus = 21 },
  eternal = { name = "Eternal Singularity (21)",            ticks = 400, bh = true,  bus = 21 },
  tne     = { name = "Transcendent Nanite Electrode (21)",  ticks = 960, bh = true,  bus = 21 },
  ironf   = { name = "Iron Singularity из флюида (21)",     ticks = 1,   bh = true,  bus = 21 },
}
local ORDER = { "block", "sdtrans", "sdspace", "sdogan", "gangue", "eternal", "tne", "ironf" }
local BASE_PAR, POWER_CAP, PUSH_PER_TICK = 120, 390, 8

-- ------------------------------ сценарии заказов ------------------------------
local JOBS = {}
local function job(t, r, n) JOBS[#JOBS + 1] = { t = math.floor(t * 20), r = r, n = n, pushed = 0, done = 0, voided = 0 } end
math.randomseed(42)
local SIM_SEC
if scenario == "stream" then
  -- обычный поток: каждые 90 с — 64 SD Transcendent Metal, каждые 150 с — 32 Gangue
  SIM_SEC = 3600
  for t = 5, 3300, 90 do job(t, "sdtrans", 64) end
  for t = 40, 3300, 150 do job(t, "gangue", 32) end
elseif scenario == "small" then
  -- мелкие заказы 1–8 крафтов в случайные моменты, в среднем раз в 45 с
  SIM_SEC = 1800
  local t, kinds = 5, { "sdtrans", "sdspace", "gangue", "eternal", "block", "ironf" }
  while t < 1650 do job(t, kinds[math.random(#kinds)], math.random(1, 8)); t = t + math.random(10, 80) end
elseif scenario == "big" then
  -- один большой заказ: 4096 SD Spacetime + 20000 блоков
  SIM_SEC = 3600
  job(10, "sdspace", 4096); job(10, "block", 20000)
elseif scenario == "long" then
  -- длинные рецепты 47–48 с: защита от войда должна расширяться
  SIM_SEC = 1800
  for t = 5, 1500, 120 do job(t, "sdogan", 16); job(t + 30, "tne", 8) end
elseif scenario == "mixed" then
  -- всё вперемешку: поток + мелочь + один длинный
  SIM_SEC = 3600
  for t = 5, 3300, 120 do job(t, "sdtrans", 48) end
  for t = 60, 3300, 200 do job(t, "eternal", 16) end
  local t = 20
  while t < 3200 do job(t, ({ "block", "ironf", "gangue" })[math.random(3)], math.random(1, 64)); t = t + math.random(20, 120) end
  job(1800, "sdogan", 8)
else
  error("неизвестный сценарий " .. scenario)
end

-- ------------------------------ модель мира ------------------------------
local SIDES = { down = 0, up = 1, north = 2, south = 3, west = 4, east = 5 }
local SIDES_FULL = {}
for k, v in pairs(SIDES) do SIDES_FULL[k] = v; SIDES_FULL[v] = k end
local TX, HATCH, RX, IFACE, BUS, STOCK = SIDES.east, SIDES.down, SIDES.west, SIDES.east, SIDES.down, SIDES.up

local SIM = { tick = 0, queue = {}, rsOut = {}, rsIn = {}, outHist = {}, rxHist = {} }
for s = 0, 5 do SIM.rsOut[s] = 0; SIM.rsIn[s] = 0 end
local M = {
  status = 1, stab = 100, costMod = 1, counter = 0,
  maxProg = 0, prog = 0, works = true, voidCur = false, cur = nil,
  bus = {}, seeds = 1000, colls = 1000, stock = opts.stock or 4000,
  checkPending = true, lastWork = 0,
  S = {}, V = {},                 -- подсеть (реально) и вид stocking-шин
  st = 0, cycles = 0, openTicks = 0, busyTicks = 0, parSum = 0, parN = 0, voidedCrafts = 0,
}
for _, k in ipairs(ORDER) do M.S[k] = 0; M.V[k] = 0 end

local function setIn(side, v)
  local old = SIM.rsIn[side]
  if old ~= v then
    SIM.rsIn[side] = v
    SIM.queue[#SIM.queue + 1] = { "redstone_changed", "rs-1", side, old, v }
  end
end
local function hatchEnabled() return (SIM.outHist[SIM.tick - 5] or 0) > 0 end

local function closeBH()
  M.status, M.stab, M.costMod, M.counter = 1, 100, 1, 0
  setIn(HATCH, 0)
end

local function maxPar(r)
  local mult = M.stab < 20 and 4 or (M.stab < 50 and 2 or 1)
  if not R[r].bh and M.stab < 20 then return math.huge end
  local p = BASE_PAR * mult
  if R[r].bh then p = math.min(p, POWER_CAP) end
  return p
end

local function check()
  if M.maxProg == 0 then
    local item = table.remove(M.bus, 1)
    if item == "seed" and M.status == 1 then M.status = 2; M.cycles = M.cycles + 1
    elseif item == "coll" and M.status ~= 1 then closeBH() end
  end
  if M.status == 1 then return end
  for _, bus in ipairs({ 20, 21 }) do
    for _, r in ipairs(ORDER) do
      if R[r].bus == bus and M.V[r] > 0 and M.S[r] > 0 then
        local p = math.min(M.V[r], M.S[r], maxPar(r))
        M.S[r] = M.S[r] - p; M.V[r] = M.V[r] - p
        M.maxProg, M.prog, M.cur = R[r].ticks, 0, { r = r, p = p }
        M.parSum, M.parN = M.parSum + p, M.parN + 1
        return
      end
    end
  end
end

local function deliver(r, n, voided)
  for _, j in ipairs(JOBS) do
    if n <= 0 then break end
    if j.r == r and j.done + j.voided < j.n then
      local take = math.min(n, j.n - j.done - j.voided)
      if voided then j.voided = j.voided + take else j.done = j.done + take end
      if j.done + j.voided >= j.n and not j.finish then j.finish = SIM.tick end
      n = n - take
    end
  end
end

local function machineTick()
  local t = SIM.tick
  -- AE2 проталкивает ингредиенты заказов в подсеть
  for _, j in ipairs(JOBS) do
    if t >= j.t and j.pushed < j.n then
      local k = math.min(PUSH_PER_TICK, j.n - j.pushed)
      j.pushed = j.pushed + k; M.S[j.r] = M.S[j.r] + k
    end
  end
  -- stocking-шины обновляют вид раз в 20 тиков; новое → немедленная проверка
  if t % 20 == 0 then
    local grew = false
    for _, r in ipairs(ORDER) do if M.S[r] > M.V[r] then grew = true end; M.V[r] = M.S[r] end
    if grew then M.checkPending = true end
  end
  -- level emitter → NOT → wireless → receiver (7 тиков)
  local any = false
  for _, r in ipairs(ORDER) do if M.S[r] > 0 then any = true end end
  SIM.rxHist[t] = any and 15 or 0
  setIn(RX, SIM.rxHist[t - 7] or 0)

  if M.maxProg > 0 then
    M.prog = M.prog + 1; M.busyTicks = M.busyTicks + 1
    if M.status == 3 then M.voidCur = true end
    if M.prog >= M.maxProg then
      if M.voidCur then M.voidedCrafts = M.voidedCrafts + M.cur.p end
      deliver(M.cur.r, M.cur.p, M.voidCur)
      M.maxProg, M.prog, M.voidCur, M.cur = 0, 0, false, nil
      M.lastWork = t
      if M.works then check() end
    end
  elseif M.works then
    local idle = t - M.lastWork
    local periodic = (idle >= 100 and t % 100 == 37) or idle == 5 or idle == 12 or idle == 20 or idle == 30
    if M.checkPending or periodic then M.checkPending = false; check() end
  end

  if M.status == 1 then return end
  M.openTicks = M.openTicks + 1
  if t % 20 == 5 then setIn(HATCH, 0) end
  if t % 20 ~= 0 then return end
  setIn(HATCH, 15)
  local dec = 1
  if M.stab > 0 and hatchEnabled() then
    M.st = M.st + M.costMod
    M.counter = M.counter + 1; dec = 0
    if M.counter >= 30 then
      if M.costMod <= 1000000000 then M.costMod = M.costMod * 2 end
      M.counter = 0
    end
  end
  M.stab = M.stab - dec
  if M.stab <= 0 then M.status = 3 end
  if M.stab <= -900 then closeBH() end
end

local function simTick()
  SIM.tick = SIM.tick + 1
  SIM.outHist[SIM.tick] = SIM.rsOut[TX]
  machineTick()
end

-- ------------------------------ моки OpenComputers ------------------------------
local comps = {
  gt_machine = {
    hasWork = function() return M.maxProg > 0 end,
    getWorkProgress = function() return M.prog end,
    getWorkMaxProgress = function() return M.maxProg end,
    setWorkAllowed = function(v) if v and not M.works then M.checkPending = true end; M.works = v end,
    isWorkAllowed = function() return M.works end,
  },
  redstone = { address = "rs-1", getInput = function(s) return SIM.rsIn[s] end, setOutput = function(s, v) SIM.rsOut[s] = v; return 0 end },
  transposer = {
    getInventorySize = function(side) if side == BUS then return 16 end end,
    getStackInSlot = function(side, slot)
      if side == BUS then
        local it = M.bus[slot]
        return it and { size = 1, label = it == "seed" and "Black Hole Seed" or "Black Hole Collapser" } or nil
      end
      if side ~= IFACE then return nil end
      local n = slot == 1 and M.seeds or (slot == 2 and M.colls or 0)
      return n > 0 and { size = n, label = "x" } or nil
    end,
    getFluidInTank = function(side) if side == STOCK then return { amount = M.stock } end end,
    transferItem = function(src, dst, _, slot)
      if src ~= IFACE or dst ~= BUS then return 0 end
      local item
      if slot == 1 and M.seeds > 0 then M.seeds = M.seeds - 1; item = "seed" end
      if slot == 2 and M.colls > 0 then M.colls = M.colls - 1; item = "coll" end
      if not item then return 0 end
      M.bus[#M.bus + 1] = item; M.checkPending = true
      return 1
    end,
  },
  gpu = {
    maxResolution = function() return 160, 50 end, getResolution = function() return 160, 50 end,
    setResolution = function() end, setForeground = function() end, setBackground = function() end,
    fill = function() end, set = function() end,
  },
  screen = {},
}
package.preload.component = function()
  return setmetatable({ isAvailable = function(n) return comps[n] ~= nil end }, { __index = comps })
end
package.preload.computer = function() return { uptime = function() return SIM.tick / 20 end } end
package.preload.sides = function() return SIDES_FULL end
package.preload.unicode = function()
  return {
    len = utf8.len,
    sub = function(s, i, j)
      local n = utf8.len(s); j = j or n
      if j < 0 then j = n + j + 1 end
      if i < 1 then i = 1 end
      if j > n then j = n end
      if i > j then return "" end
      return s:sub(utf8.offset(s, i), (utf8.offset(s, j + 1) or (#s + 1)) - 1)
    end,
  }
end
package.preload.serialization = function()
  local function ser(v)
    if type(v) == "table" then
      local p = {}
      for k, x in pairs(v) do p[#p + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
      return "{" .. table.concat(p, ",") .. "}"
    elseif type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
  end
  return { serialize = ser, unserialize = function(s) return load("return " .. s)() end }
end
local STOP = SIM_SEC * 20
package.preload.event = function()
  return {
    pull = function(timeout)
      if #SIM.queue > 0 then return unpack(table.remove(SIM.queue, 1)) end
      for _ = 1, math.max(1, math.floor((timeout or 1) * 20 + 0.5)) do
        simTick()
        if SIM.tick >= STOP then error("interrupted", 0) end
        if #SIM.queue > 0 then return unpack(table.remove(SIM.queue, 1)) end
      end
    end,
  }
end

-- конфиг программы
BHC_CFG_PATH = os.tmpname()
BHC_HW_PATH = "/nonexistent/bhc-hw.cfg"
do
  local f = io.open(BHC_CFG_PATH, "w")
  f:write(("{maxRuntime=%d,targetStability=%d,earlyCloseSec=%d}"):format(opts.runtime or 200, opts.target or 18, opts.early or 10))
  f:close()
end
local LOGN = 0
BHC_ON_LOG = function(msg, kind)
  if kind == "err" or kind == "warn" then LOGN = LOGN + 1; if LOGN <= 12 then io.stderr:write(("  %7.1f с [%s] %s\n"):format(SIM.tick / 20, kind, msg)) end end
end

local realPrint = print
print = function() end
dofile("bhc.lua")
print = realPrint
os.remove(BHC_CFG_PATH)

-- ------------------------------ отчёт ------------------------------
local done, stuck, lat, latMax, crafts, total = 0, 0, 0, 0, 0, 0
for _, j in ipairs(JOBS) do
  total = total + j.n; crafts = crafts + j.done
  if j.finish and j.voided == 0 then
    done = done + 1
    local l = (j.finish - j.t) / 20
    lat = lat + l; latMax = math.max(latMax, l)
  elseif j.voided > 0 then stuck = stuck + 1 end
end
local function f1(x) return string.format("%.1f", x) end
print(("=== %s · ранний выход %s с · цель %s%% · жизнь %s с · %d с симуляции ==="):format(
  scenario, tostring(opts.early or 10), tostring(opts.target or 18), tostring(opts.runtime or 200), SIM_SEC))
print(("заказов выполнено: %d / %d, застряло из-за войда: %d"):format(done, #JOBS, stuck))
print(("крафтов: %d / %d, войднуто крафтов: %d"):format(crafts, total, M.voidedCrafts))
print(("задержка заказа: средняя %s с, максимальная %s с"):format(done > 0 and f1(lat / done) or "—", f1(latMax)))
print(("циклов дыры: %d (seed %d, collapser %d), spacetime: %d L, на 1 крафт: %s L"):format(
  M.cycles, 1000 - M.seeds, 1000 - M.colls, M.st, crafts > 0 and string.format("%.2f", M.st / crafts) or "—"))
print(("дыра открыта %s%% времени, машина работала %s%% времени открытой дыры, средние параллели %s"):format(
  f1(100 * M.openTicks / (SIM_SEC * 20)), f1(M.openTicks > 0 and 100 * M.busyTicks / M.openTicks or 0),
  M.parN > 0 and f1(M.parSum / M.parN) or "—"))

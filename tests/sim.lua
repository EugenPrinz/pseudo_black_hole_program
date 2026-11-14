-- Офлайн-симулятор для bhc.lua (Lua 5.3, вне Minecraft).
-- Моделирует BHC по логике MTEBlackHoleCompressor.java потиково и мокает
-- component / computer / event / gpu OpenComputers.
--
--   lua5.3 tests/sim.lua <сценарий>     сценарии: basic, long, recovery, starve, screen

local scenario = arg[1] or "basic"
local unpack = table.unpack

-- ---------------- машина ----------------
local SIDES = { down = 0, up = 1, north = 2, south = 3, west = 4, east = 5 }
local M = {
  status = 1, stab = 100, costMod = 1, counter = 0,
  maxProg = 0, prog = 0, works = true, voidCur = false,
  done = 0, voided = 0, stConsumed = 0, bus = {},
  recipeTicks = 313, inputs = math.huge,
  seeds = 20, colls = 20, stStock = 1000,
  cycles = {}, curCycle = nil,
}
local SIM = { tick = 0, queue = {}, stopAt = 20 * 700, rsOut = {}, rsIn = {}, outHist = {}, script = {} }
for _, s in pairs(SIDES) do SIM.rsOut[s] = 0; SIM.rsIn[s] = 0 end

local TX, HATCH, RX, IFACE, BUS, STOCK = SIDES.east, SIDES.down, SIDES.west, SIDES.east, SIDES.down, SIDES.up

local function setIn(side, v)
  local old = SIM.rsIn[side]
  if old ~= v then
    SIM.rsIn[side] = v
    SIM.queue[#SIM.queue + 1] = { "redstone_changed", "rs-1", side, old, v }
  end
end

local function hatchEnabled()          -- machine controller cover, tick rate 5
  local t = SIM.tick - 5
  return (SIM.outHist[t] or 0) > 0
end

local function closeBH()
  M.status, M.stab, M.costMod, M.counter = 1, 100, 1, 0
  setIn(HATCH, 0)
  if M.curCycle then
    M.curCycle.closeTick = SIM.tick
    M.cycles[#M.cycles + 1] = M.curCycle
    M.curCycle = nil
  end
end

local function check()
  if M.maxProg == 0 then                -- searchAndDecrementCatalysts
    local item = table.remove(M.bus, 1)
    if item == "seed" and M.status == 1 then
      M.status = 2
      M.curCycle = { openTick = SIM.tick, st = 0, voided = 0 }
    elseif item == "coll" and M.status ~= 1 then
      closeBH()
    end
  end
  if M.status == 1 then return end
  if M.inputs > 0 then
    M.inputs = M.inputs - 1
    M.maxProg, M.prog = M.recipeTicks, 0
  end
end

local function machineTick()
  if M.maxProg > 0 then
    M.prog = M.prog + 1
    if M.status == 3 then M.voidCur = true end
    if M.prog >= M.maxProg then
      if M.voidCur then
        M.voided = M.voided + 1
        if M.curCycle then M.curCycle.voided = M.curCycle.voided + 1 end
      else M.done = M.done + 1 end
      M.maxProg, M.prog, M.voidCur = 0, 0, false
      if M.works then check() end
    end
  elseif M.works then
    check()
  end
  setIn(RX, M.inputs > 0 and 15 or 0)

  if M.status == 1 then return end
  if SIM.tick % 20 == 5 then setIn(HATCH, 0) end
  if SIM.tick % 20 ~= 0 then return end
  setIn(HATCH, 15)
  local dec = 1
  if M.stab > 0 and hatchEnabled() then
    M.stConsumed = M.stConsumed + M.costMod
    if M.curCycle then M.curCycle.st = M.curCycle.st + M.costMod end
    M.counter = M.counter + 1
    dec = 0
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
  if SIM.script[SIM.tick] then SIM.script[SIM.tick]() end
  machineTick()
end

-- ---------------- моки OC ----------------
local screen, scrW, scrH = {}, 160, 50
local gpuMock = {
  maxResolution = function() return 160, 50 end,
  getResolution = function() return scrW, scrH end,
  setResolution = function(w, h) scrW, scrH = w, h; screen = {} end,
  setForeground = function(c) SIM.fg = c end, setBackground = function(c) SIM.bg = c end,
  fill = function() end,
  set = function(x, y, s)
    screen[y] = screen[y] or {}
    local i = 0
    for _, c in utf8.codes(s) do screen[y][x + i] = { utf8.char(c), SIM.fg or 0xFFFFFF, SIM.bg or 0 }; i = i + 1 end
  end,
}
local function dumpCells(name)
  local dir = os.getenv("BHC_DUMP_DIR")
  if not dir then return end
  local f = io.open(dir .. "/" .. name .. ".cells", "w")
  f:write(scrW, "\t", scrH, "\n")
  for y = 1, scrH do for x = 1, scrW do
    local c = screen[y] and screen[y][x]
    if c then f:write(y, "\t", x, "\t", c[2], "\t", c[3], "\t", c[1], "\n") end
  end end
  f:close()
end
local function dumpScreen()
  local out = {}
  for y = 1, scrH do
    local row = {}
    for x = 1, scrW do local c = screen[y] and screen[y][x]; row[x] = c and c[1] or " " end
    out[#out + 1] = table.concat(row)
  end
  return table.concat(out, "\n")
end

local comps = {
  gt_machine = {
    hasWork = function() return M.maxProg > 0 end,
    getWorkProgress = function() return M.prog end,
    getWorkMaxProgress = function() return M.maxProg end,
    setWorkAllowed = function(v) M.works = v end,
    isWorkAllowed = function() return M.works end,
  },
  redstone = {
    address = "rs-1",
    getInput = function(side) return SIM.rsIn[side] end,
    setOutput = function(side, v) SIM.rsOut[side] = v; return 0 end,
  },
  transposer = {
    getStackInSlot = function(side, slot)
      if side ~= IFACE then return nil end
      local n = slot == 1 and M.seeds or (slot == 2 and M.colls or 0)
      if n > 0 then return { size = n, label = slot == 1 and "Black Hole Seed" or "Black Hole Collapser" } end
      return nil
    end,
    getFluidInTank = function(side) if side == STOCK then return { amount = M.stStock, name = "spacetime" } end end,
    transferItem = function(src, dst, count, slot)
      if src ~= IFACE or dst ~= BUS then return 0 end
      if slot == 1 and M.seeds > 0 then M.seeds = M.seeds - 1; M.bus[#M.bus + 1] = "seed"; return 1 end
      if slot == 2 and M.colls > 0 then M.colls = M.colls - 1; M.bus[#M.bus + 1] = "coll"; return 1 end
      return 0
    end,
  },
  gpu = gpuMock, screen = {},
}

package.preload.component = function()
  local c = { isAvailable = function(n) return comps[n] ~= nil end }
  return setmetatable(c, { __index = comps })
end
package.preload.computer = function() return { uptime = function() return SIM.tick / 20 end } end
package.preload.sides = function() return SIDES end
package.preload.unicode = function()
  return {
    len = utf8.len,
    sub = function(s, i, j)
      local n = utf8.len(s); j = j or n
      if j < 0 then j = n + j + 1 end
      if i < 1 then i = 1 end
      if j > n then j = n end
      if i > j then return "" end
      local a = utf8.offset(s, i)
      local b = utf8.offset(s, j + 1) or (#s + 1)
      return s:sub(a, b - 1)
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
package.preload.event = function()
  return {
    pull = function(timeout)
      if #SIM.queue > 0 then return unpack(table.remove(SIM.queue, 1)) end
      local n = math.max(1, math.floor((timeout or 1) * 20 + 0.5))
      for _ = 1, n do
        simTick()
        if SIM.tick >= SIM.stopAt then error("interrupted", 0) end
        if #SIM.queue > 0 then return unpack(table.remove(SIM.queue, 1)) end
      end
      return nil
    end,
  }
end

local function touch(atTick, x, y)
  local prev = SIM.script[atTick]
  SIM.script[atTick] = function()
    if prev then prev() end
    SIM.queue[#SIM.queue + 1] = { "touch", "scr", x, y, 0, "tester" }
  end
end

-- ---------------- сценарии ----------------
BHC_CFG_PATH = os.tmpname()
os.remove(BHC_CFG_PATH)
local dumpAt = {}

if scenario == "basic" then
  SIM.stopAt = 20 * 660                 -- ~3 цикла
elseif scenario == "long" then
  M.recipeTicks = 900                   -- 45 с — длиннее цели 18%, нужна защита
  SIM.stopAt = 20 * 500
elseif scenario == "recovery" then
  M.status, M.stab, M.costMod, M.counter = 2, 60, 2, 40   -- дыра уже открыта до запуска
  M.curCycle = { openTick = 0, st = 0, voided = 0 }
  SIM.stopAt = 20 * 120
elseif scenario == "starve" then
  M.inputs = 12                         -- входы кончаются посреди цикла
  SIM.stopAt = 20 * 400
elseif scenario == "screen" then
  SIM.stopAt = 20 * 200
  dumpAt[20 * 150] = "main"
  touch(20 * 160, 80, 23)               -- НАСТРОЙКИ (4-я кнопка)
  dumpAt[20 * 162] = "settings"
elseif scenario == "touch" then
  -- НАСТРОЙКИ → «+10» к времени жизни → СОХРАНИТЬ; затем ЗАКРЫТЬ СЕЙЧАС во время распада
  SIM.stopAt = 20 * 260
  touch(20 * 5, 80, 23)
  touch(20 * 6, 82, 5)
  touch(20 * 7, 10, 23)
  touch(20 * 230, 55, 23)
end

for t, name in pairs(dumpAt) do
  local prev = SIM.script[t]
  SIM.script[t] = function()
    if prev then prev() end
    SIM.pendingDump = name; SIM.dumpAfter = SIM.tick + 12
  end
end
-- дамп делаем после ближайшей перерисовки
local realSet = gpuMock.set
local dumps = {}
gpuMock.set = function(...)
  realSet(...)
end

local origPull = package.preload.event
package.preload.event = function()
  local ev = origPull()
  local pull = ev.pull
  ev.pull = function(...)
    if SIM.pendingDump and SIM.tick >= (SIM.dumpAfter or 0) then
      dumps[#dumps + 1] = { SIM.pendingDump, dumpScreen() }
      dumpCells(SIM.pendingDump)
      SIM.pendingDump = nil
    end
    return pull(...)
  end
  return ev
end

dofile("bhc.lua")

-- ---------------- отчёт ----------------
print(("=== сценарий: %s, %d с симуляции ==="):format(scenario, SIM.tick // 20))
print(("рецептов выполнено: %d, ВОЙДНУТО: %d, spacetime потрачено: %d L"):format(M.done, M.voided, M.stConsumed))
for i, c in ipairs(M.cycles) do
  print(("  цикл %d: открыта %.1f с → закрыта %.1f с (жизнь %.1f с), spacetime %d L, войдов %d")
    :format(i, c.openTick / 20, c.closeTick / 20, (c.closeTick - c.openTick) / 20, c.st, c.voided))
end
if M.curCycle then print(("  незакрытый цикл с %.1f с, spacetime %d L"):format(M.curCycle.openTick / 20, M.curCycle.st)) end
print(("seeds: %d, collapsers: %d, в bus осталось: %d, status=%d, works=%s, spacetime-выход=%d")
  :format(M.seeds, M.colls, #M.bus, M.status, tostring(M.works), SIM.rsOut[TX]))
local f = io.open(BHC_CFG_PATH)
if f then print("cfg: " .. f:read("*a")); f:close() end
os.remove(BHC_CFG_PATH)
for _, d in ipairs(dumps) do
  print("\n----- экран: " .. d[1] .. " -----")
  print(d[2])
end

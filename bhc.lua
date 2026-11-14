-- =====================================================================
--  BHC Control — Pseudostable Black Hole Containment Field (GTNH)
--  OpenComputers / OpenOS. Один компьютер = один BHC.
--
--  Железо: раскладка «Method 1» с вики GTNH (redstone I/O + wireless
--  receiver/transmitter + Black Hole Utility Hatch в режиме PULSE,
--  transposer + ME interface + Super Stock Replenisher + input bus,
--  adapter с MFU на контроллер). Стороны настраивает установщик
--  (bhc-install sides → /home/bhc-hw.cfg), по умолчанию — таблица HW ниже.
--
--  Экран: T3 5×2, видеокарта T3. Разрешение 128×24.
--  Выход: кнопка «ВЫХОД» (дважды) или Ctrl+Alt+C.
--
--  Механика взята из MTEBlackHoleCompressor.java (GT5-Unofficial):
--   * импульс utility hatch приходит раз в 20 тиков в том же тике,
--     где стабильность падает на 1% (или тратится spacetime);
--   * k-й слив spacetime стоит 2^floor((k-1)/30) L, счётчик живёт до
--     закрытия дыры (паузы его не сбрасывают), потолок 2^30 L;
--   * seed/collapser забираются только между рецептами; collapser
--     закрывает дыру до старта следующего рецепта;
--   * рецепт, который идёт при стабильности <= 0, войдится.
-- =====================================================================

local VERSION = "0.3.2"

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local sides     = require("sides")
local serial    = require("serialization")
local unicode   = require("unicode")

-- ============================== ЖЕЛЕЗО ==============================
-- Значения по умолчанию — раскладка Method 1 с вики. Свои стороны лучше задавать
-- через установщик (bhc-install sides): он пишет /home/bhc-hw.cfg, который
-- переопределяет эту таблицу и не затирается при обновлении программы.
local HW = {
  receiverSide    = sides.west,  -- Redstone I/O ← wireless receiver («в подсети есть входы»)
  transmitterSide = sides.east,  -- Redstone I/O → wireless transmitter (включает spacetime-хэтч)
  hatchSide       = sides.down,  -- Redstone I/O ← Black Hole Utility Hatch в режиме PULSE
  interfaceSide   = sides.east,  -- Transposer: ME interface (слот 1 — seeds, слот 2 — collapsers)
  stockerSide     = sides.up,    -- Transposer: Super Stock Replenisher со spacetime; -1 — стокера у transposer'а нет
                                 -- (предохранитель стоит снаружи у хэтча spacetime, запас не проверяется)
  busSide         = sides.down,  -- Transposer: обычный input bus BHC
  seedSlot        = 1,
  collapserSlot   = 2,
  resolution      = {128, 24},   -- под экран T3 5×2
  stLatency       = 0.4,         -- с: сколько нужно хэтчу, чтобы включиться (cover 5 тиков + запас)
  pulseTimeout    = 2.5,         -- с без импульсов → дыра закрыта
  openAttemptSec  = 10,          -- с на одну попытку открытия (seed должен быть принят)
  openAttempts    = 3,           -- попыток до тревоги (повтор = выкл/вкл машины → проверка рецепта)
  collapseDelay   = 3,           -- с паузы после закрытия (анимация схлопывания)
}
local CFG_PATH = BHC_CFG_PATH or "/home/bhc.cfg"        -- luacheck: ignore (глобал для тестов)
local HW_PATH  = BHC_HW_PATH  or "/home/bhc-hw.cfg"     -- luacheck: ignore

local HW_SOURCE = "по умолчанию (Method 1 с вики)"
do
  local f = io.open(HW_PATH, "r")
  if f then
    local data = f:read("*a")
    f:close()
    local ok, t = pcall(serial.unserialize, data)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do
        if HW[k] ~= nil and type(v) == type(HW[k]) then HW[k] = v end
      end
      HW_SOURCE = HW_PATH
    end
  end
end
-- ====================================================================

local DEFAULTS = {
  maxRuntime      = 200,   -- с, полное время жизни дыры (включая базовые 100)
  targetStability = 18,    -- %, на которой замораживаем распад
  voidProtection  = true,  -- держать стабильность до конца последнего рецепта
  protectMaxSec   = 30,    -- с, минимальный лимит доп. стабилизации ради защиты
  autoProtect     = true,  -- поднимать лимит под самый длинный замеченный рецепт
  protectAutoCap  = 120,   -- с, потолок авто-лимита
  safetyMargin    = 2,     -- с, запас по времени для защиты
  earlyCloseSec   = 10,    -- с: нет входов и машина простаивает → закрыть раньше (0 — выкл)
  useCollapser    = true,  -- закрывать collapser'ом (иначе — ждать ~15 мин)
  auto            = true,  -- автоматически открывать дыру
  stats = { cycles = 0, spacetime = 0, voids = 0, maxRecipe = 0 },
}
local LIMITS = {
  maxRuntime = {100, 1150}, targetStability = {1, 99},
  protectMaxSec = {0, 600}, protectAutoCap = {0, 600},
  safetyMargin = {0, 20}, earlyCloseSec = {0, 120},
}

local unpack = table.unpack or unpack

-- ============================== УТИЛИТЫ ==============================
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

local function safe(f, ...)
  if type(f) ~= "function" and type(f) ~= "table" then return nil end
  local res = { pcall(f, ...) }
  if res[1] then return select(2, unpack(res)) end
  return nil
end

local function fmtInt(n)
  if n == nil then return "?" end
  local s = string.format("%.0f", n)
  local neg = s:sub(1, 1) == "-"
  if neg then s = s:sub(2) end
  s = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
  return (neg and "-" or "") .. s
end

local function fmtL(n)
  if n == nil then return "?" end
  local a = math.abs(n)
  if a >= 1e12 then return string.format("%.2f трлн", n / 1e12)
  elseif a >= 1e9 then return string.format("%.2f млрд", n / 1e9)
  elseif a >= 1e6 then return string.format("%.2f млн", n / 1e6) end
  return fmtInt(n)
end

local function ulen(s) return unicode.len(s) end
local function usub(s, i, j) return unicode.sub(s, i, j) end
local function fit(s, w) if ulen(s) > w then return usub(s, 1, math.max(0, w - 1)) .. "…" end return s end

-- ======================= ЭКОНОМИКА SPACETIME =======================
local COST_CAP = 2 ^ 30

local function drainCost(k)              -- цена k-го слива (k с 1)
  if k < 1 then return 0 end
  return math.min(2 ^ math.floor((k - 1) / 30), COST_CAP)
end

local function totalCost(n)              -- сумма первых n сливов
  local sum, k = 0, 1
  while k <= n do
    local block = math.floor((k - 1) / 30)
    local last = math.min(n, (block + 1) * 30)
    sum = sum + math.min(2 ^ block, COST_CAP) * (last - k + 1)
    k = last + 1
  end
  return sum
end

-- Лимит доп. стабилизации ради защиты: минимум protectMaxSec; с авто-лимитом —
-- сколько нужно самому длинному замеченному рецепту, но не выше потолка.
local function protectLimits(cfg)
  if not cfg.voidProtection then return 0, 0, 0 end
  local cap = cfg.autoProtect and math.max(cfg.protectMaxSec, cfg.protectAutoCap) or cfg.protectMaxSec
  local maxRecipe = (cfg.stats and cfg.stats.maxRecipe) or 0
  local need = math.max(0, math.ceil(maxRecipe + cfg.safetyMargin - cfg.targetStability))
  local extra = cfg.protectMaxSec
  if cfg.autoProtect then extra = math.max(extra, math.min(need, cap)) end
  return extra, cap, need
end

local function makePlan(cfg)
  local hold  = math.max(0, cfg.maxRuntime - 100)
  local extra, cap, need = protectLimits(cfg)
  return {
    maxRuntime = cfg.maxRuntime, target = cfg.targetStability,
    voidProtection = cfg.voidProtection, useCollapser = cfg.useCollapser,
    autoProtect = cfg.autoProtect, earlyClose = cfg.earlyCloseSec,
    extraCap = cap, unprotectable = cfg.voidProtection and need > cap,
    margin = cfg.safetyMargin, extra = extra, hold = hold,
    holdStart = 100 - cfg.targetStability,
    closeAt   = 100 - cfg.targetStability + hold,
    holdCost  = totalCost(hold),        peak     = drainCost(hold),
    fullCost  = totalCost(hold + extra), fullPeak = drainCost(hold + extra),
  }
end

local function zoneMult(stab)
  if stab < 20 then return 4 elseif stab < 50 then return 2 end
  return 1
end

-- ============================== КОНФИГ ==============================
local CFG

local function loadCfg()
  local cfg = copy(DEFAULTS)
  local f = io.open(CFG_PATH, "r")
  if f then
    local data = f:read("*a")
    f:close()
    local ok, t = pcall(serial.unserialize, data)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do
        if k == "stats" and type(v) == "table" then
          for sk, sv in pairs(v) do if type(sv) == "number" then cfg.stats[sk] = sv end end
        elseif DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then
          cfg[k] = v
        end
      end
    end
  end
  for k, lim in pairs(LIMITS) do cfg[k] = clamp(math.floor(cfg[k]), lim[1], lim[2]) end
  return cfg
end

local function saveCfg()
  local f = io.open(CFG_PATH, "w")
  if f then f:write(serial.serialize(CFG)); f:close() end
end

-- ============================ КОМПОНЕНТЫ ============================
local bhc, rs, tp, gpu

local function bindComponents()
  local missing = {}
  for _, name in ipairs({ "gt_machine", "redstone", "transposer", "gpu", "screen" }) do
    if not component.isAvailable(name) then missing[#missing + 1] = name end
  end
  if #missing > 0 then
    return false, "Не найдены компоненты: " .. table.concat(missing, ", ") ..
      "\n(gt_machine — adapter с MFU на контроллер BHC)"
  end
  bhc, rs, tp, gpu = component.gt_machine, component.redstone, component.transposer, component.gpu
  return true
end

local function mWork()    return safe(bhc.hasWork) == true end
local function mAllowed() return safe(bhc.isWorkAllowed) ~= false end
local function setAllowed(v) safe(bhc.setWorkAllowed, v) end
local function mRemain()   -- осталось секунд, длительность рецепта в секундах
  local mx = tonumber(safe(bhc.getWorkMaxProgress)) or 0
  local p  = tonumber(safe(bhc.getWorkProgress)) or 0
  return math.max(0, mx - p) / 20, mx / 20, mx > 0 and p / mx or 0
end

local function slotCount(slot)
  local s = safe(tp.getStackInSlot, HW.interfaceSide, slot)
  return type(s) == "table" and (tonumber(s.size) or 0) or 0
end

local function hasStocker() return HW.stockerSide >= 0 end

local function stockAmount()           -- nil — стокера у transposer'а нет
  if not hasStocker() then return nil end
  local f = safe(tp.getFluidInTank, HW.stockerSide, 1)
  if type(f) ~= "table" then return 0 end
  if f.amount then return f.amount end
  if type(f[1]) == "table" and f[1].amount then return f[1].amount end
  return 0
end

local function insert(slot)
  local n = safe(tp.transferItem, HW.interfaceSide, HW.busSide, 1, slot)
  return (tonumber(n) or 0) > 0
end

-- Что лежит в input bus: seeds, collapsers (nil — bus не читается, проверь busSide)
local function busScan()
  local size = tonumber(safe(tp.getInventorySize, HW.busSide))
  if not size then return nil end
  local seeds, colls = 0, 0
  for i = 1, size do
    local st = safe(tp.getStackInSlot, HW.busSide, i)
    if type(st) == "table" then
      local l = string.lower(tostring(st.label or st.name or ""))
      local n = tonumber(st.size) or 1
      if l:find("collaps") or l:find("closer") then colls = colls + n
      elseif l:find("seed") or l:find("opener") then seeds = seeds + n end
    end
  end
  return seeds, colls
end

-- ============================== СОСТОЯНИЕ ==============================
local PHASES = { "IDLE", "OPENING", "DECAY", "HOLD", "CLOSING", "COLLAPSE" }
local PHASE_RU = {
  IDLE = "ОЖИДАНИЕ", OPENING = "ОТКРЫТИЕ", DECAY = "РАСПАД", HOLD = "СТАБИЛИЗАЦИЯ",
  CLOSING = "ЗАКРЫТИЕ", COLLAPSE = "СХЛОПЫВАНИЕ", RECOVERY = "ВОССТАНОВЛЕНИЕ",
}
local OPEN_PHASES = { DECAY = true, HOLD = true, CLOSING = true, RECOVERY = true }

local S = {
  running = true, phase = "IDLE", screen = "main",
  stOn = false, stChangedAt = -100, lastPulse = -100,
  res = { inputs = false, seeds = 0, coll = 0, st = 0 },
  mach = { work = false, allowed = true, rem = 0, dur = 0, frac = 0 },
  readyMsg = "Запуск…", readyOk = false, nextReady = 0, grace = 0,
  dirty = true,
}

local LOG = {}
local function log(msg, kind)
  table.insert(LOG, 1, { t = os.date("%H:%M:%S"), m = msg, k = kind or "info" })
  while #LOG > 40 do table.remove(LOG) end
  S.dirty = true
  if BHC_ON_LOG then BHC_ON_LOG(msg, kind) end   -- luacheck: ignore (хук для тестов, в OC = nil)
end

local function resetCycle()
  S.stab, S.pulses, S.drains, S.extraDrains, S.cycleST = 100, 0, 0, 0, 0
  S.history = {}
  S.unknown, S.collapserIn, S.disabled = false, false, false
  S.unstableLogged, S.voidLogged, S.limitLogged, S.protectLogged = false, false, false, false
  S.prevPhase, S.idleSince, S.openAttempt = nil, nil, 0
end

local function setST(on)
  if S.stOn ~= on then
    safe(rs.setOutput, HW.transmitterSide, on and 15 or 0)
    S.stOn = on
    S.stChangedAt = computer.uptime()
    S.dirty = true
  end
end

local function stEffective(now)          -- был ли хэтч реально включён к этому импульсу
  local e = S.stOn
  if now - S.stChangedAt < HW.stLatency then e = not e end
  return e
end

local function alarm(msg)
  S.alarm = msg
  log(msg, "err")
end

local function pollMachine()
  local m = S.mach
  m.work, m.allowed = mWork(), mAllowed()
  m.rem, m.dur, m.frac = mRemain()
  S.res.inputs = (tonumber(safe(rs.getInput, HW.receiverSide)) or 0) > 0
  -- самый длинный рецепт (реальная длительность с разгоном/batch) — для авто-лимита защиты
  if m.work and m.dur > (CFG.stats.maxRecipe or 0) + 0.05 then
    CFG.stats.maxRecipe = m.dur
    log(("Самый длинный рецепт: %.1f с"):format(m.dur), "info")
    saveCfg()
  end
end

local function pollRes()
  local r = S.res
  r.inputs = (tonumber(safe(rs.getInput, HW.receiverSide)) or 0) > 0
  r.seeds  = slotCount(HW.seedSlot)
  r.coll   = slotCount(HW.collapserSlot)
  r.st     = stockAmount()
end

local function ready(manual)
  local p = makePlan(CFG)
  if not manual and not S.res.inputs then return false, "Нет входов в подсети — сон" end
  if S.res.seeds < 1 then return false, "Нет Black Hole Seed в ME interface (слот " .. HW.seedSlot .. ")" end
  if CFG.useCollapser and S.res.coll < 1 then
    return false, "Нет Black Hole Collapser в ME interface (слот " .. HW.collapserSlot .. ")"
  end
  if hasStocker() and p.fullCost > 0 and S.res.st < p.fullCost then
    return false, ("Мало spacetime: нужно %s L (защита %d с), в стокере %s L — фильтр стокера ≥ %s L")
      :format(fmtL(p.fullCost), p.extra, fmtL(S.res.st), fmtL(math.ceil(p.fullCost * 1.5)))
  end
  return true, "Готов к открытию дыры"
end

-- ============================ ЛОГИКА ЦИКЛА ============================
-- Рецепт длиннее, чем покрывает текущий лимит: пробуем расширить защиту на лету
-- (только с авто-лимитом, в пределах потолка и если в стокере хватает spacetime).
local function tryExtend(rem)
  local P = S.plan
  if S.unknown or not P.autoProtect then return false end
  local k = math.ceil(rem + P.margin - S.stab)          -- сколько ещё сливов нужно
  if k <= 0 then return false end
  local total = S.extraDrains + k
  if total > P.extraCap then
    log(("Рецепту нужно %d с защиты, потолок %d с"):format(total, P.extraCap), "err")
    return false
  end
  local add = totalCost(S.drains + k) - totalCost(S.drains)
  local st = stockAmount()
  if st and st < add then
    log(("Расширить защиту нельзя: нужно %s L, есть %s L"):format(fmtL(add), fmtL(st)), "err")
    return false
  end
  P.extra = total
  log(("Защита расширена до %d с (+%s L)"):format(total, fmtL(add)), "warn")
  return true
end

local function protect()
  local P = S.plan
  if not P.voidProtection then setST(false); return end
  if not S.unknown and S.stab <= 0 then setST(false); return end
  local need, rem = false, 0
  if mWork() then
    rem = mRemain()
    need = S.unknown or (rem + P.margin >= S.stab)
  end
  if need and S.extraDrains >= P.extra and not S.limitLogged then
    if not tryExtend(rem) then
      S.limitLogged = true
      log("Лимит защиты исчерпан — рецепт может войднуться", "warn")
    end
  end
  if need and S.extraDrains >= P.extra then need = false end
  if need and not S.protectLogged then
    S.protectLogged = true
    log("Защита: держим до конца рецепта", "warn")
  end
  setST(need)
end

local function beginClosing(reason)
  S.phase = "CLOSING"
  log(reason .. " → закрытие", "ok")
  if S.plan.useCollapser then
    if insert(HW.collapserSlot) then
      S.collapserIn = true
      log("Collapser в input bus")
    else
      setAllowed(false); S.disabled = true
      log("Collapser не вставлен — машина остановлена", "err")
    end
  else
    setAllowed(false); S.disabled = true
    log("Машина остановлена, ждём естественного схлопывания (~15 мин)")
  end
  protect()
end

local function startRecovery(reason)
  resetCycle()
  S.plan = makePlan(CFG)
  S.unknown = true
  S.phase = "RECOVERY"
  log(reason .. " — аварийное закрытие", "warn")
  if CFG.useCollapser and insert(HW.collapserSlot) then
    S.collapserIn = true
    log("Collapser в input bus")
  else
    setAllowed(false); S.disabled = true
    log("Collapser недоступен — машина остановлена", "err")
  end
  protect()
end

-- Простой машины в фазе ОТКРЫТИЕ: выкл/вкл работу → hasWorkJustBeenEnabled → проверка рецепта
-- (в 2.9 простаивающий BHC проверяет рецепты только по событиям).
local function kickMachine()
  setAllowed(false)
  setAllowed(true)
end

local function openHole(manual)
  pollRes()
  local ok, why = ready(manual)
  if not ok then log(why, "warn"); return false end
  resetCycle()
  S.plan = makePlan(CFG)
  setAllowed(true)
  local seedsInBus = busScan()
  if seedsInBus and seedsInBus > 0 then
    log("В input bus уже лежит seed — повторно не вставляю", "warn")
    kickMachine()
  elseif not insert(HW.seedSlot) then
    log("Не удалось переместить seed в input bus", "err")
    return false
  end
  S.phase = "OPENING"
  S.openingAt = computer.uptime()
  S.openAttempt = 1
  log(("Seed: цель %d%%, жизнь %d с"):format(S.plan.target, S.plan.maxRuntime), "ok")
  return true
end

local function openingTimeout(now)
  local seeds = busScan()
  if seeds == nil then
    alarm("Не читается input bus (проверь HW.busSide) и дыра не открылась")
    S.phase = "IDLE"
  elseif seeds > 0 then
    if S.openAttempt < HW.openAttempts then
      S.openAttempt = S.openAttempt + 1
      S.openingAt = now
      log(("Seed не принят, повтор %d/%d"):format(S.openAttempt, HW.openAttempts), "warn")
      kickMachine()
    else
      alarm("Seed лежит в bus, машина его не берёт (структура, питание, maintenance?)")
      S.phase = "IDLE"
    end
  else
    -- seed забран, но импульсов нет: дыра открыта без контроля — закрываем
    alarm("Seed принят, но импульсов нет — проверь utility hatch (PULSE) и HW.hatchSide")
    if CFG.useCollapser then insert(HW.collapserSlot) end
    S.phase = "IDLE"
  end
end

local function decide()
  local P = S.plan
  if S.phase == "DECAY" then
    if S.stab <= P.target then
      if P.hold > 0 then
        setST(true)
        S.phase = "HOLD"
        log(("%d%% → spacetime ВКЛ на %d с"):format(S.stab, P.hold), "ok")
      else
        beginClosing("Цель достигнута")
      end
    end
  elseif S.phase == "HOLD" then
    if S.drains >= P.hold then beginClosing("Стабилизация завершена") end
  elseif S.phase == "CLOSING" or S.phase == "RECOVERY" then
    protect()
  end
end

local function onPulse()
  local now = computer.uptime()
  S.lastPulse = now
  if S.phase == "IDLE" then
    startRecovery("Найдена уже открытая дыра")
  elseif S.phase == "COLLAPSE" then
    S.phase = S.prevPhase or "CLOSING"
    log("Импульсы вернулись", "warn")
  elseif S.phase == "OPENING" then
    S.phase = "DECAY"
    log("Дыра открыта (100%)", "ok")
  end

  S.pulses = S.pulses + 1
  local eff, work = stEffective(now), mWork()
  local kind
  if S.unknown then
    if eff then S.extraDrains = S.extraDrains + 1 end
    kind = eff and "h" or "c"
  else
    if eff and S.stab > 0 then
      S.drains = S.drains + 1
      S.cycleST = S.cycleST + drainCost(S.drains)
      if S.phase == "CLOSING" then S.extraDrains = S.extraDrains + 1 end
      kind = "h"
    else
      S.stab = S.stab - 1
      if S.stab <= 0 then kind = "x" elseif S.phase == "CLOSING" then kind = "c" else kind = "d" end
    end
    if S.stab <= 0 and not S.unstableLogged then
      S.unstableLogged = true
      log("Дыра стала НЕСТАБИЛЬНОЙ", "err")
    end
    if S.stab <= 0 and work and not S.voidLogged then
      S.voidLogged = true
      CFG.stats.voids = CFG.stats.voids + 1
      log("Рецепт шёл при нестабильной дыре — вероятен войд!", "err")
    end
  end
  S.history[#S.history + 1] = work and kind:upper() or kind
  decide()
  S.dirty = true
end

local function finishCycle(now)
  if not S.unknown then
    CFG.stats.cycles = CFG.stats.cycles + 1
    CFG.stats.spacetime = CFG.stats.spacetime + S.cycleST
    log(("Цикл: %d с, %s L spacetime"):format(S.pulses, fmtL(S.cycleST)), "ok")
  else
    log("Аварийное закрытие завершено", "ok")
  end
  setAllowed(true)
  saveCfg()
  resetCycle()
  S.phase = "IDLE"
  S.nextReady = now + 2
end

-- Раннее закрытие: входов нет и машина простаивает earlyClose секунд подряд
local function checkEarlyClose(now)
  local P = S.plan
  if P.earlyClose <= 0 or S.unknown then S.idleSince = nil; return end
  if S.res.inputs or S.mach.work then S.idleSince = nil; return end
  S.idleSince = S.idleSince or now
  if now - S.idleSince >= P.earlyClose then
    S.idleSince = nil
    beginClosing(("Входов нет %d с"):format(P.earlyClose))
  end
end

local function tick(now)
  local ph = S.phase
  if ph == "IDLE" then
    if now >= S.nextReady and now >= S.grace then
      S.nextReady = now + 2
      local ok, why = ready(false)
      S.readyOk, S.readyMsg = ok, why
      -- причины блокировки (кроме обычного «нет входов») пишем в журнал один раз
      if not ok and why ~= S.lastBlock and not why:find("Нет входов") then log(why, "warn") end
      S.lastBlock = (not ok) and why or nil
      if ok and CFG.auto and not S.alarm then openHole(false) end
    end
  elseif ph == "OPENING" then
    if now - S.openingAt > HW.openAttemptSec then openingTimeout(now) end
  elseif OPEN_PHASES[ph] then
    if now - S.lastPulse > HW.pulseTimeout then
      setST(false)
      if ph == "CLOSING" or ph == "RECOVERY" then
        S.prevPhase = ph
        S.phase = "COLLAPSE"
        S.collapseAt = now
        log("Дыра закрыта", "ok")
      else
        alarm("Импульсы utility hatch пропали во время фазы «" .. PHASE_RU[ph] .. "»")
        setAllowed(true)
        resetCycle()
        S.phase = "IDLE"
      end
    elseif ph == "CLOSING" or ph == "RECOVERY" then
      protect()
    else
      checkEarlyClose(now)
    end
  elseif ph == "COLLAPSE" then
    if now - S.collapseAt >= HW.collapseDelay then finishCycle(now) end
  end
end

-- ============================== РЕНДЕР ==============================
local W, H
local FB, FR = {}, {}   -- back / front: [i] = {ch, fg, bg}
local BTN = {}

local C = {
  bg = 0x0A0A12, panel = 0x12121E, border = 0x34345A, text = 0xD8D8E8, dim = 0x6E6E8C,
  faint = 0x3A3A50, title = 0x24103C, accent = 0xB070FF, cyan = 0x40D8FF, green = 0x50D878,
  yellow = 0xFFC840, red = 0xFF4848, orange = 0xFF9030, black = 0x000000, white = 0xFFFFFF,
  z1 = 0x3CB464, z1d = 0x12261A, z2 = 0xE6B432, z2d = 0x2E2410, z4 = 0xD24BD2, z4d = 0x2C102C,
  btn = 0x24243A, btnOn = 0x2F7A4A, btnWarn = 0x7A3030, btnAcc = 0x4A2A7A,
}
local HIST = {
  d = 0x173A4E, D = 0x2F86B0,   -- распад: простой / работа
  h = 0x45285F, H = 0xB070FF,   -- стабилизация
  c = 0x1A4A40, C = 0x40C0A0,   -- хвост после стабилизации
  x = 0x5A1A1A, X = 0xFF4848,   -- нестабильна
}

local function cellsOf(s)
  local t = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
  return t
end

local function put(x, y, s, fg, bg)
  if y < 1 or y > H then return end
  local cs = cellsOf(s)
  for i = 1, #cs do
    local xx = x + i - 1
    if xx >= 1 and xx <= W then
      local c = FB[(y - 1) * W + xx]
      c[1], c[2], c[3] = cs[i], fg, bg
    end
  end
end

local function fill(x, y, w, h, ch, fg, bg)
  for yy = y, y + h - 1 do
    if yy >= 1 and yy <= H then
      for xx = x, x + w - 1 do
        if xx >= 1 and xx <= W then
          local c = FB[(yy - 1) * W + xx]
          c[1], c[2], c[3] = ch, fg, bg
        end
      end
    end
  end
end

local function initBuffers()
  FB, FR = {}, {}
  for i = 1, W * H do FB[i] = { " ", C.text, C.bg }; FR[i] = { nil, nil, nil } end
end

local curFg, curBg
local function flush()
  for y = 1, H do
    local x = 1
    while x <= W do
      local i = (y - 1) * W + x
      local b, f = FB[i], FR[i]
      if b[1] ~= f[1] or b[2] ~= f[2] or b[3] ~= f[3] then
        -- run одного цвета; неизменённые ячейки внутри run (до 6 подряд) включаем,
        -- чтобы не дробить вызовы gpu.set, хвост из неизменённых — отрезаем
        local fg, bg, x0, parts, trail = b[2], b[3], x, {}, 0
        while x <= W do
          local j = (y - 1) * W + x
          local bb, ff = FB[j], FR[j]
          if bb[2] ~= fg or bb[3] ~= bg then break end
          if bb[1] == ff[1] and bb[2] == ff[2] and bb[3] == ff[3] then
            if trail >= 6 then break end
            trail = trail + 1
          else
            trail = 0
          end
          parts[#parts + 1] = bb[1]
          ff[1], ff[2], ff[3] = bb[1], bb[2], bb[3]
          x = x + 1
        end
        for _ = 1, trail do parts[#parts] = nil end
        if curFg ~= fg then gpu.setForeground(fg); curFg = fg end
        if curBg ~= bg then gpu.setBackground(bg); curBg = bg end
        gpu.set(x0, y, table.concat(parts))
        x = x0 + #parts
      else
        x = x + 1
      end
    end
  end
end

local function button(x, y, w, h, label, fg, bg, fn)
  fill(x, y, w, h, " ", fg, bg)
  put(x + math.floor((w - ulen(label)) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
  BTN[#BTN + 1] = { x, y, x + w - 1, y + h - 1, fn }
end

local function box(x, y, w, h, title, tcol)
  fill(x, y, w, h, " ", C.text, C.panel)
  put(x, y, "┌" .. string.rep("─", w - 2) .. "┐", C.border, C.panel)
  for yy = y + 1, y + h - 2 do
    put(x, yy, "│", C.border, C.panel)
    put(x + w - 1, yy, "│", C.border, C.panel)
  end
  put(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘", C.border, C.panel)
  if title then put(x + 2, y, " " .. title .. " ", tcol or C.accent, C.panel) end
end

local function kv(x, y, w, key, val, vcol)
  put(x, y, key, C.dim, C.panel)
  put(x + w - ulen(val), y, val, vcol or C.text, C.panel)
end

local function rput(xr, y, s, fg, bg) put(xr - ulen(s) + 1, y, s, fg, bg) end

local function zoneCol(v, dim)
  if v < 20 then return dim and C.z4d or C.z4
  elseif v < 50 then return dim and C.z2d or C.z2 end
  return dim and C.z1d or C.z1
end

-- ---------- главный экран ----------
local function drawHeader()
  fill(1, 1, W, 1, " ", C.text, C.title)
  put(2, 1, "◉ ПСЕВДОСТАБИЛЬНАЯ ЧЁРНАЯ ДЫРА", C.accent, C.title)
  put(35, 1, "· контроль BHC", C.dim, C.title)
  local right = os.date("%H:%M")
  rput(W - 1, 1, right, C.dim, C.title)
  local a = CFG.auto and " АВТО ● " or " ПАУЗА ‖ "
  rput(W - 8, 1, a, CFG.auto and C.green or C.yellow, C.title)
end

local function drawPipeline()
  local y = 3
  if S.phase == "RECOVERY" then
    local s = " ⚠ ВОССТАНОВЛЕНИЕ: закрываем дыру с неизвестной стабильностью "
    put(math.floor((W - ulen(s)) / 2) + 1, y, s, C.black, C.orange)
    return
  end
  local cur = 1
  for i, p in ipairs(PHASES) do if p == S.phase then cur = i end end
  local P = S.plan or makePlan(CFG)
  local total = 0
  for i, p in ipairs(PHASES) do total = total + ulen(PHASE_RU[p]) + 2 + (i > 1 and 3 or 0) end
  local x = math.floor((W - total) / 2) + 1
  for i, p in ipairs(PHASES) do
    if i > 1 then put(x, y, " › ", C.faint, C.bg); x = x + 3 end
    local label = " " .. PHASE_RU[p] .. " "
    local fg, bg = C.dim, C.panel
    if i == cur then fg, bg = C.black, (p == "HOLD" and C.accent or C.cyan)
    elseif p == "HOLD" and P.hold == 0 then fg = C.faint
    elseif i < cur and cur > 1 then fg = C.green end
    put(x, y, label, fg, bg)
    x = x + ulen(label)
  end
end

local function drawStability()
  local P = S.plan or makePlan(CFG)
  local open = OPEN_PHASES[S.phase] or S.phase == "COLLAPSE"
  local y = 5
  put(3, y, "СТАБИЛЬНОСТЬ", C.dim, C.bg)
  local stab = S.stab or 100
  local vtxt, vcol
  if not open then vtxt, vcol = "—", C.dim
  elseif S.unknown then vtxt, vcol = "??", C.orange
  else vtxt, vcol = math.max(0, stab) .. "%", (stab <= 0) and C.red or zoneCol(stab) end
  put(17, y, vtxt, vcol, C.bg)
  local mtxt = ""
  if open and not S.unknown and stab > 0 then
    local m = zoneMult(stab)
    mtxt = "×" .. m .. " параллели" .. (m == 4 and " · обычные рецепты без лимита" or "")
  end
  put(23, y, mtxt, C.text, C.bg)
  put(70, y, "цель " .. P.target .. "%", C.dim, C.bg)
  local st, scol
  if S.phase == "IDLE" or S.phase == "OPENING" then st, scol = "дыра закрыта", C.dim
  elseif S.phase == "COLLAPSE" then st, scol = "схлопывается", C.dim
  elseif not S.unknown and stab <= 0 then st, scol = "⚠ НЕСТАБИЛЬНА — рецепты войдятся", C.red
  elseif S.stOn then st, scol = "▣ заморожена spacetime", C.accent
  else st, scol = "распад −1%/с", C.cyan end
  rput(W - 2, y, st, scol, C.bg)

  local x0, bw = 3, W - 4
  for i = 1, bw do
    local v = (i - 0.5) / bw * 100
    local filled = open and not S.unknown and v <= stab
    local bg = zoneCol(v, not filled)
    fill(x0 + i - 1, 6, 1, 2, " ", C.text, bg)
  end
  local xt = x0 + math.floor(P.target / 100 * bw)
  put(xt, 6, "┃", C.white, zoneCol(P.target, not (open and not S.unknown and P.target <= stab)))
  put(xt, 7, "┃", C.white, zoneCol(P.target, not (open and not S.unknown and P.target <= stab)))
  local function at(pct) return x0 + math.floor(pct / 100 * bw) end
  put(x0, 8, "0", C.dim, C.bg)
  put(at(10) - 1, 8, "×4", C.z4, C.bg)
  put(at(20), 8, "20", C.dim, C.bg)
  put(at(35) - 1, 8, "×2", C.z2, C.bg)
  put(at(50), 8, "50", C.dim, C.bg)
  put(at(75) - 1, 8, "×1", C.z1, C.bg)
  rput(x0 + bw - 1, 8, "100%", C.dim, C.bg)
end

local function drawLifetime()
  local P = S.plan or makePlan(CFG)
  local y = 10
  put(3, y, "ВРЕМЯ ЖИЗНИ", C.dim, C.bg)
  local open = S.phase ~= "IDLE" and S.phase ~= "OPENING"
  put(17, y, (open and S.pulses or 0) .. " / " .. P.maxRuntime .. " с", C.text, C.bg)
  put(31, y, ("стаб. %d–%d с · collapser %d с"):format(P.holdStart, P.closeAt, P.closeAt), C.dim, C.bg)
  local lx = W - 62
  local function leg(x, col, txt) put(x, y, "■", col, C.bg); put(x + 2, y, txt, C.dim, C.bg); return x + 3 + ulen(txt) end
  lx = leg(lx, HIST.D, "распад")
  lx = leg(lx, HIST.H, "стабилизация")
  lx = leg(lx, HIST.C, "хвост")
  lx = leg(lx, HIST.X, "нестабильна")
  put(lx, y, "(ярко = работа)", C.faint, C.bg)

  local x0, bw = 3, W - 4
  local hist = S.history or {}
  local scale = math.max(P.maxRuntime, #hist, 1)
  for i = 1, bw do
    local s2 = math.floor(i * scale / bw)
    local s1 = math.floor((i - 1) * scale / bw) + 1
    -- ячейка = диапазон секунд; «работа» важнее «простоя», иначе — последняя секунда
    local col, last
    for s = s1, s2 do
      local k = hist[s]
      if k then
        last = k
        if k:upper() == k then col = HIST[k] end
      end
    end
    if not col and last then col = HIST[last] end
    if not col then
      local sec = s2
      if sec <= P.holdStart then col = 0x141C24
      elseif sec <= P.closeAt then col = 0x1E1428
      else col = 0x14201C end
    end
    fill(x0 + i - 1, 11, 1, 1, " ", C.text, col)
  end
  local function at(sec) return x0 + math.floor(sec / scale * bw) end
  put(x0, 12, "0", C.dim, C.bg)
  if P.hold > 0 then
    put(at(P.holdStart), 12, "▲" .. P.holdStart .. "с", C.accent, C.bg)
  end
  put(at(P.closeAt), 12, "▲" .. P.closeAt .. "с", C.cyan, C.bg)
  rput(x0 + bw - 1, 12, scale .. " с", C.dim, C.bg)
end

local function drawPanels()
  local P = S.plan or makePlan(CFG)
  local y, h = 14, 7
  local xs = { 2, 33, 64, 89 }
  local ws = { 30, 30, 24, W - 89 }
  local open = OPEN_PHASES[S.phase]

  -- SPACETIME
  local x, w = xs[1], ws[1]
  box(x, y, w, h, "SPACETIME", C.accent)
  local iw = w - 4
  kv(x + 2, y + 1, iw, "Цена сейчас", S.stOn and (fmtL(drainCost((S.drains or 0) + 1)) .. " L/с") or "выкл",
     S.stOn and C.accent or C.dim)
  local dbl = "—"
  if open and not S.unknown and (S.drains or 0) > 0 then dbl = (30 - S.drains % 30) .. " сл." end
  kv(x + 2, y + 2, iw, "Удвоение через", dbl, C.text)
  kv(x + 2, y + 3, iw, "За этот цикл", S.unknown and "?" or (fmtL(S.cycleST or 0) .. " L"), C.text)
  kv(x + 2, y + 4, iw, "План/+" .. P.extra .. "с", fmtL(P.holdCost) .. " / " .. fmtL(P.fullCost) .. " L", C.text)
  if hasStocker() then
    kv(x + 2, y + 5, iw, "В стокере", fmtL(S.res.st) .. " L", S.res.st >= P.fullCost and C.green or C.red)
  else
    kv(x + 2, y + 5, iw, "Предохранитель", "≥ " .. fmtL(math.ceil(P.fullCost * 1.5)) .. " L", C.dim)
  end

  -- МАШИНА
  x, w = xs[2], ws[2]
  box(x, y, w, h, "МАШИНА", C.cyan)
  iw = w - 4
  local m = S.mach
  local stxt, scol = "ПРОСТОЙ", C.dim
  if not m.allowed then stxt, scol = "ОТКЛЮЧЕНА", C.orange elseif m.work then stxt, scol = "РАБОТАЕТ", C.cyan end
  kv(x + 2, y + 1, iw, "Состояние", stxt, scol)
  put(x + 2, y + 2, "Рецепт", C.dim, C.panel)
  local bwid = iw - 12
  local nfill = m.work and math.floor(m.frac * bwid + 0.5) or 0
  fill(x + 9, y + 2, bwid, 1, " ", C.text, C.faint)
  if nfill > 0 then fill(x + 9, y + 2, nfill, 1, " ", C.text, C.cyan) end
  rput(x + 2 + iw - 1, y + 2, m.work and (math.floor(m.frac * 100) .. "%") or "—", C.text, C.panel)
  kv(x + 2, y + 3, iw, "Осталось", m.work and string.format("%.1f из %.1f с", m.rem, m.dur) or "—", C.text)
  local par = "—"
  if open and not S.unknown and S.stab > 0 then par = "×" .. zoneMult(S.stab) end
  kv(x + 2, y + 4, iw, "Параллели", par, C.text)
  local mr = CFG.stats.maxRecipe or 0
  kv(x + 2, y + 5, iw, "Самый длинный", mr > 0 and string.format("%.1f с", mr) or "—",
     P.unprotectable and C.red or C.text)

  -- РЕСУРСЫ
  x, w = xs[3], ws[3]
  box(x, y, w, h, "РЕСУРСЫ", C.green)
  iw = w - 4
  kv(x + 2, y + 1, iw, "Seeds", tostring(S.res.seeds), S.res.seeds > 0 and C.text or C.red)
  kv(x + 2, y + 2, iw, "Collapsers", tostring(S.res.coll),
     (S.res.coll > 0 or not CFG.useCollapser) and C.text or C.red)
  kv(x + 2, y + 3, iw, "Входы", S.res.inputs and "есть" or "нет", S.res.inputs and C.green or C.dim)
  kv(x + 2, y + 4, iw, "Циклы/войды", CFG.stats.cycles .. " / " .. CFG.stats.voids,
     CFG.stats.voids > 0 and C.yellow or C.text)
  kv(x + 2, y + 5, iw, "ST всего", fmtL(CFG.stats.spacetime) .. " L", C.text)

  -- ЖУРНАЛ
  x, w = xs[4], ws[4]
  box(x, y, w, h, "ЖУРНАЛ", C.dim)
  iw = w - 4
  local kcol = { info = C.text, ok = C.green, warn = C.yellow, err = C.red }
  for i = 1, 5 do
    local e = LOG[i]
    if e then
      put(x + 2, y + i, e.t:sub(1, 5), C.faint, C.panel)
      put(x + 8, y + i, fit(e.m, iw - 6), kcol[e.k] or C.text, C.panel)
    end
  end
end

local function statusLine()
  local P = S.plan or makePlan(CFG)
  if S.alarm then return "⚠ " .. S.alarm .. " — нажми «АВТО», чтобы сбросить", C.red end
  local ph = S.phase
  if ph == "IDLE" then
    if not CFG.auto then return "Автоматика на паузе. " .. S.readyMsg, C.yellow end
    return S.readyMsg, S.readyOk and C.green or C.dim
  elseif ph == "OPENING" then
    return ("Ждём, пока машина примет seed: попытка %d/%d, %d с"):format(S.openAttempt or 1, HW.openAttempts,
      math.floor(computer.uptime() - S.openingAt)), C.cyan
  end
  local idle = ""
  if (ph == "DECAY" or ph == "HOLD") and S.idleSince and P.earlyClose > 0 then
    idle = (" · входов нет — закрытие через %d с"):format(
      math.max(0, math.ceil(P.earlyClose - (computer.uptime() - S.idleSince))))
  end
  if ph == "DECAY" then
    if P.hold > 0 then return ("Распад: до стабилизации %d с"):format(math.max(0, S.stab - P.target)) .. idle, C.cyan end
    return ("Распад: до закрытия %d с"):format(math.max(0, S.stab - P.target)) .. idle, C.cyan
  elseif ph == "HOLD" then
    return ("Стабилизация: осталось %d с, следующий слив %s L"):format(
      math.max(0, P.hold - S.drains), fmtL(drainCost(S.drains + 1))) .. idle, C.accent
  elseif ph == "CLOSING" then
    if S.mach.work then
      return ("Закрытие: ждём конец рецепта (%.1f с)%s"):format(S.mach.rem,
        S.stOn and " · защита держит стабильность" or ""), C.cyan
    end
    return "Закрытие: машина свободна, collapser сработает при следующей проверке", C.cyan
  elseif ph == "RECOVERY" then
    return "Восстановление: ждём закрытия дыры", C.orange
  elseif ph == "COLLAPSE" then
    return "Дыра закрыта, пауза перед следующим циклом", C.green
  end
  return "", C.text
end

local function drawMain()
  drawHeader()
  drawPipeline()
  drawStability()
  drawLifetime()
  drawPanels()
  local s, col = statusLine()
  put(3, 21, "● ", col, C.bg)
  put(5, 21, fit(s, W - 30), col, C.bg)
  rput(W - 2, 21, "Ctrl+Alt+C — выход", C.faint, C.bg)

  local bw, by, gap = 24, 22, 1
  local x = 3
  button(x, by, bw, 3, CFG.auto and "АВТО: ВКЛ" or "АВТО: ПАУЗА", C.white, CFG.auto and C.btnOn or C.btn, function()
    if S.alarm then S.alarm = nil; CFG.auto = true; log("Тревога сброшена, автоматика ВКЛ", "ok")
    else CFG.auto = not CFG.auto; log(CFG.auto and "Автоматика ВКЛ" or "Автоматика на паузе") end
    S.nextReady = 0
    saveCfg()
  end)
  x = x + bw + gap
  local canOpen = S.phase == "IDLE"
  button(x, by, bw, 3, "ОТКРЫТЬ СЕЙЧАС", canOpen and C.white or C.faint, canOpen and C.btnAcc or C.btn, function()
    if S.phase ~= "IDLE" then log("Дыра уже в работе", "warn"); return end
    openHole(true)
  end)
  x = x + bw + gap
  local canClose = S.phase == "DECAY" or S.phase == "HOLD"
  button(x, by, bw, 3, "ЗАКРЫТЬ СЕЙЧАС", canClose and C.white or C.faint, canClose and C.btnWarn or C.btn, function()
    if S.phase == "DECAY" or S.phase == "HOLD" then beginClosing("Ручное закрытие")
    else log("Сейчас закрывать нечего", "warn") end
  end)
  x = x + bw + gap
  button(x, by, bw, 3, "НАСТРОЙКИ", C.white, C.btn, function()
    S.draft = copy(CFG); S.screen = "settings"
  end)
  x = x + bw + gap
  local armed = S.exitArmed and computer.uptime() - S.exitArmed < 3
  button(x, by, W - 2 - x, 3, armed and "НАЖМИ ЕЩЁ РАЗ" or "ВЫХОД", C.white, armed and C.btnWarn or C.btn, function()
    if S.exitArmed and computer.uptime() - S.exitArmed < 3 then S.running = false
    else S.exitArmed = computer.uptime() end
  end)
end

-- ---------- экран настроек ----------
local function drawSettings()
  drawHeader()
  local D = S.draft
  put(3, 3, "НАСТРОЙКИ ЦИКЛА", C.accent, C.bg)
  if S.phase ~= "IDLE" then
    put(22, 3, "· изменения применятся со следующего цикла", C.yellow, C.bg)
  end

  local function stepper(y, label, key, steps, hint, hintCol)
    put(4, y, label, C.text, C.bg)
    local x = 68                                   -- колонка значений
    for i = 1, #steps do x = x - (ulen("−" .. steps[i]) + 3) end
    for i = #steps, 1, -1 do
      local st = steps[i]
      local t = "−" .. st
      button(x, y, ulen(t) + 2, 1, t, C.white, C.btn, function()
        D[key] = clamp(D[key] - st, LIMITS[key][1], LIMITS[key][2])
      end)
      x = x + ulen(t) + 3
    end
    local v = tostring(D[key])
    put(x + math.floor((6 - ulen(v)) / 2), y, v, C.white, C.bg)
    x = x + 7
    for i = 1, #steps do
      local st = steps[i]
      local t = "+" .. st
      button(x, y, ulen(t) + 2, 1, t, C.white, C.btn, function()
        D[key] = clamp(D[key] + st, LIMITS[key][1], LIMITS[key][2])
      end)
      x = x + ulen(t) + 3
    end
    if hint then put(x + 2, y, hint, hintCol or C.dim, C.bg) end
  end

  local function toggle(x, y, label, key)
    put(x, y, label, C.text, C.bg)
    local bx = x + ulen(label) + 2
    button(bx, y, 8, 1, D[key] and "ВКЛ" or "ВЫКЛ", C.white, D[key] and C.btnOn or C.btnWarn, function()
      D[key] = not D[key]
    end)
    return bx + 12
  end

  local P = makePlan(D)
  stepper(4, "Время жизни дыры, с (включая базовые 100)", "maxRuntime", { 1, 10, 50 },
    P.hold > 0 and ("стабилизация " .. P.hold .. " с") or "без spacetime")
  local m = zoneMult(D.targetStability)
  stepper(6, "Целевая стабильность, %", "targetStability", { 1, 5 },
    "×" .. m .. " параллели", m == 4 and C.z4 or (m == 2 and C.z2 or C.z1))
  stepper(8, "Мин. лимит доп. стабилизации (защита), с", "protectMaxSec", { 1, 5, 30 },
    "в цикле сейчас: " .. P.extra .. " с")
  stepper(10, "Потолок авто-лимита защиты, с", "protectAutoCap", { 5, 30 },
    D.autoProtect and "по самому длинному рецепту" or "авто-лимит выключен", D.autoProtect and C.dim or C.faint)
  stepper(12, "Запас по времени для защиты, с", "safetyMargin", { 1 })
  stepper(14, "Раннее закрытие: нет входов и простой, с", "earlyCloseSec", { 1, 5 },
    D.earlyCloseSec > 0 and "экономит spacetime" or "выключено", D.earlyCloseSec > 0 and C.dim or C.faint)
  local tx = toggle(4, 16, "Защита от войда", "voidProtection")
  tx = toggle(tx, 16, "Авто-лимит защиты", "autoProtect")
  toggle(tx, 16, "Закрывать collapser'ом", "useCollapser")

  box(3, 17, W - 4, 4, "СВОДКА", C.accent)
  local l1 = ("Распад до %d%% за %d с → стабилизация %d с (%d–%d с) → collapser на %d с → закрытие после рецепта")
    :format(D.targetStability, P.holdStart, P.hold, P.holdStart, P.closeAt, P.closeAt)
  put(5, 18, fit(l1, W - 8), C.text, C.panel)
  local l2 = ("Spacetime: %s L/цикл (пик %s L/с) · с защитой %d с до %s L (пик %s L/с) · фильтр стокера/предохранителя ≥ %s L")
    :format(fmtL(P.holdCost), fmtL(P.peak), P.extra, fmtL(P.fullCost), fmtL(P.fullPeak),
      fmtL(math.ceil(P.fullCost * 1.5)))
  put(5, 19, fit(l2, W - 8), C.text, C.panel)

  local warn, wcol = "", C.yellow
  local mr = CFG.stats.maxRecipe or 0
  if P.unprotectable then
    warn, wcol = ("Рецепт %.0f с не спасти: защиты нужно больше потолка %d с"):format(mr, P.extraCap), C.red
  elseif D.targetStability >= 50 then warn = "Цель ≥ 50%: параллели без бонуса."
  elseif D.targetStability >= 20 then warn = "Цель ≥ 20%: только ×2 параллели." end
  put(3, 21, fit(warn, 80), wcol, C.bg)
  local rtxt = mr > 0 and ("Самый длинный рецепт: %.1f с"):format(mr) or "Рецепты ещё не замерены"
  rput(W - 15, 21, rtxt, C.dim, C.bg)
  button(W - 13, 21, 12, 1, "сбросить", C.white, C.btn, function()
    CFG.stats.maxRecipe = 0
    if D.stats then D.stats.maxRecipe = 0 end
    saveCfg()
    log("Замер длины рецептов сброшен")
  end)

  local bw = 30
  button(3, 22, bw, 3, "СОХРАНИТЬ", C.white, C.btnOn, function()
    local stats = CFG.stats
    CFG = S.draft; CFG.stats = stats
    saveCfg(); S.screen = "main"; S.nextReady = 0
    log(("Настройки: жизнь %d с, цель %d%%"):format(CFG.maxRuntime, CFG.targetStability), "ok")
  end)
  button(3 + bw + 1, 22, bw, 3, "ОТМЕНА", C.white, C.btn, function() S.screen = "main" end)
  button(3 + (bw + 1) * 2, 22, bw, 3, "ПО УМОЛЧАНИЮ", C.white, C.btnWarn, function()
    local keep = { auto = D.auto, stats = D.stats }
    S.draft = copy(DEFAULTS); S.draft.auto = keep.auto; S.draft.stats = keep.stats
  end)
end

local function draw()
  BTN = {}
  fill(1, 1, W, H, " ", C.text, C.bg)
  if S.screen == "settings" then drawSettings() else drawMain() end
  flush()
  S.dirty = false
end

local function onTouch(x, y)
  for i = #BTN, 1, -1 do
    local b = BTN[i]
    if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then
      local ok, err = pcall(b[5])
      if not ok then log("Ошибка кнопки: " .. tostring(err), "err") end
      S.dirty = true
      return
    end
  end
end

-- ============================== ЗАПУСК ==============================
local oldW, oldH

local function shutdown()
  if OPEN_PHASES[S.phase] and not S.collapserIn and CFG.useCollapser then
    insert(HW.collapserSlot)
  end
  if rs then pcall(rs.setOutput, HW.transmitterSide, 0) end
  if CFG then saveCfg() end
  if gpu and oldW then
    pcall(gpu.setBackground, 0x000000); pcall(gpu.setForeground, 0xFFFFFF)
    pcall(gpu.setResolution, oldW, oldH)
    pcall(gpu.fill, 1, 1, oldW, oldH, " ")
  end
  if OPEN_PHASES[S.phase] then
    print("BHC: программа остановлена при открытой дыре (" .. PHASE_RU[S.phase] .. ").")
    print("     Spacetime выключен" .. (CFG and CFG.useCollapser and ", collapser отправлен в bus." or "."))
  end
end

local function main()
  local ok, err = bindComponents()
  if not ok then error(err, 0) end
  CFG = loadCfg()
  local mw, mh = gpu.maxResolution()
  W, H = HW.resolution[1], HW.resolution[2]
  if mw < W or mh < H then
    error(("Нужны видеокарта и экран T3 (нужно %dx%d, доступно %dx%d)"):format(W, H, mw, mh), 0)
  end
  oldW, oldH = gpu.getResolution()
  gpu.setResolution(W, H)
  initBuffers()

  resetCycle()
  S.plan = makePlan(CFG)
  safe(rs.setOutput, HW.transmitterSide, 0)
  S.stOn, S.stChangedAt = false, -100
  S.grace = computer.uptime() + HW.pulseTimeout   -- если дыра уже открыта — поймаем импульс
  log("BHC Control " .. VERSION .. " запущен", "ok")
  log("Стороны: " .. HW_SOURCE, HW_SOURCE == HW_PATH and "info" or "warn")
  if not hasStocker() then log("Стокера нет: запас spacetime не проверяется (предохранитель у хэтча)", "info") end
  pollRes(); pollMachine()

  local nextMach, nextRes, nextDraw = 0, 0, 0
  while S.running do
    local ev = { event.pull(0.25) }
    local name = ev[1]
    if name == "redstone_changed" then
      local addr, side, old, new = ev[2], ev[3], ev[4], ev[5]
      if addr == rs.address and side == HW.hatchSide and (old or 0) == 0 and (new or 0) > 0 then
        onPulse()
      end
    elseif name == "touch" then
      onTouch(ev[3], ev[4])
    elseif name == "interrupted" then
      S.running = false
    end
    local now = computer.uptime()
    if now >= nextMach then pollMachine(); nextMach = now + 0.5 end
    if now >= nextRes then pollRes(); nextRes = now + 2 end
    tick(now)
    if S.dirty or now >= nextDraw then draw(); nextDraw = now + 0.5 end
  end
end

local ok, err = xpcall(main, debug.traceback)
local okS, errS = pcall(shutdown)
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write("BHC: " .. tostring(err) .. "\n")
end
if not okS then io.stderr:write("BHC shutdown: " .. tostring(errS) .. "\n") end

-- End-to-end: the real main.lua and adapter.lua against fake UE4SS objects, across several
-- simulated play sessions. Run with:  python tests/run_tests.py
package.path = "Scripts/?.lua;tests/?.lua;" .. package.path

local say = print
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; say("ok    " .. name)
    else failed = failed + 1; say("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function expect(cond, msg) if not cond then error(msg, 2) end end

local F = require("fake_ue4ss")
local store = require("store")
local cfg = require("config")
cfg.dryRun = false

-- Controlled clock and captured log ---------------------------------------------------------
local realTime = os.time
local now = 1790900000
os.time = function(t) if t then return realTime(t) end return now end
local logs = {}
print = function(s) logs[#logs + 1] = s end
local function logged(pattern)
    for _, l in ipairs(logs) do if l:find(pattern) then return l end end
    return nil
end
local function dumpLogs() return table.concat(logs, "") end

local saveTime = nil
local function saveAt(unix) saveTime = unix end

-- UE4SS hooks ---------------------------------------------------------------------------------
local hook, loopFn
function RegisterInitGameStatePostHook(f) hook = f end
function ExecuteWithDelay(ms, f) assert(math.type(ms) == "integer", "UE4SS needs whole milliseconds, got " .. tostring(ms)); f() end
function ExecuteInGameThread(f) f() end
function LoopAsync(_, f) loopFn = f end
function RegisterHook() end

-- Scene -----------------------------------------------------------------------------------------
local stone = F.slot("Stone", 5)
local wood = F.slot("Wood", 50)
local berries = F.slot("Berries", 40, 50)
local gameHour = 7.0
local playerAt = { X = 50000, Y = 0, Z = 0 }

local function buildWorld(baseN, stoneSlot)
    F.world = {
        PalBaseCampModel = { F.base(baseN) },
        PalMapObjectItemChestModel = { F.storage(baseN, F.container(baseN * 10 + 1, { stoneSlot, wood })) },
        PalMapObjectPalFoodBoxModel = { F.storage(baseN, F.container(baseN * 10 + 2, { berries })) },
        PalItemIDManager = { F.itemManager() },
        PalPlayerCharacter = { F.obj({ K2_GetActorLocation = function() return playerAt end }) },
        PalBaseCampManager = { F.obj({ UpdateIntervalSquaredDistanceFromPlayer = 10000 * 10000 }) },
        PalTimeManager = { F.obj({
            GetCurrentDayTimeType = function() return (gameHour >= 6 and gameHour < 18) and 1 or 2 end,
            GetCurrentPalWorldHoursFloat = function() return gameHour end,
            GetCurrentPalWorldTime_TotalDay = function() return 10 end,
            SetGameTime_FixDay = function() end,
        }) },
        PalSaveGameManager = { F.obj({ LoadedWorldSaveData = F.obj({ Timestamp = F.dt(saveTime) }) }) },
    }
end
F.items = { Stone = {}, Wood = {}, Berries = {} }

local function gameState(world)
    return { get = function()
        return F.obj({
            GetFullName = function() return "BP_PalGameStateInGame_C /Game/Pal/Maps/MainWorld_5/PL_MainWorld5:GS" end,
            GetWorldSaveDirectoryName = function() return F.fstr(world) end,
        })
    end }
end
local title = { get = function() return F.obj({ GetFullName = function() return "GS /Game/Pal/Maps/Title" end }) end }

-- Old-format state: one world's worth of learned rates and a heartbeat.
OFFLINE_PROGRESS_STATE_PATH = os.tmpname()
store.save(OFFLINE_PROGRESS_STATE_PATH, {
    lastSeen = now - 3700,
    bases = { [F.key(1)] = { processes = {
        ["make:Stone"] = { id = "make:Stone", kind = "work", inputs = {}, outputs = { Stone = 100 }, samples = 9 },
    } } },
})

saveAt(now - 3600)
buildWorld(1, stone)
dofile("Scripts/main.lua")

-- Sessions ----------------------------------------------------------------------------------

test("session 1: old state is migrated and downtime comes from the save's timestamp", function()
    hook(gameState("WORLD_A"))
    expect(logged("Moved learned rates from the old state format to world WORLD_A"), "migrated\n" .. dumpLogs())
    expect(logged("Offline 1%.00h, measured from the save's timestamp %(utc%)"), "save timestamp used\n" .. dumpLogs())
    expect(stone.StackCount == 80, "stone 5 + 100/h x 1h x 75% = 80, got " .. stone.StackCount)
    expect(logged("Stone 5 %-> 80 %(wanted %+75%)"), "read-back logged")
    local st = store.load(OFFLINE_PROGRESS_STATE_PATH)
    expect(st.worlds.WORLD_A.lastApply.items[F.key(1)].Stone.wanted == 75, "catch-up recorded for the save check")
    expect(st.bases == nil, "old fields removed")
end)

test("heartbeats learn the clock speed and new rates (with day and far tags)", function()
    for _ = 1, 10 do now = now + 60; gameHour = gameHour + 0.5; loopFn() end -- baseline sample
    stone.StackCount = stone.StackCount + 20
    for _ = 1, 10 do now = now + 60; gameHour = gameHour + 0.5; loopFn() end
    expect(logged("Measured 1 item change%(s%) over the last 10 min %(day%)"), "measured\n" .. dumpLogs())
    local st = store.load(OFFLINE_PROGRESS_STATE_PATH)
    local w = st.worlds.WORLD_A
    local tags = w.bases[F.key(1)].processes["make:Stone"].tags
    expect(tags["day:far"] and tags["day:far"].samples == 1, "day:far sample recorded")
    expect(math.abs(w.time.day.value - 30) < 1e-6, "clock: 30 game h per real h, got " .. tostring(w.time.day.value))
end)

test("session 2: the save check finds the last catch-up in the save", function()
    hook(title)
    logs = {}
    now = now + 600
    saveAt(now - 300)
    buildWorld(1, stone)
    hook(gameState("WORLD_A"))
    expect(logged("Save check: 1 of 1 changes from the last catch%-up are in this save"), "save check\n" .. dumpLogs())
    expect(logged("Offline 0%.08h"), "5 minutes offline")
end)

test("session 3: an older save than the last catch-up redoes it", function()
    hook(title)
    logs = {}
    now = now + 600
    saveAt(now - 7200)
    buildWorld(1, stone)
    hook(gameState("WORLD_A"))
    expect(logged("this save is from before the last catch%-up"), "older save noticed\n" .. dumpLogs())
    expect(logged("Offline 2%.00h"), "caught up from the older save's time")
end)

test("a write that doesn't read back puts the mod in safe mode", function()
    hook(title)
    logs = {}
    -- A second world whose storage ignores writes.
    local stubborn = F.slot("Stone", 5)
    local proxy = setmetatable({}, {
        __index = stubborn,
        __newindex = function(t, k, v) if k ~= "StackCount" then rawset(t, k, v) end end,
    })
    local st = store.load(OFFLINE_PROGRESS_STATE_PATH)
    st.worlds.WORLD_B = { bases = { [F.key(2)] = { processes = {
        ["make:Stone"] = { id = "make:Stone", kind = "work", tags = { all = { inputs = {}, outputs = { Stone = 100 }, samples = 9 } } },
    } } } }
    store.save(OFFLINE_PROGRESS_STATE_PATH, st)
    -- main.lua keeps state in memory; reload it as a new game session would.
    package.loaded.adapter, package.loaded.config = nil, nil
    cfg = require("config"); cfg.dryRun = false
    now = now + 600
    saveAt(now - 3600)
    buildWorld(2, proxy)
    dofile("Scripts/main.lua")
    hook(gameState("WORLD_B"))
    expect(logged("SAFE MODE: storage at base"), "safe mode entered\n" .. dumpLogs())
    local saved = store.load(OFFLINE_PROGRESS_STATE_PATH)
    expect(saved.safeMode ~= nil, "safe mode saved")
    expect(saved.worlds.WORLD_B.lastApply == nil, "the failed write isn't recorded as applied")
    expect(not logged("bases caught up"), "no 'caught up' announcement")
end)

test("in safe mode the next load only logs", function()
    hook(title)
    logs = {}
    now = now + 600
    saveAt(now - 3600)
    buildWorld(1, stone)
    local before = stone.StackCount
    hook(gameState("WORLD_A"))
    expect(logged("In safe mode"), "safe mode announced\n" .. dumpLogs())
    expect(stone.StackCount == before, "nothing written")
end)

test("rates filed under a per-launch TrivialObject name move to the real world", function()
    hook(title)
    logs = {}
    local st = store.load(OFFLINE_PROGRESS_STATE_PATH)
    st.worlds["TrivialObject: 0000018EF801C548"] = { lastSeen = now, bases = { [F.key(3)] = { processes = {
        ["make:Wood"] = { id = "make:Wood", kind = "work", tags = { all = { inputs = {}, outputs = { Wood = 10 }, samples = 9 } } },
    } } } }
    store.save(OFFLINE_PROGRESS_STATE_PATH, st)
    package.loaded.adapter, package.loaded.config = nil, nil
    cfg = require("config"); cfg.dryRun = false
    dofile("Scripts/main.lua")
    buildWorld(3, F.slot("Stone", 5))
    hook(gameState("WORLD_C"))
    expect(logged('Moved learned rates from "TrivialObject: 0000018EF801C548" to world WORLD_C'), "moved\n" .. dumpLogs())
    local saved = store.load(OFFLINE_PROGRESS_STATE_PATH)
    expect(saved.worlds["TrivialObject: 0000018EF801C548"] == nil, "old key removed")
    expect(saved.worlds.WORLD_C.bases[F.key(3)].processes["make:Wood"], "rates kept")
end)

os.remove(OFFLINE_PROGRESS_STATE_PATH)
os.remove(OFFLINE_PROGRESS_STATE_PATH .. ".bak")
print = say
os.time = realTime
say(("\n%d passed, %d failed"):format(passed, failed))
if arg then os.exit(failed == 0 and 0 or 1) end -- standalone lua
return failed                                    -- embedded (run_tests.py)

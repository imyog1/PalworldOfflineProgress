-- Run with:  python tests/run_tests.py
package.path = "Scripts/?.lua;" .. package.path

local catchup = require("catchup")
local rates = require("rates")
local store = require("store")

local passed, failed = 0, 0

local function near(a, b) return math.abs((a or 0) - (b or 0)) < 1e-6 end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end

local function expect(cond, msg) if not cond then error(msg, 2) end end
local function expectNear(actual, expected, what)
    if not near(actual, expected) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

test("constant production scales with time", function()
    local r = catchup.simulate({ stocks = {}, processes = {
        { id = "log", kind = "work", outputs = { wood = 120 } } } }, 2)
    expectNear(r.deltas.wood, 240, "wood")
    expect(#r.segments == 1, "one segment")
end)

test("production stops when storage is full", function()
    local r = catchup.simulate({ stocks = { wood = 0 }, caps = { wood = 100 }, processes = {
        { id = "log", kind = "work", outputs = { wood = 120 } } } }, 2)
    expectNear(r.stocks.wood, 100, "wood")
    expect(r.segments[1].reason == "wood storage full", "first segment ends at full storage")
    expectNear(r.segments[1].hours, 100 / 120, "time to fill")
end)

test("work stops when food runs out", function()
    local r = catchup.simulate({ stocks = { food = 30 }, processes = {
        { id = "eat", kind = "upkeep", inputs = { food = 60 } },
        { id = "log", kind = "work", outputs = { wood = 120 } } } }, 2)
    expectNear(r.stocks.food, 0, "food")
    expectNear(r.stocks.wood, 60, "wood (half an hour of work)")
    expect(r.segments[1].reason == "food ran out", "food runs out first")
end)

test("partial food supply slows work proportionally", function()
    local r = catchup.simulate({ stocks = { food = 0 }, processes = {
        { id = "farm", kind = "upkeep", outputs = { food = 30 } },
        { id = "eat", kind = "upkeep", inputs = { food = 60 } },
        { id = "log", kind = "work", outputs = { wood = 120 } } } }, 1)
    expectNear(r.stocks.wood, 60, "wood at 50%")
    expectNear(r.stocks.food, 0, "food")
end)

test("chain is limited by its slowest input", function()
    local r = catchup.simulate({ stocks = { ore = 0 }, processes = {
        { id = "mine", kind = "work", outputs = { ore = 30 } },
        { id = "smelt", kind = "work", inputs = { ore = 40 }, outputs = { ingot = 20 } } } }, 1)
    expectNear(r.stocks.ingot, 15, "ingots at 75%")
    expectNear(r.stocks.ore, 0, "ore")
end)

test("stockpile is used up, then the chain slows down", function()
    local r = catchup.simulate({ stocks = { ore = 10 }, processes = {
        { id = "mine", kind = "work", outputs = { ore = 30 } },
        { id = "smelt", kind = "work", inputs = { ore = 40 }, outputs = { ingot = 20 } } } }, 2)
    -- 1h at full speed drains the 10 ore (net -10/h), then 1h at 75%.
    expectNear(r.segments[1].hours, 1, "first segment")
    expectNear(r.stocks.ingot, 20 + 15, "ingots")
end)

test("efficiency applies to work but not upkeep", function()
    local r = catchup.simulate({ stocks = { food = 100 }, processes = {
        { id = "eat", kind = "upkeep", inputs = { food = 10 } },
        { id = "log", kind = "work", outputs = { wood = 100 } } } }, 1, { efficiency = 0.5 })
    expectNear(r.stocks.wood, 50, "wood")
    expectNear(r.stocks.food, 90, "food")
end)

test("full storage downstream backs up the chain", function()
    local r = catchup.simulate({ stocks = { ore = 100, ingot = 0 }, caps = { ingot = 10 }, processes = {
        { id = "smelt", kind = "work", inputs = { ore = 40 }, outputs = { ingot = 20 } } } }, 2)
    expectNear(r.stocks.ingot, 10, "ingots capped")
    expectNear(r.stocks.ore, 80, "only the ore needed for 10 ingots is used")
end)

test("no processes means no change", function()
    local r = catchup.simulate({ stocks = { wood = 5 }, processes = {} }, 5)
    expect(next(r.deltas) == nil, "no deltas")
end)

test("elapsed time: missing, backwards, short, capped, normal", function()
    local cfg = { minGapSeconds = 120, maxCatchupHours = 24 }
    expect(catchup.elapsedSeconds(nil, 1000, cfg) == 0, "no heartbeat")
    expect(catchup.elapsedSeconds(2000, 1000, cfg) == 0, "clock went backwards")
    expect(catchup.elapsedSeconds(1000, 1060, cfg) == 0, "quick restart")
    expect(catchup.elapsedSeconds(0, 48 * 3600, cfg) == 24 * 3600, "capped at 24h")
    expect(catchup.elapsedSeconds(0, 3600, cfg) == 3600, "one hour")
end)

test("fractions carry over between restarts", function()
    local carry, got = {}, 0
    for _ = 1, 3 do
        local whole
        whole, carry = catchup.wholeItems({ wood = 0.4 }, carry)
        got = got + (whole.wood or 0)
    end
    expect(got == 1, "0.4 x 3 gives 1 whole wood, got " .. got)
    expectNear(carry.wood, 0.2, "remainder")
    local whole = catchup.wholeItems({ food = -2.7 }, {})
    expect(whole.food == -2, "negatives round toward zero")
end)

test("timers finish or count down", function()
    local t = catchup.advanceTimers({ { id = "egg", remaining = 3600 }, { id = "crop", remaining = 9000 } }, 7200)
    expect(t[1].done and t[1].remaining == 0, "egg hatched")
    expect(not t[2].done and t[2].remaining == 1800, "crop has 30 min left")
end)

test("rates keep a running average and need enough samples to be trusted", function()
    local bs = {}
    rates.observe(bs, "smelt", "work", { ore = 20 }, { ingot = 10 }, 1800, 0.5)
    rates.observe(bs, "smelt", "work", { ore = 30 }, { ingot = 15 }, 1800, 0.5)
    local s = bs.processes.smelt.tags.all
    expect(s.samples == 2, "two samples")
    expectNear(s.outputs.ingot, 25, "running average of 20/h and 30/h")
    expect(#rates.processList(bs, 3) == 0, "not trusted yet")
    expect(#rates.processList(bs, 2) == 1, "trusted")
end)

test("feed box overflow spills back into chests", function()
    local r = catchup.simulate({ stocks = { food = 90 }, caps = { food = 100 }, processes = {
        { id = "make:food", kind = "work", outputs = { food = 20 } },
        { id = "spill:food", kind = "work", spillOf = "make:food", outputs = { Berries = 20 } } } }, 1.5)
    -- 0.5 h to fill the box, then 1 h of overflow into chests
    expectNear(r.stocks.food, 100, "box full")
    expectNear(r.stocks.Berries, 20, "rest stays in chests")
end)

test("fedHours counts only the time Pals were fed", function()
    local r = catchup.simulate({ stocks = { food = 30 }, processes = {
        { id = "eat", kind = "upkeep", inputs = { food = 60 } },
        { id = "log", kind = "work", outputs = { wood = 120 } } } }, 2)
    expectNear(r.fedHours, 0.5, "fed for half an hour")
end)

test("day and night stretches chain with their own rates", function()
    local dayProcs = { { id = "log", kind = "work", outputs = { wood = 100 } } }
    local nightProcs = { { id = "log", kind = "work", outputs = { wood = 10 } } }
    local r = catchup.simulatePhased({ stocks = {} }, {
        { phase = "day", hours = 2, processes = dayProcs },
        { phase = "night", hours = 1, processes = nightProcs },
        { phase = "day", hours = 1, processes = dayProcs } })
    expectNear(r.stocks.wood, 310, "2h day + 1h night + 1h day")
    expect(r.segments[2].phase == "night", "segments tagged by phase")
end)

test("a finite crafting queue stops when it runs out", function()
    local r = catchup.simulate({ stocks = { ore = 1000, ["__queue:ingot"] = 5 }, processes = {
        { id = "craft:ingot", kind = "work", inputs = { ore = 20, ["__queue:ingot"] = 10 }, outputs = { ingot = 10 } } } }, 2)
    expectNear(r.stocks.ingot, 5, "only the 5 queued")
    expectNear(r.stocks.ore, 990, "ore only for those 5")
end)

test("distribute splits whole units by share and keeps the total", function()
    local d = catchup.distribute(-10, { Berries = 0.7, Wheat = 0.3 })
    expect(d.Berries + d.Wheat == -10, "total kept")
    expect(d.Berries == -7 and d.Wheat == -3, "split")
end)

test("finished timers report their leftover time", function()
    local t = catchup.advanceTimers({ { id = "egg", remaining = 600, owner = "inc" } }, 1000)
    expect(t[1].done and t[1].leftover == 400 and t[1].owner == "inc", "leftover")
end)

test("learned rates plug straight into the simulation", function()
    local bs = {}
    for _ = 1, 3 do rates.observe(bs, "log", "work", {}, { wood = 60 }, 1800, 0.3) end
    local r = catchup.simulate({ stocks = {}, processes = rates.processList(bs, 3) }, 1)
    expectNear(r.stocks.wood, 120, "wood")
end)

test("state survives a save/load round trip", function()
    local path = os.tmpname()
    local state = { lastSeen = 1759300000, bases = { ["A-1"] = { carry = { wood = 0.25 } } } }
    store.save(path, state)
    local back = store.load(path)
    expect(back.lastSeen == 1759300000, "lastSeen")
    expectNear(back.bases["A-1"].carry.wood, 0.25, "carry")
    store.save(path, { lastSeen = 2 })
    expect(store.load(path).lastSeen == 2, "overwrite works")
    expect(store.load(path .. ".missing") == nil, "missing file gives nil")
    os.remove(path); os.remove(path .. ".bak")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if arg then os.exit(failed == 0 and 0 or 1) end -- standalone lua
return failed                                    -- embedded (run_tests.py)

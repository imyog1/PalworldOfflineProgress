-- Tests for rates (tags), timeline (day/night) and observe (measuring).
-- Run with:  python tests/run_tests.py
package.path = "Scripts/?.lua;" .. package.path

local rates = require("rates")
local timeline = require("timeline")
local observe = require("observe")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("ok    " .. name)
    else failed = failed + 1; print("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function expect(cond, msg) if not cond then error(msg, 2) end end
local function near(a, b) return math.abs((a or 0) - (b or 0)) < 1e-6 end
local function expectNear(a, b, what)
    if not near(a, b) then error(("%s: expected %s, got %s"):format(what, tostring(b), tostring(a)), 2) end
end

-- rates ------------------------------------------------------------------------------------

test("rates prefer phase-and-far, then phase, then far, then all", function()
    local bs = {}
    for _ = 1, 3 do rates.observe(bs, "make:Wood", "work", {}, { Wood = 100 }, 3600, 0.5, rates.tagsFor("day", true)) end
    for _ = 1, 3 do rates.observe(bs, "make:Wood", "work", {}, { Wood = 10 }, 3600, 0.5, rates.tagsFor("night", false)) end
    expectNear(rates.processList(bs, 3, "day")[1].outputs.Wood, 100, "day:far")
    expect(rates.processList(bs, 3, "day")[1].tag == "day:far", "tag")
    expectNear(rates.processList(bs, 3, "night")[1].outputs.Wood, 10, "night (no far data)")
    expect(rates.processList(bs, 3, nil)[1].tag == "far", "no phase: far")
end)

test("a big change in two windows in a row resets the average", function()
    local bs = {}
    for _ = 1, 5 do rates.observe(bs, "make:Ore", "work", {}, { Ore = 100 }, 3600, 0.2) end
    rates.observe(bs, "make:Ore", "work", {}, { Ore = 0 }, 3600, 0.2)
    local s = bs.processes["make:Ore"].tags.all
    expectNear(s.outputs.Ore, 80, "one odd window only nudges it")
    rates.observe(bs, "make:Ore", "work", {}, { Ore = 0 }, 3600, 0.2)
    expectNear(s.outputs.Ore, 0, "second odd window in a row: line was dismantled")
end)

test("old-format rates are kept as the 'all' condition", function()
    local bs = { processes = { ["make:Wood"] = { id = "make:Wood", kind = "work", inputs = {}, outputs = { Wood = 50 }, samples = 9 } } }
    local list = rates.processList(bs, 6, "day")
    expect(#list == 1 and list[1].tag == "all", "migrated")
    expectNear(list[1].outputs.Wood, 50, "rate kept")
end)

test("scalars and mixes", function()
    local s = {}
    rates.scalar(s, "k", 10, 0.5); rates.scalar(s, "k", 20, 0.5)
    expectNear(rates.get(s, "k", 2), 15, "average")
    expect(rates.get(s, "k", 3) == nil, "not enough samples")
    local m = {}
    rates.mix(m, { Berries = 30, Wheat = 10 }, 1)
    local sh = rates.shares(m, { Berries = true, Wheat = true })
    expectNear(sh.Berries, 0.75, "share")
    expectNear(rates.shares(m, { Wheat = true }).Wheat, 1, "restricted to what's present")
end)

-- timeline ---------------------------------------------------------------------------------

local clock = { hour = 16, dayStart = 6, nightStart = 18, rate = { day = 24, night = 48 } }

test("timeline splits a gap into day and night", function()
    -- 16:00 day: 2 game h to night = 5 real min; night 12 game h = 15 real min; then day.
    local r = timeline.split(0.5, clock)
    expect(r.segments[1].phase == "day" and near(r.segments[1].hours, 2 / 24), "day first")
    expect(r.segments[2].phase == "night" and near(r.segments[2].hours, 12 / 48), "then night")
    expect(r.segments[3].phase == "day", "then day again")
    expect(r.dawns == 1, "one dawn crossed")
    expectNear(r.endHour, 6 + (0.5 - 2 / 24 - 12 / 48) * 24, "end hour")
end)

test("timeline needs a measured clock", function()
    expect(timeline.split(1, { hour = 3, rate = { day = 1 } }) == nil, "unmeasured clock")
end)

test("clock plan never goes backwards", function()
    local short = timeline.split(1 / 24, clock) -- +1 game hour, same day
    local p = timeline.advancePlan(clock, short)
    expect(p.nextDays == 0 and p.setHour == 17, "same day, 17:00")
    local long = timeline.split(0.5, clock)
    p = timeline.advancePlan(clock, long)
    expect(p.nextDays == 1 and p.setHour == 10, "next morning then 10:00, got " .. tostring(p.setHour))
    local evening = timeline.split(0.2, clock) -- ends 23:36 the same day
    p = timeline.advancePlan(clock, evening)
    expect(p.nextDays == 0 and p.setHour == 23, "same evening, 23:00")
    local overnight = timeline.split(0.25, clock) -- ends 02:00, after midnight but before dawn
    p = timeline.advancePlan(clock, overnight)
    expect(p.nextDays == 0 and p.setHour == nil and not p.exact, "can't reach before-dawn of the next day")
end)

-- observe ----------------------------------------------------------------------------------

local function snap(items, caps, extra)
    local b = { items = items, caps = caps or {}, foodItems = {}, workers = {}, spoil = {} }
    for k, v in pairs(extra or {}) do b[k] = v end
    return { bases = { B = b } }
end

test("observe turns changes into make/use/eat measurements", function()
    local res = observe.compare(snap({ Wood = 10, Ore = 50, food = 20 }), snap({ Wood = 30, Ore = 40, food = 15 }),
        600, { B = { clean = true, far = true } }, "day", nil)
    local ids = {}
    for _, o in ipairs(res.obs) do ids[o.processId] = o end
    expect(ids["make:Wood"].outputs.Wood == 20, "wood made")
    expect(ids["use:Ore"].inputs.Ore == 10, "ore used")
    expect(ids.eat.kind == "upkeep" and ids.eat.inputs.food == 5, "food eaten")
    expect(#ids["make:Wood"].tags == 4, "all/far/day/day:far")
end)

test("observe reports zero output unless the process was blocked", function()
    local known = { B = { ["make:Wood"] = { kind = "work" }, ["make:Stone"] = { kind = "work" }, ["use:Ore"] = { kind = "work" } } }
    local res = observe.compare(snap({ Wood = 10, Stone = 99, Ore = 0 }, { Stone = 99 }),
        snap({ Wood = 10, Stone = 99, Ore = 0 }, { Stone = 99 }), 600, { B = { clean = true } }, nil, known)
    local ids = {}
    for _, o in ipairs(res.obs) do ids[o.processId] = o end
    expect(ids["make:Wood"] and ids["make:Wood"].outputs.Wood == 0, "wood really stopped")
    expect(not ids["make:Stone"], "stone was full: blocked, not zero")
    expect(not ids["use:Ore"], "no ore to use: blocked, not zero")
end)

test("observe skips bases a player was in", function()
    local res = observe.compare(snap({ Wood = 10 }), snap({ Wood = 30 }), 600, { B = { clean = false } }, nil, nil)
    expect(#res.obs == 0, "skipped")
end)

test("observe measures hunger, sanity, spoilage and food mix", function()
    local p = snap({ food = 10 }, {}, { workers = { a = { stomach = 80, sanity = 50 } },
        spoil = { s1 = { item = "Berries", count = 5, value = 0.1, progress = 0.1, mult = 0.5, factor = 2 } },
        foodItems = { Berries = 6, Wheat = 4 } })
    local c = snap({ food = 8 }, {}, { workers = { a = { stomach = 70, sanity = 48 } },
        spoil = { s1 = { item = "Berries", count = 5, value = 0.2, progress = 0.2, mult = 0.5, factor = 2 } },
        foodItems = { Berries = 4, Wheat = 4 } })
    local res = observe.compare(p, c, 1800, { B = { clean = true } }, nil, nil)
    expectNear(res.needs.B.decline, 20, "stomach -10 in 0.5 h")
    expectNear(res.needs.B.drift, -4, "sanity -2 in 0.5 h")
    expectNear(res.spoil[1].k, 0.1 / 0.5 / (2 * 0.5), "spoil speed per unit factor and multiplier")
    expectNear(res.spoil[1].threshold, 1, "spoils at 1.0")
    expect(res.mix.B.eaten.Berries == 2 and res.mix.B.eaten.Wheat == nil, "what was eaten")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if arg then os.exit(failed == 0 and 0 or 1) end -- standalone lua
return failed                                    -- embedded (run_tests.py)

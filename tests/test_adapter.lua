-- Exercises adapter.lua against fake objects shaped like UE4SS's view of Palworld 1.0.5.
-- Run with:  python tests/run_tests.py
package.path = "Scripts/?.lua;tests/?.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("ok    " .. name)
    else failed = failed + 1; print("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function expect(cond, msg) if not cond then error(msg, 2) end end
local function expectEq(actual, expected, what)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

local F = require("fake_ue4ss")
local key = F.key

-- Scene: base 1 with two chests (one shared with base 2), a feed box, an egg in storage;
-- base 2; an incubator; a smelter; a breeding farm; Pals.
local woodA, woodB, stone = F.slot("Wood", 990, 999), F.slot("Wood", 9990), F.slot("Stone", 5)
local emptyA, emptyB = F.slot(nil, 0), F.slot(nil, 0)
local berries = F.slot("Berries", 10, 50, { spoil = 0.2 })
local wheat = F.slot("Wheat", 3, 50)
local egg = F.slot("PalEgg_Fire_01", 1, 1, { dynamic = F.obj({}) })
local sharedWood = F.slot("Wood", 100)
local chestA = F.container(11, { woodA, emptyA, egg })
local chestB = F.container(12, { woodB, stone, emptyB }, { mult = 0.5 })
local feedBox = F.container(13, { berries, wheat })
local sharedC = F.container(14, { sharedWood })
local incubator = F.work(1, 77, 100, 40, 2, 500)
local smelter = F.station(1, 600, "Ingot", 10)
local farm = F.obj({ BreedProgressTime = 30, BreedRequiredRealTime = 300, ExistPalEggMaxNum = 10,
                     SpawnedEggInstanceIds = F.tarray({ 1, 2 }) })
farm.CanProceedBreeding = function() return true end
farm.GetBaseCampIdBelongTo = function() return F.guid(1) end
farm.GetInstanceId = function() return F.guid(700) end
farm.OnRep_UpdateBreedProgress = function() end

local chestModelA = F.storage(1, chestA)
F.world = {
    PalBaseCampModel = { F.base(1, { at = { X = 0, Y = 0, Z = 0 } }), F.base(2, { at = { X = 50000, Y = 0, Z = 0 } }) },
    -- The same chest is returned under two class names, as FindAllOf might for a subclass.
    PalMapObjectItemChestModel = { chestModelA, F.storage(1, sharedC), F.storage(2, sharedC) },
    PalMapObjectItemChest_AffectCorruption = { F.storage(1, chestB), chestModelA },
    PalMapObjectPalFoodBoxModel = { F.storage(1, feedBox) },
    PalWorkProgress = { incubator, F.work(2, 78, 100, 0, 5), F.work(1, 79, 100, 100, 5) },
    PalMapObjectConvertItemModel = { smelter },
    PalMapObjectBreedFarmModel = { farm },
    PalIndividualCharacterParameter = { F.pal(1, 901, 80, 60), F.pal(1, 902, 50, 90), F.pal(nil, 903, 10, 10) },
    PalItemIDManager = { F.itemManager() },
    PalPlayerCharacter = { F.obj({ K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end }) },
    PalBaseCampManager = { F.obj({ UpdateIntervalSquaredDistanceFromPlayer = 10000 * 10000 }) },
    PalTimeManager = { F.obj({
        GetCurrentDayTimeType = function() return 2 end,
        GetCurrentPalWorldHoursFloat = function() return 21.5 end,
        GetCurrentPalWorldTime_TotalDay = function() return 42 end,
        SetGameTime_FixDay = function(_, h) F.calls.fixDay = h end,
    }) },
    PalPlayerController = { F.obj({ CheatManager = F.obj({ SetGameTime_NextDay = function()
        F.calls.nextDay = (F.calls.nextDay or 0) + 1 end }) }) },
    PalSaveGameManager = { F.obj({ LoadedWorldSaveData = F.obj({ Timestamp = F.dt(os.time() - 3600) }) }) },
}
F.items = { Berries = { factor = 2 }, Wheat = { factor = 1 }, Wood = {}, Stone = {}, PalEgg_Fire_01 = { unique = true, max = 1 } }
F.recipes = { Ingot = { product = "CopperIngot", count = 1, materials = { { "CopperOre", 2 } } } }

local cfg = require("config")
local adapter = require("adapter")
adapter.setGameState(F.obj({ GetWorldSaveDirectoryName = function() return F.fstr("8122951F") end }))

local function byId(list, id) for _, b in ipairs(list) do if b.id == id then return b end end end

test("world id and save age are read", function()
    expectEq(adapter.worldId(), "8122951F", "world id")
    local ages = adapter.saveAge()
    expectEq(ages.utc, 3600, "saved an hour ago (UTC reading)")
end)

test("a TrivialObject string is never used as a world id", function()
    adapter.setGameState(F.obj({ WorldSaveDirectoryName = F.fstr("TrivialObject: 0000018EF801C548"),
                                 GetWorldSaveDirectoryName = function() return F.fstr("TrivialObject: 1") end,
                                 WorldName = F.fstr("My World") }))
    local id, diag = adapter.worldId()
    expectEq(id, "bases:" .. key(1), "falls back to an id built from the world's bases")
    expect(diag:find("GameState.WorldSaveDirectoryName = \"TrivialObject", 1, true), "diagnostic says what came back: " .. diag)
    F.world.PalGameInstance = { F.obj({ SelectedWorldSaveDirectoryName = F.fstr("FROM_GAME_INSTANCE") }) }
    adapter.setGameState(F.obj({ WorldSaveDirectoryName = F.fstr("TrivialObject: 1") })) -- new load clears lookups
    expectEq((adapter.worldId()), "FROM_GAME_INSTANCE", "game instance is tried first")
    F.world.PalGameInstance = nil
    adapter.setGameState(F.obj({ GetWorldSaveDirectoryName = function() return F.fstr("8122951F") end }))
end)

test("real-progress timers are found and moved earlier", function()
    local exp = F.obj({ State = 2, MissionStartDateTime = F.dt(1000), MissionCompleteDateTime = F.dt(5000) })
    exp.OnRep_MissionCompleteDateTime = function() F.calls.expRep = true end
    local done = F.obj({ State = 3, MissionStartDateTime = F.dt(1000), MissionCompleteDateTime = F.dt(2000) })
    F.world.PalMapObjectCharacterTeamMissionModel = { exp, done }
    local timers = adapter.realProgressTimers()
    expectEq(#timers, 1, "only the expedition in progress")
    expect(adapter.shiftRealProgress(timers[1], 600), "reads back as moved")
    expectEq(exp.MissionCompleteDateTime._t, 4400, "finish 10 min earlier")
    expectEq(exp.MissionStartDateTime._t, 400, "start too")
    expect(F.calls.expRep, "replication callback called")
end)

test("version is read from ProjectVersion", function()
    local v, raw = adapter.getGameVersion()
    expectEq(v, "1.0.5", "version")
    expectEq(raw, "1.0.5.102999", "raw")
end)

test("clock reads hour, day and phase", function()
    local c = adapter.clock()
    expectEq(c.hour, 21.5, "hour"); expectEq(c.day, 42, "day"); expectEq(c.phase, "night", "phase")
end)

test("advanceClock jumps days with the cheat manager, then sets the hour", function()
    local ok = adapter.advanceClock({ nextDays = 2, setHour = 9 })
    expect(ok, "done")
    expectEq(F.calls.nextDay, 2, "next day calls"); expectEq(F.calls.fixDay, 9, "hour")
end)

test("objects returned under two class names are counted once", function()
    local b1 = byId(adapter.listBases(), key(1))
    expectEq(b1.stocks.Wood, 10980, "wood counted once per chest")
end)

test("storage used by two bases becomes its own shared pool", function()
    local list = adapter.listBases()
    local shared = byId(list, "shared:" .. key(14))
    expect(shared and shared.shared, "shared pool exists")
    expectEq(shared.stocks.Wood, 100, "shared wood")
    expectEq(byId(list, key(2)).stocks.Wood, nil, "base 2 no longer counts it")
end)

test("eggs and other unique items are never counted", function()
    local b1 = byId(adapter.listBases(), key(1))
    expectEq(b1.stocks.PalEgg_Fire_01, nil, "egg ignored")
    expectEq(b1.defaultCap, 0, "egg slot isn't counted as empty either")
end)

test("feed boxes fold into food, with per-item contents kept", function()
    local b1 = byId(adapter.listBases(), key(1))
    expectEq(b1.stocks.food, 13, "food"); expectEq(b1.foodItems.Berries, 10, "berries")
    expectEq(b1.caps.food, 13 + 40 + 47, "food cap")
end)

test("presence reports inside and distance per base, plus the full-speed distance", function()
    local p, threshold = adapter.presence()
    expectEq(threshold, 10000, "threshold")
    expectEq(p[key(1)].distance, 100, "near base 1"); expectEq(p[key(2)].distance, 49900, "far from base 2")
    expect(not p[key(1)].inside, "not inside")
end)

test("snapshot has items, workers and perishable stacks", function()
    local s = adapter.snapshot().bases[key(1)]
    expectEq(s.items.Wood, 10980, "wood")
    expectEq(s.workers[key(901)].stomach, 80, "pal stomach")
    expectEq(s.workers[key(903)], nil, "pal without a base ignored")
    local spoilCount, berriesEntry = 0, nil
    for _, e in pairs(s.spoil) do spoilCount = spoilCount + 1; if e.item == "Berries" then berriesEntry = e end end
    expectEq(spoilCount, 2, "berries and wheat are perishable")
    expectEq(berriesEntry.factor, 2, "factor"); expectEq(berriesEntry.value, 0.2, "value")
end)

test("timers come from self-progressing work at that base, with their machine", function()
    local t = adapter.getTimers(key(1))
    expectEq(#t, 1, "one timer"); expectEq(t[1].remaining, 30, "60 work left at 2/s")
    expectEq(t[1].owner, key(500), "owner")
end)

test("applyTimers leaves finished work for the game to complete", function()
    adapter.applyTimers(key(1), { { id = key(77), remaining = 0, done = true } })
    expectEq(incubator.CurrentWorkAmount, 99, "a hair short of 100")
    expect(not incubator:IsCompleted(), "not completed by the mod")
end)

test("leftover time goes to the next job at the same machine", function()
    local nextJob = F.work(1, 80, 100, 0, 2, 500)
    table.insert(F.world.PalWorkProgress, nextJob)
    local used = adapter.advanceNextAtOwner(key(500), 20, { [key(77)] = true })
    expectEq(used, 20, "seconds used"); expectEq(nextJob.CurrentWorkAmount, 40, "20 s at 2/s")
end)

test("stations come with their recipe", function()
    local st = adapter.stations()[key(1)][1]
    expectEq(st.product, "CopperIngot", "product"); expectEq(st.materials.CopperOre, 2, "ore per ingot")
    expectEq(st.remain, 10, "queue"); expect(st.toStorage, "goes to storage")
end)

test("applyStation shortens the queue, leaving the last craft for the game", function()
    local st = adapter.stations()[key(1)][1]
    adapter.applyStation(st, 4)
    expectEq(smelter.RemainProductNum, 6, "6 left")
    st = adapter.stations()[key(1)][1]
    adapter.applyStation(st, 50)
    expectEq(smelter.RemainProductNum, 1, "last craft left to the game")
end)

test("breeding farms report progress in seconds", function()
    local f = adapter.breedFarms()[key(1)][1]
    expectEq(f.required, 300, "required"); expectEq(f.eggs, 2, "eggs"); expect(f.canProceed, "can breed")
end)

test("topUpOnly fills existing stacks and returns what didn't fit", function()
    cfg.itemWriteMode = "topUpOnly"
    adapter.listBases()
    local left = adapter.applyItemDeltas(key(1), { Wood = 50, Iron = 5 }, {})
    expectEq(woodA.StackCount, 999, "first stack full"); expectEq(woodB.StackCount, 9999, "second stack full")
    expectEq(left.Wood, 32, "32 wood left over"); expectEq(left.Iron, 5, "no iron stack")
    expect((F.calls.OnUpdateSlotContent or 0) >= 2, "container told about each slot")
    expect((F.calls["module:PalBaseCampModuleItemStorage"] or 0) >= 1, "base storage module told")
    expect((F.calls["module:PalBaseCampModuleItemStackInfo"] or 0) >= 1, "base item totals told")
end)

test("feed deltas name specific foods and never empty a stack in topUpOnly", function()
    adapter.listBases()
    local left = adapter.applyItemDeltas(key(1), {}, { Berries = -12, Wheat = 2 })
    expectEq(berries.StackCount, 1, "berries left at 1"); expectEq(left["food:Berries"], -3, "3 couldn't be taken")
    expectEq(wheat.StackCount, 5, "wheat added")
end)

test("full mode starts new stacks but never creates unique items", function()
    cfg.itemWriteMode = "full"
    adapter.listBases()
    local left = adapter.applyItemDeltas(key(1), { Iron = 5, PalEgg_Fire_01 = 1 }, {})
    expectEq(emptyA.ItemId.StaticId:ToString(), "Iron", "iron placed"); expectEq(emptyA.StackCount, 5, "count")
    expectEq(left.PalEgg_Fire_01, 1, "egg not created")
    cfg.itemWriteMode = "topUpOnly"
end)

test("spoilage and Pal needs can be written", function()
    local s = adapter.spoilSlots()
    expect(#s >= 2, "perishables listed")
    adapter.setSpoil(berries, 0.7)
    expectEq(berries.CorruptionProgressValue, 0.7, "spoil written")
    local w = adapter.workers(key(1))[key(901)]
    adapter.setPalNeeds(w.ref, 40, 55)
    expectEq(w.ref.SaveParameter.FullStomach, 40, "stomach"); expectEq(w.ref.SaveParameter.SanityValue, 55, "sanity")
end)

test("placeholder base names become Base N; renamed bases keep their name", function()
    expectEq(adapter.friendlyBaseName("新規生成拠点テンプレート名0(仮)"), "Base 1", "placeholder 0")
    expectEq(adapter.friendlyBaseName("新規生成拠点テンプレート名6(仮)"), "Base 7", "placeholder 6")
    expectEq(adapter.friendlyBaseName("Ore Mine"), "Ore Mine", "custom name kept")
    expectEq(adapter.friendlyBaseName(nil), nil, "no name")
end)

test("repeated lookups don't search all objects again", function()
    adapter.clock(); adapter.listBases(); adapter.presence()
    local before = {}
    for k, v in pairs(F.searches) do before[k] = v end
    for _ = 1, 10 do adapter.clock(); adapter.presence() end
    for _ = 1, 3 do adapter.listBases() end -- item data lookups for every stack
    expectEq(F.searches.PalTimeManager, before.PalTimeManager, "time manager remembered")
    expectEq(F.searches.PalItemIDManager, before.PalItemIDManager, "item manager remembered")
    expectEq(F.searches.PalBaseCampManager, before.PalBaseCampManager, "base manager remembered")
    expectEq(F.searches.PalBaseCampModel, before.PalBaseCampModel, "base list reused within a minute")
end)

test("players come from the game state's player list, without a search", function()
    local ps = F.obj({ PlayerUId = F.guid(7), GetPawn = function()
        return F.obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end }) end })
    adapter.setGameState(F.obj({ GetWorldSaveDirectoryName = function() return F.fstr("8122951F") end,
                                 PlayerArray = F.tarray({ ps }) }))
    local before = F.searches.PalPlayerState or 0
    local players = adapter.players()
    expectEq(#players, 1, "one player"); expectEq(players[1].key, key(7), "their id")
    local p = adapter.presence()
    expectEq(p[key(1)].distance, 0, "distance from their character")
    expectEq(F.searches.PalPlayerState or 0, before, "no search for player states")
end)

test("empty incubators are not counted as timers (Nexus report)", function()
    local function owner(name, workable)
        return F.obj({ GetClass = function() return { GetFName = function() return FName(name) end } end,
                       IsWorkable = function() return workable end })
    end
    local egg = F.work(9, 901, 100, 10, 2, 900)
    egg.CachedOwnerMapObjectConcreteModel = owner("PalMapObjectHatchingEggModel", true)
    local emptyByState = F.work(9, 902, 100, 10, 2, 901)
    emptyByState.CurrentState = 2 -- NotWorkable: no egg
    local emptyByOwner = F.work(9, 903, 100, 10, 2, 902)
    emptyByOwner.CachedOwnerMapObjectConcreteModel = owner("PalMapObjectHatchingEggModel", false)
    local machine = F.work(9, 904, 100, 10, 2, 903)
    local saved = F.world.PalWorkProgress
    F.world.PalWorkProgress = { egg, emptyByState, emptyByOwner, machine }
    adapter.setGameState(F.obj({ GetWorldSaveDirectoryName = function() return F.fstr("8122951F") end }))
    local t = adapter.getTimers(key(9))
    F.world.PalWorkProgress = saved
    expectEq(#t, 2, "only the incubator with an egg and the running machine")
    local kinds = {}
    for _, x in ipairs(t) do kinds[x.id] = x.kind end
    expectEq(kinds[key(901)], "incubator", "incubator with an egg")
    expectEq(kinds[key(904)], "machine", "other self-running work")
end)

test("expedition dates are written as text when a direct write doesn't stick (Nexus report)", function()
    local start, finish = os.time() - 3000, os.time() + 3000
    local m = F.dateModel({ State = 2, MissionStartDateTime = F.dt(start), MissionCompleteDateTime = F.dt(finish),
                            OnRep_MissionCompleteDateTime = function() end,
                            GetBaseCampIdBelongTo = function() return F.guid(1) end, GetAddress = function() return 4242 end })
    F.world.PalMapObjectCharacterTeamMissionModel = { m }
    local timers = adapter.realProgressTimers()
    local ok, method, err = adapter.shiftRealProgress(timers[1], 1800)
    expect(ok, "moved: " .. tostring(err))
    expectEq(method, "text", "fell back to importing the date as text")
    expectEq(m.MissionCompleteDateTime._t, finish - 1800, "finish 30 min earlier")
    expectEq(m.MissionStartDateTime._t, start - 1800, "start too")
    expectEq(m.imports(), 2, "both dates imported")
end)

test("describe summarises the scan and warns about unsaved containers", function()
    local s = adapter.describe()
    expect(s:find("found 2 base%(s%)") and s:find("1 shared storage") and s:find("1 crafting station%(s%) %(1 with a queue%)"),
        "summary: " .. s)
    expect(not s:find("WARNING"), "no warning")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if arg then os.exit(failed == 0 and 0 or 1) end -- standalone lua
return failed                                    -- embedded (run_tests.py)

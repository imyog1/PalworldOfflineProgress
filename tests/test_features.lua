-- End-to-end run of every catch-up feature (crafting, spoilage, world time, timers with
-- follow-up rounds, breeding, Pal needs, crops) first in dry run, then live.
-- Run with:  python tests/run_tests.py
package.path = "Scripts/?.lua;tests/?.lua;" .. package.path

local say = print
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; say("ok    " .. name)
    else failed = failed + 1; say("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function expect(cond, msg) if not cond then error(msg, 2) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

local F = require("fake_ue4ss")
local store = require("store")
local cfg = require("config")
cfg.dryRun = false

local realTime = os.time
local now = 1790900000
os.time = function(t) if t then return realTime(t) end return now end
local logs = {}
print = function(s) logs[#logs + 1] = s end
local function logged(pattern)
    for _, l in ipairs(logs) do if l:find(pattern) then return l end end
    return nil
end
local function dump() return table.concat(logs, "") end



local hook
function RegisterInitGameStatePostHook(f) hook = f end
function ExecuteWithDelay(_, f) f() end
function ExecuteInGameThread(f) f() end
function LoopAsync() end
function RegisterHook() end

-- Scene ------------------------------------------------------------------------------------
local ore = F.slot("CopperOre", 100)
local ingot = F.slot("CopperIngot", 5)
local chestBerries = F.slot("Berries", 40, 9999, { spoil = 0.3 })
local feedBerries = F.slot("Berries", 40, 50, { spoil = 0.1 })
local smelter = F.station(1, 600, "Ingot", 10)
local smeltWork = F.work(1, 601, 50, 10, 0, 600)
local incubator = F.work(1, 77, 100, 50, 1, 500)
local nextJob = F.work(1, 78, 100, 0, 1, 500)
local farm = F.obj({ BreedProgressTime = 0, BreedRequiredRealTime = 600, ExistPalEggMaxNum = 10,
                     SpawnedEggInstanceIds = F.tarray({}) })
farm.CanProceedBreeding = function() return true end
farm.GetBaseCampIdBelongTo = function() return F.guid(1) end
farm.GetInstanceId = function() return F.guid(700) end
local breedSets = 0
farm.OnRep_UpdateBreedProgress = function() breedSets = breedSets + 1 end
local crop = F.obj({ CurrentCropDataId = FName("Berries"), CurrentState = 3, CropProgressRateValue = 0.2 })
crop.GetBaseCampIdBelongTo = function() return F.guid(1) end
crop.GetInstanceId = function() return F.guid(800) end
crop.OnRep_CropProgressRateValue = function() end
local palA, palB = F.pal(1, 901, 80, 50), F.pal(1, 902, 60, 50)
local cheat = { nextDay = 0, fixDay = nil }

F.world = {
    PalBaseCampModel = { F.base(1) },
    PalMapObjectItemChestModel = { F.storage(1, F.container(11, { ore, ingot, chestBerries })) },
    PalMapObjectPalFoodBoxModel = { F.storage(1, F.container(12, { feedBerries })) },
    PalWorkProgress = { incubator, nextJob, smeltWork },
    PalMapObjectConvertItemModel = { smelter },
    PalMapObjectBreedFarmModel = { farm },
    PalMapObjectFarmBlockV2Model = { crop },
    PalIndividualCharacterParameter = { palA, palB },
    PalItemIDManager = { F.itemManager() },
    PalPlayerCharacter = { F.obj({ K2_GetActorLocation = function() return { X = 99999, Y = 0, Z = 0 } end }) },
    PalBaseCampManager = { F.obj({ UpdateIntervalSquaredDistanceFromPlayer = 1e8 }) },
    PalTimeManager = { F.obj({
        GetCurrentDayTimeType = function() return 1 end,
        GetCurrentPalWorldHoursFloat = function() return 16 end,
        GetCurrentPalWorldTime_TotalDay = function() return 10 end,
        SetGameTime_FixDay = function(_, h) cheat.fixDay = h end,
    }) },
    PalPlayerController = { F.obj({ CheatManager = F.obj({ SetGameTime_NextDay = function() cheat.nextDay = cheat.nextDay + 1 end }) }) },
    PalSaveGameManager = { F.obj({ LoadedWorldSaveData = F.obj({ Timestamp = F.dt(0) }) }) },
}
local function setSave(unix)
    F.world.PalSaveGameManager[1].LoadedWorldSaveData.Timestamp = F.dt(unix)
end
F.items = { CopperOre = {}, CopperIngot = {}, Berries = { factor = 2 } }
F.recipes = { Ingot = { product = "CopperIngot", count = 1, materials = { { "CopperOre", 2 } } } }

local function proc(id, kind, inputs, outputs)
    return { id = id, kind = kind, tags = { all = { inputs = inputs, outputs = outputs, samples = 9, pending = {} } } }
end
OFFLINE_PROGRESS_STATE_PATH = os.tmpname()
store.save(OFFLINE_PROGRESS_STATE_PATH, {
    spoil = { k = { value = 0.1, samples = 3 }, threshold = { value = 1, samples = 3 } },
    worlds = { W = {
        lastSeen = now - 3590,
        time = { day = { value = 24, samples = 5 }, night = { value = 48, samples = 5 },
                 dayStart = { value = 6, samples = 2 }, nightStart = { value = 18, samples = 2 } },
        crops = { Berries = { value = 0.5, samples = 3 } },
        bases = { [F.key(1)] = {
            processes = {
                ["make:CopperIngot"] = proc("make:CopperIngot", "work", {}, { CopperIngot = 20 }),
                ["use:CopperOre"] = proc("use:CopperOre", "work", { CopperOre = 40 }, {}),
                ["eat"] = proc("eat", "upkeep", { food = 10 }, {}),
            },
            needs = { decline = { value = 10, samples = 5 }, drift = { value = -2, samples = 5 } },
            foodEaten = { Berries = 1 },
        } },
    } },
})

local function gameState()
    return { get = function()
        return F.obj({
            GetFullName = function() return "GS /Game/Pal/Maps/MainWorld_5/PL_MainWorld5:GS" end,
            GetWorldSaveDirectoryName = function() return F.fstr("W") end,
        })
    end }
end
local title = { get = function() return F.obj({ GetFullName = function() return "GS /Game/Pal/Maps/Title" end }) end }

setSave(now - 3600)
dofile("Scripts/main.lua")

test("first load: default settings (items, timers, breeding live; the rest dry run)", function()
    hook(gameState())
    expect(logged("Day/night: day 0%.08h, night 0%.25h, day 0%.50h, night 0%.17h"), "day/night split\n" .. dump())
    expect(logged("Spoilage %(dry run%): 2 perishable stack%(s%) aged, 0 would spoil"), "spoilage dry")
    expect(logged("World time %(dry run%): day 10 16%.00h %-> %+34%.0 in%-game hours %(1 dawn%(s%)%), ends 02%.00h, reachable approximately"),
        "world time dry\n" .. dump())
    expect(logged("10 CopperIngot craft%(s%) finished from the queue %(dry run%)"), "crafting preview")
    expect(ingot.StackCount == 5 and ore.StackCount == 100, "no crafting items while crafting is dry run, and no ore lost")
    expect(logged("breeding farm would lay 6 egg%(s%)\n"), "breeding live by default\n" .. dump())
    expect(breedSets == 7 and farm.BreedProgressTime == 0, "6 eggs in follow-up rounds, then the leftover progress")
    expect(logged("2 Pal%(s%): hungry 0%.00h %(stomach %-0%), sanity %-2%.0 %(dry run%)"), "pal needs dry")
    expect(logged("1 crop plot%(s%) grown %(dry run%)"), "crops dry")
    expect(feedBerries.StackCount == 30, "food eaten: 10/h x 1h = 10")
    expect(near(incubator.CurrentWorkAmount, 99.5), "incubator left just short of done")
    expect(near(nextJob.CurrentWorkAmount, 99.5), "leftover time went to the next job at the same incubator")
end)

test("second load with every feature live", function()
    for k in pairs(cfg.live) do cfg.live[k] = true end
    hook(title)
    logs = {}
    now = now + 3600
    setSave(now - 3600)
    chestBerries.CorruptionProgressValue = 0.3
    hook(gameState())
    expect(logged("Save check: 1 of 1 changes"), "previous food change found in the save\n" .. dump())
    expect(ingot.StackCount == 15, "10 crafts added, got " .. ingot.StackCount)
    expect(ore.StackCount == 80, "20 ore used for them, got " .. ore.StackCount)
    expect(smelter.RemainProductNum == 1 and near(smeltWork.CurrentWorkAmount, 49.95), "queue's last craft left to the game")
    expect(near(chestBerries.CorruptionProgressValue, 0.3 + 0.1 * 2 * 1), "berries aged by one hour")
    expect(cheat.nextDay == 1 and cheat.fixDay == 23, "clock: next morning, then as late as that day allows (target was 02:00 the day after)")
    expect(breedSets == 14 and farm.BreedProgressTime == 0, "another 6 eggs on the second load")
    expect(near(palA.SaveParameter.SanityValue, 48), "sanity drifted")
    expect(near(crop.CropProgressRateValue, 0.7), "crop grew")
end)

os.remove(OFFLINE_PROGRESS_STATE_PATH)
os.remove(OFFLINE_PROGRESS_STATE_PATH .. ".bak")
print = say
os.time = realTime
say(("\n%d passed, %d failed"):format(passed, failed))
if arg then os.exit(failed == 0 and 0 or 1) end -- standalone lua
return failed                                    -- embedded (run_tests.py)

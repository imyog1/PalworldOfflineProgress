-- "While you were away" summaries: formatting, and delivery to the right player in multiplayer.
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

local summary = require("summary")

-- Formatting ---------------------------------------------------------------------------------

local function pretty(id) return (id:gsub("(%l)(%u)", "%1 %2")) end

test("summary lists each base with its biggest gains first", function()
    local pending = {}
    summary.add(pending, "P1", "B1", "Mining Base", { items = { Wood = 1750, Stone = 2403, CopperOre = 12 }, eaten = 30 })
    summary.add(pending, "P1", "B2", "Ranch", { items = { Milk = 95 }, hatched = 1, eggs = 2, expeditions = 1 })
    summary.addHours(pending, { P1 = true }, 2.25)
    local lines, top = summary.format(pending.P1, pretty, 6)
    expect(lines[1] == "While you were away (2h 15m), your bases kept working:", lines[1])
    expect(lines[2] == "Mining Base: +2,403 Stone, +1,750 Wood, +12 Copper Ore, Pals ate 30 food", lines[2])
    expect(lines[3] == "Ranch: +95 Milk, 1 incubator finished, 2 eggs laid, 1 expedition moved ahead", lines[3])
    expect(top[1].item == "Stone" and top[2].item == "Wood", "popups biggest first")
end)

test("long lists are cut off with '+N more', and gains add up across catch-ups", function()
    local pending = {}
    local many = {}
    for i = 1, 9 do many["Item" .. string.char(64 + i)] = i end
    summary.add(pending, "P", "B", "Base", { items = many })
    summary.add(pending, "P", "B", "Base", { items = { ItemA = 10 } })
    summary.addHours(pending, { P = true }, 0.5)
    summary.addHours(pending, { P = true }, 0.5)
    local lines = summary.format(pending.P, pretty, 3)
    expect(lines[1]:find("%(1h%)"), "hours summed: " .. lines[1])
    expect(lines[2] == "Base: +11 Item A, +9 Item I, +8 Item H, +6 more", lines[2])
end)

test("nothing gained means no summary", function()
    local pending = {}
    summary.add(pending, "P", "B", "Base", { items = {} })
    expect(summary.format(pending.P, pretty) == nil, "no lines")
end)

-- Multiplayer delivery ------------------------------------------------------------------------

local F = require("fake_ue4ss")
local store = require("store")
local cfg = require("config")
cfg.dryRun = false

local realTime = os.time
local now = 1790900000
os.time = function(t) if t then return realTime(t) end return now end
local logs = {}
print = function(s) logs[#logs + 1] = s end
local function dump() return table.concat(logs, "") end

local hook, loopFn
function RegisterInitGameStatePostHook(f) hook = f end
function ExecuteWithDelay(_, f) f() end
function ExecuteInGameThread(f) f() end
local loops = {}
function LoopAsync(ms, f) loops[ms] = f; loopFn = f end
function RegisterHook() end

local chats, popups = {}, {}
F.statics["/Script/Pal.Default__PalUtility"] = F.obj({ SendSystemToPlayerChat = function(_, _, text, uids)
    local to = F.key(uids[1].A)
    chats[to] = chats[to] or {}
    table.insert(chats[to], text)
end })
local names = { Stone = "Stone", Wood = "Wood", Milk = "Milk", CopperOre = "Copper Ore" }
F.statics["/Script/Pal.Default__PalUIUtility"] = F.obj({ GetItemName = function(_, _, id, out)
    out.outName = F.fstr(names[id:ToString()])
end })
local function playerState(n, spawned)
    return F.obj({ PlayerUId = F.guid(n), spawned = spawned,
        GetPawn = function(self) return self.spawned and F.obj({}) or nil end, AddItemGetLog_ToClient = function(_, item, num)
        local to = F.key(n)
        popups[to] = popups[to] or {}
        table.insert(popups[to], { item = item.StaticItemId:ToString(), n = item.Num })
    end })
end
local palboxes = { [F.key(5001)] = 1, [F.key(5002)] = 2 } -- palbox -> player who placed it

local hostStone, friendMilk = F.slot("Stone", 100), F.slot("Milk", 10)
local sharedChest = F.container(30, { F.slot("Wood", 50) })
local host, friend = playerState(1, true), playerState(2, false)
F.world = {
    PalBaseCampModel = { F.base(1, { name = "Mining Base" }), F.base(2, { name = "Ranch" }) },
    PalMapObjectItemChestModel = {
        F.storage(1, F.container(11, { hostStone })), F.storage(2, F.container(21, { friendMilk })),
        F.storage(1, sharedChest), F.storage(2, sharedChest) },
    PalItemIDManager = { F.itemManager() },
    PalMapObjectManager = { F.obj({ FindModel = function(_, g)
        local owner = palboxes[F.key(g.A)]
        return owner and F.obj({ BuildPlayerUId = F.guid(owner) }) or nil
    end }) },
    PalPlayerState = { host },
    PalTimeManager = { F.obj({ GetCurrentDayTimeType = function() return 1 end,
        GetCurrentPalWorldHoursFloat = function() return 10 end, GetCurrentPalWorldTime_TotalDay = function() return 1 end }) },
    PalSaveGameManager = { F.obj({ LoadedWorldSaveData = F.obj({ Timestamp = F.dt(0) }) }) },
}
local function saveAt(unix) F.world.PalSaveGameManager[1].LoadedWorldSaveData.Timestamp = F.dt(unix) end
F.items = { Stone = {}, Milk = {}, Wood = {} }

local function proc(item, rate)
    return { id = "make:" .. item, kind = "work", tags = { all = { inputs = {}, outputs = { [item] = rate }, samples = 9 } } }
end
OFFLINE_PROGRESS_STATE_PATH = os.tmpname()
store.save(OFFLINE_PROGRESS_STATE_PATH, { worlds = { W = { bases = {
    [F.key(1)] = { processes = { ["make:Stone"] = proc("Stone", 100) } },
    [F.key(2)] = { processes = { ["make:Milk"] = proc("Milk", 40) } },
    ["shared:" .. F.key(30)] = { processes = { ["make:Wood"] = proc("Wood", 20) } },
} } } })

local sent = {}
local gs = { get = function() return F.obj({
    GetFullName = function() return "GS /Game/Pal/Maps/MainWorld_5/PL_MainWorld5:GS" end,
    GetWorldSaveDirectoryName = function() return F.fstr("W") end,
    BroadcastChatMessage = function(_, m)
        sent[#sent + 1] = m
        local to = F.key(m.ReceiverPlayerUIds[1].A)
        chats[to] = chats[to] or {}
        table.insert(chats[to], m.Message)
    end }) end }
local title = { get = function() return F.obj({ GetFullName = function() return "GS /Game/Pal/Maps/Title" end }) end }

saveAt(now - 3600)
dofile("Scripts/main.lua")

test("host sees only their own base (plus shared storage) right after loading", function()
    hook(gs)
    local mine = chats[F.key(1)] or {}
    expect(#mine == 3, "header + Mining Base + Shared storage, got " .. #mine .. "\n" .. dump())
    expect(mine[1]:find("While you were away %(1h%)"), mine[1])
    local text = table.concat(mine, "\n")
    expect(text:find("Mining Base: %+75 Stone"), text)
    expect(text:find("Shared storage: %+15 Wood"), text)
    expect(not text:find("Ranch") and not text:find("Milk"), "nothing about the friend's base")
    expect(popups[F.key(1)][1].item == "Stone" and popups[F.key(1)][1].n == 75, "pickup popup for the biggest gain")
    expect(chats[F.key(2)] == nil, "friend isn't online, so nothing sent to them yet")
    expect(#sent == 0, "system chat by default, not a Global chat message")
end)

test("an offline player's summary waits, and adds up over catch-ups", function()
    hook(title)
    now = now + 1800
    saveAt(now - 1800)
    hook(gs) -- second catch-up, friend still offline
    local st = store.load(OFFLINE_PROGRESS_STATE_PATH)
    local entry = st.worlds.W.pending[F.key(2)]
    expect(entry and math.abs(entry.hours - 1.5) < 1e-6, "1h + 0.5h pending for the friend\n" .. dump())
    expect(entry.bases[F.key(2)].items.Milk == 30 + 15, "milk from both catch-ups")
end)

test("a player who joins gets their summary 5 seconds after their character appears", function()
    local join = loops[5000]
    expect(join, "join check loop running every 5 s")
    F.world.PalPlayerState = { host, friend }
    now = now + 5; join() -- joined, still loading (no character yet)
    now = now + 5; join()
    expect(chats[F.key(2)] == nil, "nothing while they're still loading")
    friend.spawned = true
    now = now + 5; join() -- character appeared
    expect(chats[F.key(2)] == nil, "waits a moment after the character appears")
    now = now + 5; join()
    local theirs = chats[F.key(2)] or {}
    local text = table.concat(theirs, "\n")
    expect(theirs[1] and theirs[1]:find("%(1h 30m%)"), "combined time: " .. tostring(theirs[1]) .. "\n" .. dump())
    expect(text:find("Ranch: %+45 Milk"), text)
    expect(text:find("Shared storage: %+"), "shared storage is theirs too")
    expect(not text:find("Mining Base"), "nothing about the host's base")
    expect(store.load(OFFLINE_PROGRESS_STATE_PATH).worlds.W.pending[F.key(2)] == nil, "delivered once, then cleared")
    now = now + 5; join()
    expect(#theirs == 3, "not sent twice")
end)

test("if a joining player's character can't be seen, they still get it after 45 seconds", function()
    local join = loops[5000]
    local third = playerState(3, false)
    local st = store.load(OFFLINE_PROGRESS_STATE_PATH)
    st.worlds.W.pending = nil
    store.save(OFFLINE_PROGRESS_STATE_PATH, st)
    -- give player 3 a pending summary through the live state
    palboxes[F.key(5002)] = 3
    hook(title); now = now + 600; saveAt(now - 600); hook(gs)
    F.world.PalPlayerState = { host, friend, third }
    for _ = 1, 9 do now = now + 5; join() end -- first check notes the join; 9th is 40 s later
    expect(chats[F.key(3)] == nil, "still waiting at 40 s")
    now = now + 5; join()
    expect(chats[F.key(3)] and #chats[F.key(3)] >= 2, "sent at 45 s: " .. dump())
end)

os.remove(OFFLINE_PROGRESS_STATE_PATH)
os.remove(OFFLINE_PROGRESS_STATE_PATH .. ".bak")
print = say
os.time = realTime
say(("\n%d passed, %d failed"):format(passed, failed))
if arg then os.exit(failed == 0 and 0 or 1) end -- standalone lua
return failed                                    -- embedded (run_tests.py)

-- The only file that touches Palworld's objects. Everything else is engine-independent.
--
-- Written against a CXXHeaderDump of Palworld 1.0.5. Names used, all present in that dump:
--   APalGameStateInGame         GetWorldSaveDirectoryName()
--   UPalSaveGameManager         LoadedWorldSaveData -> UPalWorldSaveGame.Timestamp
--   UPalTimeManager             GetCurrentPalWorldHoursFloat(), GetCurrentPalWorldTime_TotalDay(),
--                               GetCurrentDayTimeType(), SetGameTime_FixDay()
--   UPalCheatManager            SetGameTime_NextDay()
--   UPalBaseCampManager         UpdateIntervalSquaredDistanceFromPlayer
--   UPalBaseCampModel           ID, IsAvailable(), bTemporary, PlayerUIdsExistsInsideInServer,
--                               GetTransform(), ModuleArray
--   UPalBaseCampModuleItemStorage / ItemStackInfo   OnUpdateItemContainer()
--   UPalMapObjectConcreteModelBase  GetBaseCampIdBelongTo(), GetItemContainerModule(), GetInstanceId(),
--                               GetEnergyModule()
--   UPalMapObjectItemContainerModule GetContainer()
--   UPalGuildItemStorage        ItemContainer
--   UPalItemContainer           ID, ItemSlotArray, CorruptionMultiplier, bIgnoreOnSave,
--                               OnUpdateSlotContent(), OnRep_ItemSlotArray()
--   UPalItemSlot                ItemId.StaticId, StackCount, SlotIndex, DynamicItemData, CorruptionProgressValue,
--                               GetMaxStack(), IsEmpty(), GetCorruptionProgressRate(), OnRep_*()
--   UPalItemIDManager           GetStaticItemData() -> CorruptionFactor, MaxStackCount, IsCorruptible(),
--                               DynamicItemDataClass
--   UPalWorkBase                ID, BaseCampIdBelongTo, OwnerMapObjectConcreteModelId, CachedOwnerMapObjectConcreteModel
--   UPalWorkProgress            RequiredWorkAmount, CurrentWorkAmount, AutoWorkSelfAmountBySec, IsCompleted()
--   UPalMapObjectConvertItemModel  CurrentRecipeId, RemainProductNum, IsProductNumInfinite(), IsTransportToStorage()
--   UPalMasterDataTablesUtility GetItemRecipeDataTable() -> FPalItemRecipe rows
--   UPalMapObjectBreedFarmModel BreedProgressTime, BreedRequiredRealTime, CanProceedBreeding(),
--                               SpawnedEggInstanceIds, ExistPalEggMaxNum
--   UPalMapObjectFarmBlockV2Model  CurrentCropDataId, CurrentState, CropProgressRateValue
--   UPalIndividualCharacterParameter  BaseCampId, IndividualId, SaveParameter.FullStomach/SanityValue,
--                               SetFullStomach()
-- Re-check these after every Palworld patch.
--
-- Called from the game thread (main.lua wraps calls in ExecuteInGameThread).

local cfg = require("config")

local M = {}

local CLASSES = {
    bases = { "PalBaseCampModel" },
    chests = { "PalMapObjectItemChestModel", "PalMapObjectItemChest_AffectCorruption" },
    guildChests = { "PalMapObjectGuildChestModel" },
    guildStorage = { "PalGuildItemStorage" },
    foodBoxes = { "PalMapObjectPalFoodBoxModel" },
    work = { "PalWorkProgress", "PalWorkProgressMultiType" },
    stations = { "PalMapObjectConvertItemModel" },
    breedFarms = { "PalMapObjectBreedFarmModel" },
    crops = { "PalMapObjectFarmBlockV2Model" },
    pals = { "PalIndividualCharacterParameter" },
    players = { "PalPlayerCharacter", "BP_Player_Female_C", "BP_Player_Male_C" },
    controllers = { "PalPlayerController", "BP_PalPlayerController_C" },
    saveManager = { "PalSaveGameManager", "BP_PalSaveGameManager_C" },
    timeManager = { "PalTimeManager", "BP_PalTimeManager_C" },
    baseManager = { "PalBaseCampManager", "BP_PalBaseCampManager_C" },
    itemIds = { "PalItemIDManager", "BP_PalItemIDManager_C" },
}

local FOOD = "food"             -- everything in a feed box counts as one "food" stock
local DEFAULT_MAX_STACK = 9999  -- used when no existing stack tells us the real limit
local EMPTY_ID = "None"
local ZERO_KEY = ("0"):rep(32)
local GROWUP = 3                -- EPalFarmCropState::Growup
local NIGHT = 2                 -- EPalOneDayTimeType::Night

local gameState = nil
local lastScan = {}    -- pool id -> group, from the latest scan
local workById = {}    -- timer id -> UPalWorkProgress, from the latest getTimers call
local itemInfoCache = {}
local recipeTable = nil

local function try(fn) pcall(fn) end

local function valid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

local function addressOf(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    return ok and a or tostring(obj)
end

-- FindAllOf may or may not include subclasses, so several names are searched and each object
-- is kept once.
-- Every full object search is noted here so slow work can be traced to it.
M.searches = {}
local function search(name)
    M.searches[#M.searches + 1] = name
    return FindAllOf(name)
end

local function findAll(classes)
    local out, seen = {}, {}
    for _, name in ipairs(classes) do
        for _, obj in ipairs(search(name) or {}) do
            local key = addressOf(obj)
            if valid(obj) and not seen[key] then
                seen[key] = true
                out[#out + 1] = obj
            end
        end
    end
    return out
end

-- A full object search costs tens of milliseconds on a big world, so one-of-a-kind objects
-- (the game's managers) are looked up once per world load and remembered. A failed lookup is
-- retried at most once a minute.
local singletons, misses = {}, {}
local function findFirst(classes)
    local key = classes[1]
    local o = singletons[key]
    if o and valid(o) then return o end
    if misses[key] and os.time() - misses[key] < 60 then return nil end
    o = findAll(classes)[1]
    singletons[key] = o
    misses[key] = (o == nil) and os.time() or nil
    return o
end

local function guidKey(g)
    return ("%08X%08X%08X%08X"):format(g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
end

local function arrayCount(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok then return n end
    return #arr
end

local function str(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or tostring(v)
end

local function className(obj)
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and n or ""
end

-- World, save and clock --------------------------------------------------------------

local basesCache, basesCachedAt = nil, nil

function M.setGameState(gs)
    gameState = gs
    singletons, misses = {}, {}
    basesCache, basesCachedAt = nil, nil
end

-- Player states straight from the game state's player list (cheap); a full object search
-- only if that list can't be read. Second value: whether the list was read.
local function playerStates()
    local out = {}
    local ok = pcall(function()
        gameState.PlayerArray:ForEach(function(_, e)
            local ps = e:get()
            if valid(ps) then out[#out + 1] = ps end
        end)
    end)
    if ok then return out, true end
    return findAll({ "PalPlayerState", "BP_PalPlayerState_C" }), false
end

-- A usable string, or nil. Unsupported return types come back as "TrivialObject: <address>",
-- which changes every launch and must never be used as an id.
local function cleanString(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" and s ~= "" and not s:find("TrivialObject", 1, true) then return s end
    return nil
end

local function gameInstance()
    local gi = nil
    pcall(function()
        gi = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetGameInstance(gameState)
    end)
    if valid(gi) then return gi end
    return findFirst({ "PalGameInstance", "BP_PalGameInstance_C" })
end

-- The world's save folder name, or an id built from its bases (same every launch, unique to
-- the world) if the name can't be read. Second value: what each lookup returned, for the log.
function M.worldId()
    local tried = {}
    local gi = gameInstance()
    local getters = {
        { "GameInstance.SelectedWorldSaveDirectoryName", function() return gi.SelectedWorldSaveDirectoryName end },
        { "GameInstance:GetSelectedWorldSaveDirectoryName()", function() return gi:GetSelectedWorldSaveDirectoryName() end },
        { "GameState.WorldSaveDirectoryName", function() return gameState.WorldSaveDirectoryName end },
        { "GameState:GetWorldSaveDirectoryName()", function() return gameState:GetWorldSaveDirectoryName() end },
    }
    for _, g in ipairs(getters) do
        local ok, v = pcall(g[2])
        local s = ok and cleanString(v) or nil
        if s then return s, nil end
        local shown = "error"
        if ok then
            local ok2, raw = pcall(function() return v:ToString() end)
            shown = ok2 and ("\"" .. tostring(raw) .. "\"") or tostring(v)
        end
        tried[#tried + 1] = g[1] .. " = " .. shown
    end
    local ids = M.baseIds()
    if #ids > 0 then return "bases:" .. ids[1], table.concat(tried, "; ") end
    return nil, table.concat(tried, "; ")
end

-- FDateTime has no fields visible to Lua, so dates are only handled through the engine's
-- date functions.
local function kismet() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end

local function secondsBetween(a, b)
    local K = kismet()
    return K:GetTotalSeconds(K:Subtract_DateTimeDateTime(a, b))
end

local function minusSeconds(dt, seconds)
    local K = kismet()
    local whole = math.floor(seconds)
    local days = whole // 86400
    local hours = (whole % 86400) // 3600
    local minutes = (whole % 3600) // 60
    local secs = whole % 60
    local ms = math.floor((seconds - whole) * 1000)
    return K:Subtract_DateTimeTimespan(dt, K:MakeTimespan(days, hours, minutes, secs, ms))
end

-- How long ago the loaded save was written, read against both UTC and local "now" since the
-- game could store either. Returns { utc = seconds, ["local"] = seconds } or nil, reason.
function M.saveAge()
    local sm = nil
    local gi = gameInstance()
    if gi then pcall(function() sm = gi.SaveGameManager end) end
    if not valid(sm) then sm = findFirst(CLASSES.saveManager) end
    if not sm then return nil, "save manager not found" end
    local data = nil
    pcall(function() data = sm.LoadedWorldSaveData end)
    if not valid(data) then return nil, "loaded save data not available" end
    local ok, ages = pcall(function()
        local K = kismet()
        return { utc = -secondsBetween(data.Timestamp, K:UtcNow()), ["local"] = -secondsBetween(data.Timestamp, K:Now()) }
    end)
    if not ok then return nil, "couldn't read the save timestamp: " .. tostring(ages) end
    return ages
end

-- Work timed on the game's "real progress" clock, which stops while the world is closed:
-- expeditions in progress and Pals reviving in medical beds.
function M.realProgressTimers()
    local out = {}
    for _, m in ipairs(findAll({ "PalMapObjectCharacterTeamMissionModel" })) do
        if m.State == 2 then -- InProgress
            local baseId = nil
            try(function() baseId = guidKey(m:GetBaseCampIdBelongTo()) end)
            out[#out + 1] = { kind = "expedition", ref = m, baseId = baseId, onRep = "OnRep_MissionCompleteDateTime",
                              fields = { "MissionStartDateTime", "MissionCompleteDateTime" } }
        end
    end
    for _, b in ipairs(findAll({ "PalMapObjectMedicalPalBedModel" })) do
        if valid(b.SleepingCharacterHandle) then
            out[#out + 1] = { kind = "medical bed", ref = b, onRep = "OnRep_ResurrectCompleteRealProgressDateTime",
                              fields = { "ResurrectCompleteRealProgressDateTime" } }
        end
    end
    return out
end

-- A date as the engine's text form, "YYYY.MM.DD-HH.MM.SS" (what FDateTime imports and exports).
local function dateText(dt)
    local K = kismet()
    return ("%04d.%02d.%02d-%02d.%02d.%02d"):format(K:GetYear(dt), K:GetMonth(dt), K:GetDay(dt),
        K:GetHour(dt), K:GetMinute(dt), K:GetSecond(dt))
end

-- Writes a date property. Assigning a date value directly doesn't stick in this UE4SS build
-- (FDateTime has no fields Lua can see), so if that doesn't read back, the date is imported
-- as text, the same way the engine loads it. `isMoved` checks the result.
-- Returns the method that worked ("assign" or "text"), or nil and the error.
local function writeDate(obj, field, value, isMoved)
    local ok, err = pcall(function() obj[field] = value end)
    if ok and isMoved() then return "assign" end
    local okText, errText = pcall(function()
        local prop = obj:Reflection():GetProperty(field)
        prop:ImportText(dateText(value), prop:ContainerPtrToValuePtr(obj, 0), 0, obj)
    end)
    if okText and isMoved() then return "text" end
    return nil, tostring(errText or err or "date didn't change")
end

-- Moves a real-progress timer's dates earlier by `seconds`. Returns true if every date reads
-- back as moved by that amount, plus the write method used or the first error.
function M.shiftRealProgress(t, seconds)
    local allOk, method, firstErr = true, nil, nil
    for _, field in ipairs(t.fields) do
        local ok, used, err = pcall(function()
            local original = minusSeconds(t.ref[field], 0) -- a copy, not a view of the live value
            local function isMoved()
                local okM, moved = pcall(function() return secondsBetween(original, t.ref[field]) end)
                return okM and math.abs(moved - seconds) <= 2
            end
            local m, e = writeDate(t.ref, field, minusSeconds(original, seconds), isMoved)
            if m and field == t.fields[#t.fields] then
                try(function() t.ref[t.onRep](t.ref, original) end)
            end
            return m, e
        end)
        if not ok then used, err = nil, tostring(used) end
        if used then method = method or used else allOk = false; firstErr = firstErr or err end
    end
    return allOk, method, firstErr
end

-- { hour, day, phase } of the in-game clock, or nil.
function M.clock()
    local tm = findFirst(CLASSES.timeManager)
    if not tm then return nil end
    local ok, c = pcall(function()
        local t = tm:GetCurrentDayTimeType()
        return {
            hour = tm:GetCurrentPalWorldHoursFloat(),
            day = tm:GetCurrentPalWorldTime_TotalDay(),
            phase = (t == NIGHT) and "night" or ((t == 1) and "day" or nil),
        }
    end)
    if ok then return c end
    return nil
end

-- Moves the clock forward per timeline.advancePlan. Returns a description of what was done.
function M.advanceClock(plan)
    local done = {}
    if plan.nextDays > 0 then
        local pc = findFirst(CLASSES.controllers)
        local cm = pc and pc.CheatManager
        if not valid(cm) then
            return false, "no cheat manager available to change the day (is CheatManagerEnablerMod on?)"
        end
        for _ = 1, plan.nextDays do cm:SetGameTime_NextDay() end
        done[#done + 1] = ("%d day(s) forward"):format(plan.nextDays)
    end
    if plan.setHour then
        local tm = findFirst(CLASSES.timeManager)
        if not tm then return false, "time manager not found" end
        tm:SetGameTime_FixDay(plan.setHour)
        done[#done + 1] = ("clock set to %02d:00"):format(plan.setHour)
    end
    return true, table.concat(done, ", ")
end

-- Bases, players and storage -----------------------------------------------------------

-- Bases change rarely, so the list is refreshed at most every 10 minutes.
local function activeBases()
    if basesCache and basesCachedAt and os.time() - basesCachedAt < 600 then
        local fresh = {}
        for _, b in ipairs(basesCache) do if valid(b.model) then fresh[#fresh + 1] = b end end
        return fresh
    end
    local list = {}
    for _, model in ipairs(findAll(CLASSES.bases)) do
        if model:IsAvailable() and not model.bTemporary then
            list[#list + 1] = { id = guidKey(model.ID), model = model }
        end
    end
    basesCache, basesCachedAt = list, os.time()
    return list
end

function M.baseIds()
    local ids = {}
    for _, b in ipairs(activeBases()) do ids[#ids + 1] = b.id end
    table.sort(ids)
    return ids
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Per base: is a player inside it, and how far away is the nearest player.
-- Also returns the distance beyond which the game updates bases less often.
function M.presence()
    local players = {}
    local states, fromList = playerStates()
    for _, ps in ipairs(states) do
        local ok, loc = pcall(function()
            local pawn = nil
            pcall(function() pawn = ps:GetPawn() end)
            if not valid(pawn) then pawn = ps.PawnPrivate end
            return pawn:K2_GetActorLocation()
        end)
        if ok and loc then players[#players + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z } end
    end
    if not fromList and #players == 0 then
        for _, p in ipairs(findAll(CLASSES.players)) do
            local ok, loc = pcall(function() return p:K2_GetActorLocation() end)
            if ok and loc then players[#players + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z } end
        end
    end
    local threshold = nil
    local manager = findFirst(CLASSES.baseManager)
    if manager then
        local ok, sq = pcall(function() return manager.UpdateIntervalSquaredDistanceFromPlayer end)
        if ok and type(sq) == "number" and sq > 0 then threshold = math.sqrt(sq) end
    end
    local out = {}
    for _, b in ipairs(activeBases()) do
        local inside = arrayCount(b.model.PlayerUIdsExistsInsideInServer) > 0
        local nearest = nil
        local ok, t = pcall(function() return b.model:GetTransform().Translation end)
        if ok and t then
            for _, p in ipairs(players) do
                local d = distance(p, { X = t.X, Y = t.Y, Z = t.Z })
                if not nearest or d < nearest then nearest = d end
            end
        end
        out[b.id] = { inside = inside, distance = nearest }
    end
    return out, threshold
end

local function itemInfo(id)
    local cached = itemInfoCache[id]
    if cached then return cached end
    local info = { factor = 0, corruptible = false, maxStack = nil, unique = false }
    local manager = findFirst(CLASSES.itemIds)
    if manager then
        try(function()
            local data = manager:GetStaticItemData(FName(id))
            if valid(data) then
                info.factor = data.CorruptionFactor or 0
                info.corruptible = data:IsCorruptible()
                info.maxStack = data.MaxStackCount
                local cls = data.DynamicItemDataClass
                info.unique = (cls ~= nil and valid(cls)) or (info.maxStack ~= nil and info.maxStack <= 1)
            end
        end)
    end
    itemInfoCache[id] = info
    return info
end

local function slotItem(slot)
    if slot:IsEmpty() or slot.StackCount <= 0 then return nil end
    local id = slot.ItemId.StaticId:ToString()
    if id == EMPTY_ID or id == "" then return nil end
    return id
end

-- Eggs, weapons and armour carry per-item data; they're never counted, created or edited.
local function isUnique(slot)
    local ok, d = pcall(function() return slot.DynamicItemData:Get() end)
    if ok and d and valid(d) then return true end
    return slot:GetMaxStack() <= 1
end

local function containerRecord(container, module)
    if not valid(container) then return nil end
    local slots = {}
    container.ItemSlotArray:ForEach(function(_, elem)
        local slot = elem:get()
        if slot and valid(slot) then slots[#slots + 1] = slot end
    end)
    local key
    local ok, k = pcall(function() return guidKey(container.ID.ID) end)
    key = ok and k or tostring(addressOf(container))
    local mult = 1
    try(function() mult = container.CorruptionMultiplier end)
    local ignored = false
    try(function() ignored = container.bIgnoreOnSave end)
    return { container = container, module = module, slots = slots, key = key, mult = mult, ignored = ignored }
end

local function containerOf(model)
    local module = model:GetItemContainerModule()
    if not valid(module) then return nil end
    return containerRecord(module:GetContainer(), module)
end

-- Re-reads every chest and feed box. Storage used by more than one base (guild storage) gets
-- its own pool, "shared:<container id>", so it isn't counted once per base.
local function scan()
    local groups, owners, records = {}, {}, {}
    local bases = {}
    for _, b in ipairs(activeBases()) do bases[b.id] = b.model end

    local function note(kind, baseId, rec)
        if not rec then return end
        records[#records + 1] = { kind = kind, baseId = baseId, rec = rec }
        owners[rec.key] = owners[rec.key] or {}
        owners[rec.key][baseId] = true
    end
    for _, m in ipairs(findAll(CLASSES.chests)) do note("chests", guidKey(m:GetBaseCampIdBelongTo()), containerOf(m)) end
    for _, m in ipairs(findAll(CLASSES.foodBoxes)) do note("food", guidKey(m:GetBaseCampIdBelongTo()), containerOf(m)) end
    for _, m in ipairs(findAll(CLASSES.guildChests)) do
        local rec = containerOf(m)
        if rec then note("shared", "guild", rec) end
    end
    for _, s in ipairs(findAll(CLASSES.guildStorage)) do
        local ok, c = pcall(function() return s.ItemContainer end)
        if ok then note("shared", "guild", containerRecord(c, nil)) end
    end

    local placed = {}
    for _, r in ipairs(records) do
        if not placed[r.rec.key] then
            placed[r.rec.key] = true
            local n = 0
            for _ in pairs(owners[r.rec.key]) do n = n + 1 end
            local poolId, kind = r.baseId, r.kind
            if kind == "shared" then
                poolId, kind = "shared:" .. r.rec.key, "chests"
            elseif n > 1 then
                poolId = "shared:" .. r.rec.key -- a feed box stays a feed box
            end
            if poolId ~= ZERO_KEY then
                groups[poolId] = groups[poolId] or { chests = {}, food = {}, model = bases[poolId] }
                table.insert(groups[poolId][kind], r.rec)
                if poolId:match("^shared:") then
                    groups[poolId].sharedBy = groups[poolId].sharedBy or {}
                    for baseId in pairs(owners[r.rec.key]) do
                        if baseId ~= "guild" then groups[poolId].sharedBy[baseId] = true end
                    end
                end
            end
        end
    end
    for id, model in pairs(bases) do
        groups[id] = groups[id] or { chests = {}, food = {}, model = model }
    end
    lastScan = groups
    return groups
end

-- Stocks, per-item capacity, capacity for items not held yet, feed contents and spoilage data.
local function tally(group)
    local stocks, room, maxStack, empties = {}, {}, {}, 0
    local spoil = {}
    local function noteSpoil(rec, slot, id)
        local info = itemInfo(id)
        if info.corruptible and (info.factor or 0) > 0 then
            local ok, s = pcall(function()
                return { item = id, count = slot.StackCount, value = slot.CorruptionProgressValue,
                         progress = slot:GetCorruptionProgressRate(), mult = rec.mult, factor = info.factor,
                         slot = slot }
            end)
            if ok then spoil[rec.key .. ":" .. tostring(slot.SlotIndex)] = s end
        end
    end
    for _, rec in ipairs(group.chests) do
        for _, slot in ipairs(rec.slots) do
            local id = slotItem(slot)
            if id and not isUnique(slot) then
                local max = slot:GetMaxStack()
                stocks[id] = (stocks[id] or 0) + slot.StackCount
                room[id] = (room[id] or 0) + math.max(0, max - slot.StackCount)
                maxStack[id] = max
                noteSpoil(rec, slot, id)
            elseif not id then
                empties = empties + 1
            end
        end
    end

    local food, foodRoom, foodItems = 0, 0, {}
    for _, rec in ipairs(group.food) do
        for _, slot in ipairs(rec.slots) do
            local id = slotItem(slot)
            if id and not isUnique(slot) then
                food = food + slot.StackCount
                foodRoom = foodRoom + math.max(0, slot:GetMaxStack() - slot.StackCount)
                foodItems[id] = (foodItems[id] or 0) + slot.StackCount
                noteSpoil(rec, slot, id)
            end
        end
    end

    local full = cfg.itemWriteMode == "full"
    local caps = {}
    for id, s in pairs(stocks) do
        caps[id] = s + room[id] + (full and empties * maxStack[id] or 0)
    end
    if #group.food > 0 then
        stocks[FOOD] = food
        caps[FOOD] = food + foodRoom
    end
    return { stocks = stocks, caps = caps, defaultCap = full and empties * DEFAULT_MAX_STACK or 0,
             foodItems = foodItems, spoil = spoil }
end

-- Pals assigned to bases: baseId -> palId -> { stomach, sanity, max, ref }
local function workers()
    local out = {}
    for _, param in ipairs(findAll(CLASSES.pals)) do
        try(function()
            local baseId = guidKey(param.BaseCampId)
            if baseId ~= ZERO_KEY then
                local sp = param.SaveParameter
                out[baseId] = out[baseId] or {}
                out[baseId][guidKey(param.IndividualId.InstanceId)] = {
                    stomach = sp.FullStomach, sanity = sp.SanityValue, max = sp.MaxFullStomach, ref = param }
            end
        end)
    end
    return out
end

-- One line for the log, so each run shows whether the lookups work.
function M.describe()
    local groups = scan()
    local chests, food, shared, ignored = 0, 0, 0, 0
    for id, g in pairs(groups) do
        chests = chests + #g.chests
        food = food + #g.food
        if id:match("^shared:") then shared = shared + 1 end
        for _, rec in ipairs(g.chests) do if rec.ignored then ignored = ignored + 1 end end
        for _, rec in ipairs(g.food) do if rec.ignored then ignored = ignored + 1 end end
    end
    local stations, active = findAll(CLASSES.stations), 0
    for _, s in ipairs(stations) do
        local ok, r = pcall(function() return s.CurrentRecipeId:ToString() end)
        if ok and r ~= EMPTY_ID and r ~= "" and s.RemainProductNum ~= 0 then active = active + 1 end
    end
    local pals = 0
    for _, w in pairs(workers()) do for _ in pairs(w) do pals = pals + 1 end end
    return ("found %d base(s), %d chest(s), %d feed box(es), %d shared storage, %d work item(s), "
        .. "%d crafting station(s) (%d with a queue), %d breeding farm(s), %d crop plot(s), %d base Pal(s)%s")
        :format(#activeBases(), chests, food, shared, #findAll(CLASSES.work), #stations, active,
            #findAll(CLASSES.breedFarms), #findAll(CLASSES.crops), pals,
            ignored > 0 and (", WARNING: %d container(s) marked not to be saved"):format(ignored) or "")
end

function M.getGameVersion()
    local settings = StaticFindObject("/Script/EngineSettings.Default__GeneralProjectSettings")
    if not valid(settings) then return nil end
    local raw = settings.ProjectVersion:ToString()
    return raw:match("%d+%.%d+%.%d+"), raw
end

-- Measuring snapshot (plain data, no object references kept in it).
function M.snapshot()
    local groups = scan()
    local pals = workers()
    local out = { bases = {} }
    for id, g in pairs(groups) do
        local t = tally(g)
        local spoil = {}
        for key, s in pairs(t.spoil) do
            spoil[key] = { item = s.item, count = s.count, value = s.value, progress = s.progress,
                           mult = s.mult, factor = s.factor }
        end
        local w = {}
        for palId, p in pairs(pals[id] or {}) do w[palId] = { stomach = p.stomach, sanity = p.sanity } end
        out.bases[id] = { items = t.stocks, caps = t.caps, foodItems = t.foodItems, workers = w, spoil = spoil }
    end
    return out
end

-- Every base and shared pool for catch-up.
function M.listBases()
    local groups = scan()
    local list = {}
    for id, g in pairs(groups) do
        local t = tally(g)
        list[#list + 1] = { id = id, stocks = t.stocks, caps = t.caps, defaultCap = t.defaultCap,
                            foodItems = t.foodItems, shared = id:match("^shared:") ~= nil, sharedBy = g.sharedBy }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Spoilage ---------------------------------------------------------------------------------

-- Every perishable stack in base storage: { { item, value, progress, mult, factor, ref }, ... }
function M.spoilSlots()
    local out = {}
    for _, g in pairs(scan()) do
        for _, s in pairs(tally(g).spoil) do out[#out + 1] = s end
    end
    return out
end

function M.setSpoil(slot, value)
    slot.CorruptionProgressValue = value
    try(function() slot:OnRep_CorruptionProgressValue() end)
end

-- Pal needs --------------------------------------------------------------------------------

function M.workers(baseId) return workers()[baseId] or {} end

function M.setPalNeeds(ref, stomach, sanity)
    if stomach then ref:SetFullStomach(stomach) end
    if sanity then
        ref.SaveParameter.SanityValue = sanity
        try(function() ref:OnRep_SaveParameter() end)
    end
end

-- Timers -----------------------------------------------------------------------------------

local function ownerKey(work)
    local ok, k = pcall(function() return guidKey(work.OwnerMapObjectConcreteModelId) end)
    return ok and k or nil
end

local function needsPower(work)
    local ok, v = pcall(function()
        local owner = work.CachedOwnerMapObjectConcreteModel
        return valid(owner) and valid(owner:GetEnergyModule())
    end)
    return ok and v or false
end

local WORKABLE = 1 -- EPalWorkProgressState::Workable

-- Is this work actually running? An empty incubator still has a work object, but the game
-- marks it NotWorkable; advancing it would report an egg that doesn't exist.
local function isRunning(work)
    local ok, state = pcall(function() return work.CurrentState end)
    if ok and type(state) == "number" and state ~= WORKABLE then return false end
    local owner = nil
    pcall(function() owner = work.CachedOwnerMapObjectConcreteModel end)
    if valid(owner) then
        local okW, workable = pcall(function() return owner:IsWorkable() end)
        if okW and workable == false then return false end
    end
    return true
end

-- "incubator" for egg incubators, "machine" for any other self-running work.
local function timerKind(work)
    local ok, name = pcall(function() return className(work.CachedOwnerMapObjectConcreteModel) end)
    if ok and name and name:find("HatchingEgg", 1, true) then return "incubator" end
    return "machine"
end

-- Self-progressing work at a base that is actually running (incubators with an egg and similar):
-- { { id, remaining = seconds, owner, power, kind }, ... }
function M.getTimers(baseId)
    local timers = {}
    for _, work in ipairs(findAll(CLASSES.work)) do
        local rate = work.AutoWorkSelfAmountBySec
        if rate > 0 and work.RequiredWorkAmount > 0 and not work:IsCompleted()
            and guidKey(work.BaseCampIdBelongTo) == baseId and isRunning(work) then
            local id = guidKey(work.ID)
            workById[id] = work
            timers[#timers + 1] = { id = id, remaining = (work.RequiredWorkAmount - work.CurrentWorkAmount) / rate,
                                    owner = ownerKey(work), power = needsPower(work), kind = timerKind(work) }
        end
    end
    return timers
end

-- Moves each timer forward. A finished one is left a hair short of done, so the game
-- completes it on its next tick through its normal code path.
function M.applyTimers(baseId, timers)
    for _, t in ipairs(timers) do
        local work = workById[t.id]
        if work and valid(work) then
            local rate = work.AutoWorkSelfAmountBySec
            local target = work.RequiredWorkAmount - t.remaining * rate
            if t.done then target = work.RequiredWorkAmount - math.max(rate * 0.5, 0.001) end
            if target > work.CurrentWorkAmount then
                work.CurrentWorkAmount = target
                try(function() work:OnRep_CurrentWorkAmount() end)
            end
        end
    end
end

-- After a timer finished, gives the rest of the gap to whatever started next at the same
-- machine (e.g. the next craft). Returns how many seconds were used.
function M.advanceNextAtOwner(owner, seconds, exceptIds)
    local used = 0
    for _, work in ipairs(findAll(CLASSES.work)) do
        local rate = work.AutoWorkSelfAmountBySec
        if rate > 0 and work.RequiredWorkAmount > 0 and not work:IsCompleted() and ownerKey(work) == owner
            and not exceptIds[guidKey(work.ID)] and isRunning(work) then
            local remaining = (work.RequiredWorkAmount - work.CurrentWorkAmount) / rate
            local step = math.min(seconds, remaining)
            local target = work.CurrentWorkAmount + step * rate
            if step >= remaining then target = work.RequiredWorkAmount - math.max(rate * 0.5, 0.001) end
            work.CurrentWorkAmount = math.max(work.CurrentWorkAmount, target)
            try(function() work:OnRep_CurrentWorkAmount() end)
            exceptIds[guidKey(work.ID)] = true
            used = math.max(used, step)
        end
    end
    return used
end

-- Crafting stations ------------------------------------------------------------------------

local function recipe(id)
    if not recipeTable then
        try(function()
            local util = StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
            recipeTable = util:GetItemRecipeDataTable(gameState)
        end)
    end
    if not valid(recipeTable) then return nil end
    local ok, row = pcall(function() return recipeTable:FindRow(id) end)
    if not ok or not row then return nil end
    local r = { product = str(row.Product_Id), perCraft = row.Product_Count, materials = {} }
    for i = 1, 5 do
        local mid = str(row["Material" .. i .. "_Id"])
        local n = row["Material" .. i .. "_Count"]
        if mid ~= EMPTY_ID and mid ~= "" and n and n > 0 then r.materials[mid] = n end
    end
    return r
end

-- baseId -> { { id, product, perCraft, materials, remain, infinite, toStorage, ref }, ... }
function M.stations()
    local out = {}
    for _, s in ipairs(findAll(CLASSES.stations)) do
        try(function()
            local rid = s.CurrentRecipeId:ToString()
            if rid == EMPTY_ID or rid == "" then return end
            local r = recipe(rid)
            if not r then return end
            local baseId = guidKey(s:GetBaseCampIdBelongTo())
            out[baseId] = out[baseId] or {}
            local remain = s.RemainProductNum
            table.insert(out[baseId], {
                id = guidKey(s:GetInstanceId()), recipe = rid, product = r.product, perCraft = r.perCraft,
                materials = r.materials, remain = remain, infinite = s:IsProductNumInfinite(remain),
                toStorage = s:IsTransportToStorage(), ref = s })
        end)
    end
    return out
end

-- Takes finished crafts off a station's queue. A queue that would empty is left on its last
-- craft, nearly done, so the game finishes it through its own code.
function M.applyStation(st, crafts)
    if st.infinite or crafts <= 0 then return end
    local s = st.ref
    local left = st.remain - crafts
    if left >= 1 then
        s.RemainProductNum = left
    else
        s.RemainProductNum = 1
        for _, work in ipairs(findAll(CLASSES.work)) do
            if ownerKey(work) == st.id and work.RequiredWorkAmount > 0 and not work:IsCompleted() then
                work.CurrentWorkAmount = work.RequiredWorkAmount * 0.999
                try(function() work:OnRep_CurrentWorkAmount() end)
            end
        end
    end
    try(function() s:OnRep_RemainProductNum() end)
end

-- Breeding farms ---------------------------------------------------------------------------

-- baseId -> { { id, progress, required, canProceed, eggs, maxEggs, ref }, ... } (seconds)
function M.breedFarms()
    local out = {}
    for _, f in ipairs(findAll(CLASSES.breedFarms)) do
        try(function()
            local baseId = guidKey(f:GetBaseCampIdBelongTo())
            out[baseId] = out[baseId] or {}
            table.insert(out[baseId], {
                id = guidKey(f:GetInstanceId()), progress = f.BreedProgressTime, required = f.BreedRequiredRealTime,
                canProceed = f:CanProceedBreeding(), eggs = arrayCount(f.SpawnedEggInstanceIds),
                maxEggs = f.ExistPalEggMaxNum, ref = f })
        end)
    end
    return out
end

function M.setBreedProgress(ref, seconds)
    ref.BreedProgressTime = seconds
    try(function() ref:OnRep_UpdateBreedProgress() end)
end

-- Crops ------------------------------------------------------------------------------------

-- baseId -> { { id, crop, growing, progress, ref }, ... }
function M.crops()
    local out = {}
    for _, c in ipairs(findAll(CLASSES.crops)) do
        try(function()
            local baseId = guidKey(c:GetBaseCampIdBelongTo())
            out[baseId] = out[baseId] or {}
            table.insert(out[baseId], {
                id = guidKey(c:GetInstanceId()), crop = c.CurrentCropDataId:ToString(),
                growing = c.CurrentState == GROWUP, progress = c.CropProgressRateValue, ref = c })
        end)
    end
    return out
end

function M.setCropProgress(ref, value)
    ref.CropProgressRateValue = value
    try(function() ref:OnRep_CropProgressRateValue() end)
end

-- Writing items ----------------------------------------------------------------------------

local function addToSlots(slots, matches, n, touched)
    for _, slot in ipairs(slots) do
        if n <= 0 then break end
        if matches(slot) then
            local add = math.min(n, slot:GetMaxStack() - slot.StackCount)
            if add > 0 then
                slot.StackCount = slot.StackCount + add
                touched[#touched + 1] = slot
                n = n - add
            end
        end
    end
    return n
end

local function removeFromSlots(slots, matches, n, touched)
    local full = cfg.itemWriteMode == "full"
    for _, slot in ipairs(slots) do
        if n <= 0 then break end
        if matches(slot) then
            -- In topUpOnly mode a stack never empties, so no slot ever changes item.
            local take = math.min(n, slot.StackCount - (full and 0 or 1))
            if take > 0 then
                slot.StackCount = slot.StackCount - take
                if slot.StackCount == 0 then slot.ItemId.StaticId = FName(EMPTY_ID) end
                touched[#touched + 1] = slot
                n = n - take
            end
        end
    end
    return n
end

local function exactItem(id)
    return function(slot) return not isUnique(slot) and slotItem(slot) == id end
end

-- Lets the base's item totals, Pal hauling and mission tracking see the change.
local function announce(group, touched, records)
    for _, entry in ipairs(touched) do
        try(function() entry.rec.container:OnUpdateSlotContent(entry.slot) end)
        try(function() entry.slot:OnRep_ItemId() end)
        try(function() entry.slot:OnRep_StackCount() end)
    end
    for _, rec in pairs(records) do
        try(function() rec.container:OnRep_ItemSlotArray() end)
        if valid(group.model) then
            try(function()
                group.model.ModuleArray:ForEach(function(_, elem)
                    local module = elem:get()
                    local name = className(module)
                    if name:find("ItemStorage") then
                        try(function() module:OnUpdateItemContainer(rec.container) end)
                    elseif name:find("ItemStackInfo") and rec.module then
                        try(function() module:OnUpdateItemContainer(rec.module) end)
                    end
                end)
            end)
        end
    end
end

-- Adds (positive) or removes (negative) whole items. chestDeltas go to chests; feedDeltas
-- name specific items in feed boxes. Returns what couldn't be placed or taken.
function M.applyItemDeltas(poolId, chestDeltas, feedDeltas)
    local group = lastScan[poolId]
    local leftovers = {}
    if not group then return leftovers end
    local touched, records = {}, {}

    local function run(list, id, n, matches, allowNew)
        for _, rec in ipairs(list) do
            local before = #touched
            local local_touched = {}
            if n > 0 then
                n = addToSlots(rec.slots, matches, n, local_touched)
            elseif n < 0 then
                n = -removeFromSlots(rec.slots, matches, -n, local_touched)
            end
            for _, slot in ipairs(local_touched) do touched[#touched + 1] = { rec = rec, slot = slot } end
            if #touched > before then records[rec.key] = rec end
        end
        if n > 0 and allowNew and cfg.itemWriteMode == "full" and not itemInfo(id).unique then
            for _, rec in ipairs(list) do
                for _, slot in ipairs(rec.slots) do
                    if n <= 0 then break end
                    if not slotItem(slot) then
                        slot.ItemId.StaticId = FName(id)
                        local put = math.min(n, slot:GetMaxStack())
                        slot.StackCount = put
                        touched[#touched + 1] = { rec = rec, slot = slot }
                        records[rec.key] = rec
                        n = n - put
                    end
                end
            end
        end
        return n
    end

    for id, n in pairs(chestDeltas or {}) do
        local left = run(group.chests, id, n, exactItem(id), true)
        if left ~= 0 then leftovers[id] = left end
    end
    for id, n in pairs(feedDeltas or {}) do
        local left = run(group.food, id, n, exactItem(id), false)
        if left ~= 0 then leftovers[FOOD .. ":" .. id] = left end
    end
    announce(group, touched, records)
    return leftovers
end

function M.notify(message)
    print("[OfflineProgress] " .. message .. "\n")
end

-- Summaries ---------------------------------------------------------------------------------

-- Bases nobody renamed store the game's internal placeholder, e.g. "新規生成拠点テンプレート名0(仮)"
-- ("auto-generated base template name 0 (temporary)"); show those as "Base 1" and so on.
function M.friendlyBaseName(raw)
    if not raw then return nil end
    local placeholder = raw:find("テンプレート", 1, true) or raw:find("(仮)", 1, true)
    if not placeholder then return raw end
    local n = tonumber(raw:match("([0-9]+)") or "") -- not %d: it can match non-ASCII bytes
    return n and ("Base " .. (n + 1)) or nil
end

-- Each base's name and owner: the player who placed its Palbox.
-- baseId -> { name = string|nil, owner = playerKey|nil }
function M.baseOwners()
    local out = {}
    local manager = findFirst({ "PalMapObjectManager", "BP_PalMapObjectManager_C" })
    for _, b in ipairs(activeBases()) do
        local info = {}
        try(function() info.name = M.friendlyBaseName(cleanString(b.model.BaseCampName)) end)
        if manager then
            try(function()
                local palbox = manager:FindModel(b.model.OwnerMapObjectInstanceId)
                if valid(palbox) then
                    local k = guidKey(palbox.BuildPlayerUId)
                    if k ~= ZERO_KEY then info.owner = k end
                end
            end)
        end
        out[b.id] = info
    end
    return out
end

-- Players in the world right now: { { key, uid, state }, ... }
function M.players()
    local out = {}
    for _, ps in ipairs((playerStates())) do
        try(function()
            local uid = ps.PlayerUId
            local k = guidKey(uid)
            if k ~= ZERO_KEY then out[#out + 1] = { key = k, uid = uid, state = ps } end
        end)
    end
    return out
end

-- Has this player's character spawned (i.e. they've finished loading into the world)?
function M.playerInWorld(p)
    local pawn = nil
    pcall(function() pawn = p.state:GetPawn() end)
    if not valid(pawn) then pcall(function() pawn = p.state.PawnPrivate end) end
    return valid(pawn)
end

local nameCache = {}

-- The game's own (localized) item name, or a tidied-up id if that can't be read.
function M.itemName(id)
    if nameCache[id] then return nameCache[id] end
    local name = nil
    try(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUIUtility")
        local out = {}
        util:GetItemName(gameState, FName(id), out)
        name = cleanString(out.outName)
    end)
    if not name then
        name = id:gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
    end
    nameCache[id] = name
    return name
end

local GLOBAL_CHAT = 1 -- EPalChatCategory::Global

-- A chat message only the given players see (uids are their PlayerUId values).
-- style "player": sent like a typed Global message from `sender`, which pops the chat open on
-- screen the way messages from other players do (consoles don't for system messages).
-- style "system": a system message, which stays in the chat history until chat is opened.
-- Returns the style actually used.
function M.sendChat(text, uids, style, sender)
    local playerErr = nil
    if style ~= "system" then
        local ok, err = pcall(function()
            gameState:BroadcastChatMessage({
                Category = GLOBAL_CHAT, Sender = sender or "Offline Progress", SenderPlayerUId = { A = 0, B = 0, C = 0, D = 0 },
                Message = text, ReceiverPlayerUIds = uids, MessageId = FName(EMPTY_ID),
                MessageArgKeys = {}, MessageArgValues = {},
            })
        end)
        if ok then return "player" end
        playerErr = tostring(err)
    end
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    util:SendSystemToPlayerChat(gameState, text, uids)
    return "system", playerErr
end

-- The game's "+N item" pickup popup on one player's screen.
function M.itemPopup(state, id, n, delay)
    state:AddItemGetLog_ToClient({ StaticItemId = FName(id), Num = n }, delay)
end

return M

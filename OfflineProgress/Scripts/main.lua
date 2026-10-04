-- OfflineProgress: catches Palworld bases up for the time a world was offline.
-- UE4SS Lua mod targeting Palworld 1.0.5 with Okaetsu's RE-UE4SS (experimental-palworld).

local MOD_VERSION = "1.0.1"

local cfg = require("config")
local store = require("store")
local catchup = require("catchup")
local rates = require("rates")
local observe = require("observe")
local timeline = require("timeline")
local summary = require("summary")
local adapter = require("adapter")

local info = debug and debug.getinfo(1, "S")
local scriptDir = info and info.source:match("^@(.*[\\/])") or "./"
local STATE_PATH = rawget(_G, "OFFLINE_PROGRESS_STATE_PATH") or (scriptDir .. "../state.lua")
local FOOD = "food"
local QUEUE = "__queue:"

local function log(fmt, ...)
    print(("[OfflineProgress] " .. fmt .. "\n"):format(...))
end

local function short(id) return tostring(id):sub(1, 8) end

-- Timing: how long the mod's work holds up the game thread. On this Windows build os.clock()
-- is elapsed wall time with millisecond resolution.
local timing = {}
local function clockMs() return os.clock() * 1000 end
local function record(name, ms)
    local t = timing[name] or { n = 0, total = 0, max = 0 }
    timing[name] = t
    t.n, t.total, t.last = t.n + 1, t.total + ms, ms
    if ms > t.max then t.max = ms end
end
-- Runs fn and records how long it took under `name`; errors still propagate.
local function timed(name, fn, ...)
    local searchesBefore = #adapter.searches
    local t0 = clockMs()
    local results = table.pack(pcall(fn, ...))
    local ms = clockMs() - t0
    record(name, ms)
    local debug = cfg.debugTiming
    if debug and debug.enabled and ms >= (debug.slowMs or 5) then
        local counts, names = {}, {}
        for i = searchesBefore + 1, #adapter.searches do
            local n = adapter.searches[i]
            if not counts[n] then names[#names + 1] = n end
            counts[n] = (counts[n] or 0) + 1
        end
        local parts = {}
        for _, n in ipairs(names) do parts[#parts + 1] = counts[n] > 1 and (n .. " x" .. counts[n]) or n end
        log("[slow] %s took %.0f ms; %d full object search(es)%s", name, ms, #adapter.searches - searchesBefore,
            #parts > 0 and (": " .. table.concat(parts, ", ")) or "")
    end
    if #adapter.searches > 10000 then adapter.searches = {} end
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end
-- "name 12.3 ms" or "name avg 4.1 / max 9.8 ms (10x)" for each name, then clears them.
local function timingReport(names)
    local parts = {}
    for _, name in ipairs(names) do
        local t = timing[name]
        if t and t.n > 0 then
            if t.n == 1 then
                parts[#parts + 1] = ("%s %.1f ms"):format(name, t.total)
            else
                parts[#parts + 1] = ("%s avg %.1f / max %.1f ms (%dx)"):format(name, t.total / t.n, t.max, t.n)
            end
            timing[name] = nil
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "nothing ran"
end

local state = store.load(STATE_PATH) or {}
state.worlds = state.worlds or {}
state.spoil = state.spoil or {}

local worldKey, world = nil, nil  -- the loaded world's part of the state
local active = false              -- a world is loaded and this game is its host

local function saveState()
    local ok, err = pcall(store.save, STATE_PATH, state)
    if not ok then log("Couldn't save state: %s", tostring(err)) end
end

if cfg.clearSafeMode and state.safeMode then
    log("Leaving safe mode (was: %s).", tostring(state.safeMode.reason))
    state.safeMode = nil
end

local function enterSafeMode(reason)
    state.safeMode = { reason = reason, time = os.time() }
    log("SAFE MODE: %s. Nothing will be written until clearSafeMode = true is set in config.lua.", reason)
end

local function isPlaceholder(key)
    return key == "unknown" or key:find("TrivialObject", 1, true) ~= nil
end

-- How much measuring a base's rates are built on.
local function sampleCount(bs)
    local n = 0
    for _, p in pairs((bs and bs.processes) or {}) do
        n = n + ((p.tags and p.tags.all and p.tags.all.samples) or p.samples or 0)
    end
    return n
end

local function mergeWorld(into, from)
    for baseId, bs in pairs(from.bases or {}) do
        if sampleCount(bs) > sampleCount(into.bases[baseId]) then into.bases[baseId] = bs end
    end
    for _, k in ipairs({ "time", "crops", "lastApply", "timestampMode", "pending", "progressing", "farms" }) do
        local v = into[k]
        if v == nil or (type(v) == "table" and next(v) == nil) then into[k] = from[k] end
    end
    for _, k in ipairs({ "lastSeen", "lastSaveTime" }) do
        if from[k] and (not into[k] or from[k] > into[k]) then into[k] = from[k] end
    end
end

local function selectWorld(id, diag)
    worldKey = id or "unknown"
    state.worlds[worldKey] = state.worlds[worldKey] or {}
    world = state.worlds[worldKey]
    world.bases = world.bases or {}
    world.time = world.time or {}
    world.crops = world.crops or {}
    world.pending = world.pending or {}
    world.progressing = world.progressing or {} -- self-running work id -> last time it was seen moving
    world.farms = world.farms or {}             -- breeding farm id -> { active, at }
    if state.bases then -- state from before worlds were tracked separately
        if next(world.bases) == nil then
            world.bases = state.bases
            world.lastSeen = world.lastSeen or state.lastSeen
            world.lastApply = world.lastApply or state.lastApply
            log("Moved learned rates from the old state format to world %s.", worldKey)
        end
        state.bases, state.lastSeen, state.lastApply = nil, nil, nil
    end
    if diag then log("World name not readable (%s); using %s.", diag, worldKey) end

    -- Earlier versions could file this world under a per-launch address, "unknown", or a
    -- base-derived id; merge those in when they share bases with this world.
    if not isPlaceholder(worldKey) then
        local here = {}
        for _, id in ipairs(adapter.baseIds()) do here[id] = true end
        for key, w in pairs(state.worlds) do
            local fromBases = key:match("^bases:(.+)$")
            if key ~= worldKey and (isPlaceholder(key) or (fromBases and here[fromBases])) then
                local shares = false
                for id in pairs(w.bases or {}) do if here[id] then shares = true end end
                if shares or next(w.bases or {}) == nil then
                    mergeWorld(world, w)
                    state.worlds[key] = nil
                    log("Moved learned rates from \"%s\" to world %s.", key, worldKey)
                end
            end
        end
    end
end

local function baseState(id)
    local bs = world.bases[id] or {}
    world.bases[id] = bs
    bs.needs = bs.needs or {}
    bs.foodEaten = bs.foodEaten or {}
    bs.foodAdded = bs.foodAdded or {}
    bs.unplaced = bs.unplaced or {}
    return bs
end

local function versionOk()
    local ok, v, raw = pcall(adapter.getGameVersion)
    if ok and v then
        if v == cfg.targetGameVersion then
            log("Game version %s (\"%s\") matches.", v, tostring(raw))
            return true
        end
        log("Game version %s (\"%s\") doesn't match target %s; dry run only.", v, tostring(raw), cfg.targetGameVersion)
        return false
    end
    if cfg.allowUnknownVersion then return true end
    log("Couldn't read the game version (got \"%s\"); dry run only.", tostring(ok and raw or v))
    return false
end

local function describe(items)
    local parts = {}
    for item, n in pairs(items) do parts[#parts + 1] = ("%+d %s"):format(n, item) end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "no change"
end

-- Reference time --------------------------------------------------------------------------

-- The save's timestamp could be UTC or local time; pick the reading that fits, remembering
-- the answer per world once the heartbeat has confirmed it. `ages` comes from adapter.saveAge
-- and was read at `readAt`.
local function resolveSaveTime(ages, readAt, now, why)
    if not ages then return nil, why or "save time unavailable" end
    local asUtc, asLocal = readAt - ages.utc, readAt - ages["local"]
    local readings = { utc = asUtc, ["local"] = asLocal }
    if world.timestampMode and readings[world.timestampMode] <= now + 60 then
        return readings[world.timestampMode], world.timestampMode
    end
    local fits = {}
    for mode, t in pairs(readings) do if t <= now + 60 then fits[#fits + 1] = { mode = mode, t = t } end end
    if #fits == 1 or math.abs(asUtc - asLocal) < 60 then return fits[1] and fits[1].t, fits[1] and fits[1].mode end
    if #fits == 0 then return nil, "save time is in the future" end
    if world.lastSeen then
        table.sort(fits, function(a, b) return math.abs(a.t - world.lastSeen) < math.abs(b.t - world.lastSeen) end)
        if math.abs(fits[1].t - world.lastSeen) < 12 * 3600 then
            world.timestampMode = fits[1].mode
            return fits[1].t, fits[1].mode
        end
    end
    return nil, "save time is ambiguous (UTC or local)"
end

-- Did the changes from the last catch-up make it into this save?
local function checkPersistence(bases, saveUnix)
    local last = world.lastApply
    if not last or last.checked then return end
    if not saveUnix then
        log("Save check: can't tell whether the last catch-up was saved (save time unknown).")
        return
    end
    last.checked = true
    if saveUnix < last.time then
        log("Save check: this save is from before the last catch-up, so the world was not saved after it "
            .. "(crash or older save). Catch-up runs again from this save's time.")
        return
    end
    local byId = {}
    for _, b in ipairs(bases) do byId[b.id] = b end
    local kept, lost, missing = 0, 0, {}
    for baseId, items in pairs(last.items or {}) do
        local b = byId[baseId]
        for item, e in pairs(items) do
            local now = b and (b.stocks[item] or 0) or 0
            local ok
            if e.wanted >= 0 then ok = now >= e.before + e.wanted / 2 else ok = now <= e.before + e.wanted / 2 end
            if ok then kept = kept + 1 else lost = lost + 1; missing[#missing + 1] = short(baseId) .. " " .. item end
        end
    end
    if kept + lost == 0 then return end
    log("Save check: %d of %d changes from the last catch-up are in this save.%s", kept, kept + lost,
        lost > 0 and (" Not found: " .. table.concat(missing, ", ") .. " (items used since then also show here).") or "")
    if lost > kept then enterSafeMode("most changes from the last catch-up were not in the save") end
end

-- Building the model for one base ---------------------------------------------------------

local function copyProc(p)
    local c = {}
    for k, v in pairs(p) do c[k] = v end
    c.inputs, c.outputs = {}, {}
    for k, v in pairs(p.inputs or {}) do c.inputs[k] = v end
    for k, v in pairs(p.outputs or {}) do c.outputs[k] = v end
    return c
end

-- Processes for one stretch of time: learned rates for that phase, crafting turned into
-- linked recipe chains with finite queues, and food spilling back into chests when the feed
-- box is full.
local function buildProcesses(bs, phase, base, stations, craftingLive)
    local procs, byId = {}, {}
    for _, p in ipairs(rates.processList(bs, cfg.minSamples, phase)) do
        local c = copyProc(p)
        procs[#procs + 1] = c
        byId[c.id] = c
    end

    local byProduct = {}
    for _, st in ipairs(stations or {}) do
        if st.toStorage then
            byProduct[st.product] = byProduct[st.product] or {}
            table.insert(byProduct[st.product], st)
        end
    end
    for product, list in pairs(byProduct) do
        local make = byId["make:" .. product]
        if make then
            -- The measured product and the materials it used are one linked process now,
            -- whether or not crafting is live (otherwise ore would vanish without ingots).
            make.dropped = true
            local rate = make.outputs[product] or 0
            local craftsPerHour = rate / math.max(1, list[1].perCraft)
            local inputs, infinite = {}, false
            for _, st in ipairs(list) do if st.infinite then infinite = true end end
            for m, n in pairs(list[1].materials) do
                inputs[m] = craftsPerHour * n
                local use = byId["use:" .. m]
                if use then use.inputs[m] = math.max(0, (use.inputs[m] or 0) - craftsPerHour * n) end
            end
            if not infinite then inputs[QUEUE .. product] = craftsPerHour end
            if craftingLive then
                procs[#procs + 1] = { id = "craft:" .. product, kind = "work", inputs = inputs, outputs = { [product] = rate } }
            end
        end
    end

    local make = byId["make:" .. FOOD]
    if make and not make.dropped then
        local inChests = {}
        for item in pairs(base.foodItems or {}) do
            if (base.stocks[item] or 0) > 0 then inChests[item] = true end
        end
        local shares = rates.shares(bs.foodAdded, inChests)
        if shares then
            local outputs = {}
            for item, s in pairs(shares) do outputs[item] = (make.outputs[FOOD] or 0) * s end
            procs[#procs + 1] = { id = "spill:" .. FOOD, kind = "work", spillOf = make.id, inputs = {}, outputs = outputs }
        end
    end

    local out = {}
    for _, p in ipairs(procs) do if not p.dropped then out[#out + 1] = p end end
    return out
end

-- Splits a whole number of food units across the feed box's items.
local function feedSplit(n, base, bs)
    if n == 0 then return {} end
    local present, total = {}, 0
    for item, c in pairs(base.foodItems or {}) do
        if c > 0 then present[item] = true; total = total + c end
    end
    local shares = rates.shares(n < 0 and bs.foodEaten or bs.foodAdded, present)
    if not shares then
        if total == 0 then return {} end
        shares = {}
        for item in pairs(present) do shares[item] = base.foodItems[item] / total end
    end
    return catchup.distribute(n, shares)
end

-- Catch-up --------------------------------------------------------------------------------

local loadTime = nil
local saveAgeAtLoad, saveAgeReadAt, saveAgeWhy = nil, nil, nil
local jobs = {}
local expeditionsByBase = {}

-- Expeditions and medical-bed revivals run on a clock that stops while the world is closed;
-- move their dates earlier by the downtime.
local function realProgress(seconds, live)
    expeditionsByBase = {}
    local timers = adapter.realProgressTimers()
    if #timers == 0 then return end
    local counts, failed, methods, firstErr = {}, 0, {}, nil
    for _, t in ipairs(timers) do
        counts[t.kind] = (counts[t.kind] or 0) + 1
        if live then
            local ok, method, err = adapter.shiftRealProgress(t, seconds)
            if ok then
                methods[method or "?"] = true
                if t.kind == "expedition" and t.baseId then
                    expeditionsByBase[t.baseId] = (expeditionsByBase[t.baseId] or 0) + 1
                end
            else
                failed = failed + 1
                firstErr = firstErr or err
            end
        end
    end
    local parts, used = {}, {}
    for kind, n in pairs(counts) do parts[#parts + 1] = ("%d %s(s)"):format(n, kind) end
    for m in pairs(methods) do used[#used + 1] = m end
    table.sort(parts)
    table.sort(used)
    log("Real-progress timers%s: %s moved %.2fh forward%s%s.", live and "" or " (dry run)", table.concat(parts, ", "),
        seconds / 3600, #used > 0 and (" (written by " .. table.concat(used, "/") .. ")") or "",
        failed > 0 and ("; %d didn't read back as moved: %s"):format(failed, tostring(firstErr)) or "")
end

local function clockSpec(c)
    if not c then return nil end
    return {
        hour = c.hour,
        dayStart = rates.get(world.time, "dayStart", 1),
        nightStart = rates.get(world.time, "nightStart", 1),
        rate = { day = rates.get(world.time, "day", 3), night = rates.get(world.time, "night", 3) },
    }
end

local function spoilage(gapHours, live)
    local k = rates.get(state.spoil, "k", 2)
    if not k then
        log("Spoilage: speed not measured yet; skipped.")
        return
    end
    local threshold = rates.get(state.spoil, "threshold", 2)
    local changed, spoiled = 0, 0
    for _, s in ipairs(adapter.spoilSlots()) do
        local delta = k * s.factor * s.mult * gapHours
        if delta > 0 then
            local limit = threshold or ((s.progress or 0) > 0.01 and s.value / s.progress) or nil
            local value = s.value + delta
            if limit and value >= limit then
                value = limit * 0.9999 -- the game finishes spoiling it on its next tick
                spoiled = spoiled + 1
            end
            changed = changed + 1
            if live then adapter.setSpoil(s.slot, value) end
        end
    end
    log("Spoilage%s: %d perishable stack(s) aged, %d would spoil.", live and "" or " (dry run)", changed, spoiled)
end

local function worldTime(clock, tl, live)
    if not tl then
        log("World time: clock speed or day/night hours not measured yet; skipped.")
        return
    end
    local plan = timeline.advancePlan(clockSpec(clock), tl)
    if not plan then return end
    local desc = ("day %d %05.2fh -> +%.1f in-game hours (%d dawn(s)), ends %05.2fh")
        :format(clock.day or 0, clock.hour, tl.gameHours, tl.dawns, tl.endHour)
    if not live then
        log("World time (dry run): %s%s.", desc, plan.exact and "" or ", reachable approximately")
        return
    end
    local ok, what = adapter.advanceClock(plan)
    log("World time: %s; %s%s.", desc, ok and what or ("not changed: " .. tostring(what)),
        plan.exact and "" or " (nearest whole hour)")
end

local ROUND_SECONDS = 2.5
local BREED_STALL_ROUNDS = 12 -- 30 s without the set-up egg being laid: its Pals stopped

-- Eggs a farm is owed for the time away, limited by its free egg space and its cake.
local function breedPlan(f, fedSeconds)
    local total = f.progress + fedSeconds * cfg.timerEfficiency
    local cycles = math.floor(total / f.required + 1e-6)
    local eggs = math.min(cycles, math.max(0, f.maxEggs - f.eggs))
    if f.cake then eggs = math.min(eggs, f.cake) end
    return eggs, math.max(0, total - cycles * f.required), total
end

-- Turns a farm into a breeding job: the first egg is set up nearly done and the game lays it.
-- Returns the job, or nil when there is nothing to lay (then just the progress moves on).
local function startBreeding(job, f, eggs, leftover, total)
    if eggs > 0 then
        adapter.setBreedProgress(f.ref, f.required - 0.5)
        job.kind, job.total, job.laid, job.waiting, job.waited = "breed", eggs, 0, true, 0
        job.leftover, job.eggsBefore = leftover, f.eggs
        return job
    end
    if total > f.progress then adapter.setBreedProgress(f.ref, math.min(total, f.required - 1)) end
    return nil
end

-- One breeding round: once the game has laid the egg that was set up, set up the next one.
-- Eggs only count (and go into the owner's summary) when the game actually lays them.
local function breedRound(job)
    local st = adapter.breedState(job.ref)
    if not st then return false end
    if job.waiting and (st.progress < st.required - 1 or st.eggs > job.eggsBefore) then
        job.laid = job.laid + 1
        job.waiting, job.waited, job.eggsBefore = false, 0, st.eggs
        for player in pairs(job.owners or {}) do
            summary.add(world.pending, player, job.baseId, job.name, { eggs = 1 })
        end
    end
    if job.waiting then
        job.waited = job.waited + 1
        if job.waited < BREED_STALL_ROUNDS then return true end
        log("  %s: breeding farm laid %d of %d egg(s); its Pals stopped breeding (cake left: %s).",
            short(job.baseId), job.laid, job.total, st.cake and tostring(st.cake) or "?")
        return false
    end
    if job.laid < job.total and st.eggs < st.maxEggs and st.cake ~= 0 then
        adapter.setBreedProgress(job.ref, st.required - 0.5)
        job.waiting = true
        return true
    end
    adapter.setBreedProgress(job.ref, math.min(job.leftover, st.required - 1))
    log("  %s: breeding farm laid %d of %d egg(s).", short(job.baseId), job.laid, job.total)
    return false
end

-- A farm with cake and room whose Pals weren't at it when catch-up ran: start it as soon as
-- they are (it can breed, or its progress moves), or give up after a while.
local function watchRound(job)
    local st = adapter.breedState(job.ref)
    if not st then return false end
    job.rounds = job.rounds + 1
    local waited = job.rounds * ROUND_SECONDS
    if st.canProceed or math.abs(st.progress - job.start) > 1e-3 then
        local f = { ref = job.ref, progress = st.progress, required = st.required, eggs = st.eggs,
                    maxEggs = st.maxEggs, cake = st.cake }
        local eggs, leftover, total = breedPlan(f, job.fedSeconds)
        log("  %s: breeding farm's Pals got back to it after %.0f s; laying %d egg(s).", short(job.baseId), waited, eggs)
        return startBreeding(job, f, eggs, leftover, total) ~= nil
    end
    if waited < cfg.breedWatchSeconds then return true end
    log("  %s: breeding farm's Pals didn't start within %.0f s; skipped.", short(job.baseId), waited)
    return false
end

local function runPasses(remaining, onDone)
    if remaining <= 0 or #jobs == 0 then
        for _, job in ipairs(jobs) do
            if job.kind == "breed" then
                log("  %s: breeding farm laid %d of %d egg(s); follow-up rounds ran out.",
                    short(job.baseId), job.laid, job.total)
            elseif job.kind == "breedWatch" then
                log("  %s: breeding farm's Pals didn't start before follow-up rounds ran out; skipped.", short(job.baseId))
            end
        end
        jobs = {}
        if onDone then onDone() end
        return
    end
    ExecuteWithDelay(math.floor(ROUND_SECONDS * 1000), function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                local still = {}
                for _, job in ipairs(jobs) do
                    if job.kind == "timer" then
                        -- The next job at that machine may take a moment to appear (and to show up
                        -- in the cached work list), so wait up to 16 rounds (40 s) for it.
                        local used = adapter.advanceNextAtOwner(job.owner, job.seconds, job.except)
                        job.seconds = job.seconds - used
                        job.waited = used > 0 and 0 or (job.waited or 0) + 1
                        if job.seconds > 1 and job.waited < 16 then still[#still + 1] = job end
                    elseif job.kind == "breed" then
                        if breedRound(job) then still[#still + 1] = job end
                    elseif job.kind == "breedWatch" then
                        if watchRound(job) then still[#still + 1] = job end
                    end
                end
                jobs = still
            end)
            if not ok then
                log("Follow-up round failed: %s", tostring(err))
                jobs = {}
            end
            runPasses(remaining - 1, onDone)
        end)
    end)
end

-- Progress recorded a few seconds after load, compared at catch-up time.
local baselineWork, baselineFarms = nil, nil

-- Was this self-running work seen moving, since load or during the last session?
local function provenFn()
    if not baselineWork then return nil end
    return function(id, amount)
        local b = baselineWork[id]
        if b and amount > b.amount + 1e-6 then return true end
        local seen = world.progressing[id]
        return seen ~= nil and os.time() - seen < 3 * 86400
    end
end

-- Is this breeding farm actually breeding? Its Pals may not be back at it yet right after
-- load, so its own "can breed" answer isn't enough on its own.
local function farmActive(f)
    if f.canProceed then return true, "working now" end
    local b = baselineFarms and baselineFarms[f.id]
    if b and f.progress ~= b then return true, "moving since load" end
    local rec = world.farms[f.id]
    if rec and rec.active then return true, "was working before you quit" end
    return false, nil
end

local function catchUpBases(seconds, tl, apply)
    local live = {}
    for k, v in pairs(cfg.live) do live[k] = apply and v end
    live.crafting = live.crafting and live.items

    local gapHours = seconds / 3600
    local stations = adapter.stations()
    local farms = adapter.breedFarms()
    local crops = adapter.crops()
    local applied = {}
    local unplacedAny = false
    local proven = provenFn()
    local skippedAll = {}
    local owners = {}
    pcall(function() owners = adapter.baseOwners() end)
    local recipients = {}

    for _, base in ipairs(adapter.listBases()) do
        local baseStart = clockMs()
        local id = base.id
        local bs = baseState(id)
        local here = stations[id] or {}

        local function phasesFor(withCrafting)
            local phases = {}
            if tl then
                for _, seg in ipairs(tl.segments) do
                    phases[#phases + 1] = { phase = seg.phase, hours = seg.hours,
                                            processes = buildProcesses(bs, seg.phase, base, here, withCrafting) }
                end
            else
                phases[1] = { hours = gapHours, processes = buildProcesses(bs, nil, base, here, withCrafting) }
            end
            return phases
        end
        local phases = phasesFor(live.crafting)

        local stocks, caps = {}, {}
        for k, v in pairs(base.stocks) do stocks[k] = v end
        for k, v in pairs(base.caps or {}) do caps[k] = v end
        local queueStart = {}
        for _, st in ipairs(here) do
            if not st.infinite then queueStart[st.product] = (queueStart[st.product] or 0) + st.remain end
        end
        for product, n in pairs(queueStart) do stocks[QUEUE .. product] = n end
        local trusted = 0
        for _, ph in ipairs(phases) do
            trusted = math.max(trusted, #ph.processes)
            for _, p in ipairs(ph.processes) do
                for item in pairs(p.outputs) do
                    if caps[item] == nil and base.defaultCap then caps[item] = base.defaultCap end
                end
            end
        end

        local opts = { efficiency = cfg.workEfficiency }
        local result = catchup.simulatePhased({ stocks = stocks, caps = caps }, phases, opts)
        local fedSeconds = result.fedHours * 3600
        local queuePattern = "^" .. QUEUE:gsub("%p", "%%%0") .. "(.+)$"
        local itemDeltas, crafts = {}, {}
        for item, d in pairs(result.deltas) do
            local product = item:match(queuePattern)
            if product then crafts[product] = math.floor(-d + 1e-6) else itemDeltas[item] = d end
        end
        -- Crafting not live: work out what it would have done, for the log only.
        if not live.crafting and next(here) then
            local preview = catchup.simulatePhased({ stocks = stocks, caps = caps }, phasesFor(true), opts)
            for item, d in pairs(preview.deltas) do
                local product = item:match(queuePattern)
                if product then crafts[product] = math.floor(-d + 1e-6) end
            end
        end
        local whole, carry = catchup.wholeItems(itemDeltas, bs.carry)
        local foodWhole = whole[FOOD] or 0
        whole[FOOD] = nil
        local feed = feedSplit(foodWhole, base, bs)

        -- Timers that need power only run while Pals were fed (they work the generators).
        local plain, powered = {}, {}
        local found, skipped = adapter.getTimers(id, proven)
        for _, t in ipairs(found) do
            table.insert(t.power and powered or plain, t)
        end
        for _, cls in ipairs(skipped) do skippedAll[cls] = (skippedAll[cls] or 0) + 1 end
        local timers = catchup.advanceTimers(plain, seconds * cfg.timerEfficiency)
        for _, t in ipairs(catchup.advanceTimers(powered, math.min(seconds, fedSeconds) * cfg.timerEfficiency)) do
            timers[#timers + 1] = t
        end
        local finished, hatched, machines = 0, 0, 0
        for _, t in ipairs(timers) do
            if t.done then
                finished = finished + 1
                if t.kind == "incubator" then hatched = hatched + 1 else machines = machines + 1 end
            end
        end
        local gains = { items = {}, crafts = {}, eaten = 0, hatched = 0, machines = 0, eggs = 0,
                        expeditions = expeditionsByBase[id] or 0 }

        if trusted > 0 or #timers > 0 or next(whole) or next(feed) then
            log("  %s: %d rate(s), %d timer(s) (%d finish), fed %.2f of %.2fh", short(id), trusted, #timers,
                finished, result.fedHours, result.hours)
            local reasons = {}
            for _, seg in ipairs(result.segments) do
                if seg.reason ~= "end" then reasons[#reasons + 1] = ("%.2fh %s"):format(seg.from + seg.hours, seg.reason) end
            end
            if #reasons > 0 then log("  %s: %s", short(id), table.concat(reasons, "; ")) end
            local all = {}
            for k, v in pairs(whole) do all[k] = v end
            for k, v in pairs(feed) do all["feed " .. k] = v end
            log("  %s: %s", short(id), describe(all))
        end

        -- Crafting queues
        for product, n in pairs(crafts) do
            if n > 0 then
                log("  %s: %d %s craft(s) finished from the queue%s", short(id), n, product, live.crafting and "" or " (dry run)")
                if live.crafting then
                    gains.crafts[product] = n
                    local left = n
                    for _, st in ipairs(here) do
                        if st.product == product and not st.infinite and left > 0 then
                            local take = math.min(left, st.remain)
                            adapter.applyStation(st, take)
                            left = left - take
                        end
                    end
                end
            end
        end

        -- Items, with an immediate read-back check
        if live.items and (next(whole) or next(feed)) then
            local before = base.stocks
            local leftovers = adapter.applyItemDeltas(id, whole, feed)
            bs.carry = carry
            local after = {}
            for _, b in ipairs(adapter.listBases()) do if b.id == id then after = b.stocks end end
            local record, bad = {}, {}
            for item, n in pairs(whole) do
                local placed = n - (leftovers[item] or 0)
                local expect = (before[item] or 0) + placed
                if (after[item] or 0) ~= expect then bad[#bad + 1] = ("%s %d, expected %d"):format(item, after[item] or 0, expect) end
                if placed ~= 0 then record[item] = { before = before[item] or 0, wanted = placed } end
                if placed > 0 then gains.items[item] = placed end
                log("  %s: %s %d -> %d (wanted %+d)", short(id), item, before[item] or 0, after[item] or 0, n)
            end
            local feedPlaced = 0
            for item, n in pairs(feed) do
                local placed = n - (leftovers[FOOD .. ":" .. item] or 0)
                feedPlaced = feedPlaced + placed
                if placed > 0 then gains.items[item] = (gains.items[item] or 0) + placed end
                if placed < 0 then gains.eaten = gains.eaten - placed end
            end
            if next(feed) then
                local expect = (before[FOOD] or 0) + feedPlaced
                if (after[FOOD] or 0) ~= expect then bad[#bad + 1] = ("food %d, expected %d"):format(after[FOOD] or 0, expect) end
                if feedPlaced ~= 0 then record[FOOD] = { before = before[FOOD] or 0, wanted = feedPlaced } end
                log("  %s: food %d -> %d (wanted %+d)", short(id), before[FOOD] or 0, after[FOOD] or 0, foodWhole)
            end
            if #bad > 0 then
                enterSafeMode(("storage at base %s didn't read back as written (%s)"):format(short(id), table.concat(bad, "; ")))
                return applied, true
            end
            if next(record) then applied[id] = record end
            for item, n in pairs(leftovers) do
                bs.unplaced[item] = (bs.unplaced[item] or 0) + n
                unplacedAny = true
            end
            if next(leftovers) then log("  %s: no room / not enough for %s", short(id), describe(leftovers)) end
        end

        -- Timers
        if live.timers and #timers > 0 then
            adapter.applyTimers(id, timers)
            gains.hatched, gains.machines = hatched, machines
            for _, t in ipairs(timers) do
                if t.done and t.owner and t.leftover > 1 then
                    jobs[#jobs + 1] = { kind = "timer", owner = t.owner, seconds = t.leftover, except = { [t.id] = true } }
                end
            end
        end

        -- Breeding farms: the game lays every egg itself, one set up at a time, so cake and egg
        -- space are used as they normally would be.
        local breeding = 0
        for _, f in ipairs(farms[id] or {}) do
            local active, why = farmActive(f)
            log("  %s: breeding farm at %.1f of %.0f s, %d of %d egg(s) waiting, cake %s, can breed now: %s, Pals that bred here: %s",
                short(id), f.progress, f.required, f.eggs, f.maxEggs, f.cake and tostring(f.cake) or "?",
                tostring(f.canProceed), f.breeders and tostring(f.breeders) or "?")
            if f.required <= 0 then
                log("  %s: breeding farm has no breeding time set, skipped", short(id))
            elseif f.eggs >= f.maxEggs then
                log("  %s: breeding farm is full of eggs, skipped", short(id))
            elseif f.cake == 0 then
                log("  %s: breeding farm has no cake, skipped", short(id))
            elseif not active then
                log("  %s: breeding farm's Pals aren't at it yet; watching it for up to %d s%s", short(id),
                    cfg.breedWatchSeconds, live.breeding and "" or " (dry run)")
                if live.breeding then
                    breeding = breeding + 1
                    jobs[#jobs + 1] = { kind = "breedWatch", baseId = id, id = f.id, ref = f.ref, start = f.progress,
                                        fedSeconds = fedSeconds, rounds = 0 }
                end
            else
                local eggs, leftover, total = breedPlan(f, fedSeconds)
                log("  %s: breeding farm would lay %d egg(s) (%s)%s", short(id), eggs, why, live.breeding and "" or " (dry run)")
                if live.breeding then
                    local job = startBreeding({ baseId = id, id = f.id, ref = f.ref }, f, eggs, leftover, total)
                    if job then
                        breeding = breeding + 1
                        jobs[#jobs + 1] = job
                    end
                end
            end
        end

        -- Pal hunger and sanity
        local decline = rates.get(bs.needs, "decline", 3)
        local drift = rates.get(bs.needs, "drift", 3)
        local hungry = math.max(0, result.hours - result.fedHours)
        if (decline and hungry > 0) or drift then
            local n = 0
            for _, w in pairs(adapter.workers(id)) do
                local stomach = (decline and hungry > 0) and math.max(0, w.stomach - decline * hungry) or nil
                local sanity = drift and math.max(0, math.min(100, w.sanity + drift * gapHours)) or nil
                if live.palNeeds then adapter.setPalNeeds(w.ref, stomach, sanity) end
                n = n + 1
            end
            if n > 0 then
                log("  %s: %d Pal(s): hungry %.2fh (stomach -%.0f), sanity %+.1f%s", short(id), n, hungry,
                    (decline or 0) * hungry, (drift or 0) * gapHours, live.palNeeds and "" or " (dry run)")
            end
        end

        -- Crop plots keep growing (harvests themselves come from the learned rates)
        local grown = 0
        for _, c in ipairs(crops[id] or {}) do
            local r = rates.get(world.crops, c.crop, 2)
            if c.growing and r then
                grown = grown + 1
                if live.crops then adapter.setCropProgress(c.ref, (c.progress + r * gapHours) % 1) end
            end
        end
        if grown > 0 then log("  %s: %d crop plot(s) grown%s", short(id), grown, live.crops and "" or " (dry run)") end

        -- Remember what this base gained for its owner's summary. Shared storage goes to the
        -- owners of the bases that share it.
        local who = {}
        if base.shared then
            for baseId in pairs(base.sharedBy or {}) do
                local o = owners[baseId] and owners[baseId].owner
                if o then who[o] = true end
            end
        elseif owners[id] and owners[id].owner then
            who[owners[id].owner] = true
        end
        local name = base.shared and "Shared storage" or (owners[id] and owners[id].name) or nil
        for _, job in ipairs(jobs) do
            if (job.kind == "breed" or job.kind == "breedWatch") and job.baseId == id and not job.owners then
                job.owners, job.name = who, name
            end
        end
        local any = next(gains.items) or next(gains.crafts) or gains.eaten > 0 or gains.hatched > 0 or gains.machines > 0
            or gains.eggs > 0 or gains.expeditions > 0 or breeding > 0
        if any then
            if next(who) == nil then log("  %s: owner unknown, so it isn't in anyone's summary", short(id)) end
            for player in pairs(who) do
                summary.add(world.pending, player, id, name, gains)
                recipients[player] = true
            end
        end
        record("per base", clockMs() - baseStart)
    end
    summary.addHours(world.pending, recipients, gapHours)
    if next(skippedAll) then
        local parts = {}
        for cls, n in pairs(skippedAll) do parts[#parts + 1] = ("%dx %s"):format(n, cls) end
        table.sort(parts)
        log("Skipped self-running jobs that weren't progressing (empty or idle): %s", table.concat(parts, ", "))
    end
    if unplacedAny then log("Some items had no room; totals so far are kept per base in state.lua (unplaced).") end
    return applied
end

-- Summaries --------------------------------------------------------------------------------

local seenLastCheck = {}
local MAX_SEND_TRIES = 3

-- Shows each player in the world their own pending summary: a private system chat message
-- per base plus pickup popups for their biggest gains. With requireSeen, a player must have
-- been in the world at the previous check too, so nothing is sent while they're still loading.
-- Sends one player their pending summary: a chat message per base plus pickup popups.
local MESSAGE_GAP_MS = 600 -- between a summary's chat messages, so they arrive in order

local function deliverTo(p)
    local entry = world.pending[p.key]
    if not entry then return end
    local blocks, top = summary.format(entry, adapter.itemName, cfg.summary.maxItemsPerBase)
    if not blocks then
        world.pending[p.key] = nil
        return
    end
    local messages = summary.messages(blocks, cfg.summary.maxLinesPerMessage)
    local style, styleErr = nil, nil
    local ok, err = pcall(function()
        style, styleErr = adapter.sendChat(messages[1], { p.uid }, cfg.summary.chatStyle, cfg.summary.sender)
        for i, t in ipairs(top) do
            if i > (cfg.summary.popups or 0) then break end
            adapter.itemPopup(p.state, t.item, math.floor(t.n), 0.4 * (i - 1))
        end
    end)
    if ok then
        -- Messages sent at the same moment can show up in any order; space out the rest.
        for i = 2, #messages do
            ExecuteWithDelay(MESSAGE_GAP_MS * (i - 1), function()
                ExecuteInGameThread(function()
                    local okM, errM = pcall(adapter.sendChat, messages[i], { p.uid }, cfg.summary.chatStyle, cfg.summary.sender)
                    if not okM then log("Couldn't send part %d of player %s's summary: %s", i, short(p.key), tostring(errM)) end
                end)
            end)
        end
        log("Summary shown to player %s (%s chat, %d message(s)):", short(p.key), tostring(style), #messages)
        if styleErr then log("  (player-style chat failed, used system chat: %s)", styleErr) end
        for _, block in ipairs(blocks) do
            for _, line in ipairs(block) do log("  | %s", line) end
        end
        world.pending[p.key] = nil
    else
        entry.tries = (entry.tries or 0) + 1
        log("Couldn't show player %s their summary (try %d of %d): %s", short(p.key), entry.tries,
            MAX_SEND_TRIES, tostring(err))
        if entry.tries >= MAX_SEND_TRIES then world.pending[p.key] = nil end
    end
    saveState()
end

-- Shows summaries to players in the world. With requireSeen, a player must have been in the
-- world at the previous check too (the once-a-minute fallback).
local function deliver(requireSeen)
    if not (cfg.summary and cfg.summary.enabled) or not world or not world.pending then return end
    local seenNow = {}
    for _, p in ipairs(adapter.players()) do
        seenNow[p.key] = true
        if world.pending[p.key] and (not requireSeen or seenLastCheck[p.key]) then deliverTo(p) end
    end
    seenLastCheck = seenNow
end

-- Every few seconds: a player who just joined gets their summary shortly after their
-- character appears (they've finished loading), or after a longer wait if that can't be seen.
local joining = {}
local function checkJoins()
    if not active or not world or not (cfg.summary and cfg.summary.enabled) then return end
    if not next(world.pending or {}) then
        joining = {} -- nobody has a summary waiting: nothing to look up
        return
    end
    local now, present = os.time(), {}
    for _, p in ipairs(adapter.players()) do
        present[p.key] = true
        local j = joining[p.key]
        if not j then
            j = { first = now }
            joining[p.key] = j
        end
        if not j.ready and adapter.playerInWorld(p) then j.ready = now end
        local due = (j.ready and now - j.ready >= (cfg.summary.joinDelaySeconds or 5))
            or now - j.first >= (cfg.summary.maxJoinWaitSeconds or 45)
        if due and world.pending[p.key] then deliverTo(p) end
    end
    for key in pairs(joining) do
        if not present[key] then joining[key] = nil end -- left; a rejoin starts over
    end
end

local function runCatchup()
    selectWorld(adapter.worldId())
    log("World %s. Scan: %s", worldKey, (function()
        local ok, s = pcall(timed, "scan", adapter.describe)
        return ok and s or ("failed: " .. tostring(s))
    end)())

    local ages, readAt, why = saveAgeAtLoad, saveAgeReadAt, saveAgeWhy
    if not ages then
        ages, why = adapter.saveAge()
        readAt = os.time()
    end
    local saveUnix, mode = resolveSaveTime(ages, readAt, loadTime, why)
    if not saveUnix then log("Save timestamp not used: %s.", tostring(mode)) end
    local reference, source
    if saveUnix then
        reference, source = saveUnix, ("the save's timestamp (%s)"):format(mode)
    elseif world.lastSaveTime then
        reference, source = world.lastSaveTime, ("the last save the mod saw finish (save timestamp: %s)"):format(tostring(mode))
    else
        reference, source = world.lastSeen, ("the last heartbeat (save timestamp: %s)"):format(tostring(mode))
    end
    local seconds, note = catchup.elapsedSeconds(reference, loadTime, cfg)
    if note then log(note) end
    if reference then log("Offline %.2fh, measured from %s.", math.max(0, loadTime - reference) / 3600, source) end

    timed("save check", function() checkPersistence(adapter.listBases(), saveUnix or world.lastSaveTime) end)
    if seconds <= 0 then return end

    local apply = versionOk() and not cfg.dryRun and not state.safeMode
    if state.safeMode then log("In safe mode (%s); dry run only.", tostring(state.safeMode.reason)) end
    log("Catching up %.2f hours%s.", seconds / 3600, apply and "" or " (dry run)")

    local clock = adapter.clock()
    local tl = timeline.split(seconds / 3600, clockSpec(clock))
    if tl then
        local parts = {}
        for _, s in ipairs(tl.segments) do parts[#parts + 1] = ("%s %.2fh"):format(s.phase, s.hours) end
        log("Day/night: %s.", table.concat(parts, ", "))
    end

    timed("spoilage", spoilage, seconds / 3600, apply and cfg.live.spoilage)
    timed("world time", worldTime, clock, tl, apply and cfg.live.worldTime)
    timed("expeditions", realProgress, seconds, apply and cfg.live.expeditions)
    log("Timing (load): %s.", timingReport({ "scan", "save check", "spoilage", "world time", "expeditions" }))

    -- Let spoiled stacks turn over before storage is read for the item catch-up.
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            local ok, result, aborted = pcall(timed, "catch-up", catchUpBases, seconds, tl, apply)
            if not ok then
                log("Catch-up stopped early: %s", tostring(result))
            else
                if next(result) then world.lastApply = { time = os.time(), items = result } end
                if aborted then
                    log("Catch-up stopped at the first base that didn't read back correctly.")
                elseif next(result) then
                    adapter.notify(("World was offline %.1fh; bases caught up."):format(seconds / 3600))
                end
            end
            timed("save state", saveState)
            log("Timing (catch-up): %s.", timingReport({ "catch-up", "per base", "save state" }))
            -- Whoever is already in the world (the host) gets their summary once the follow-up
            -- rounds (eggs, next jobs) are done, so it only lists what actually happened.
            runPasses(cfg.maxCatchupPasses, function()
                ExecuteWithDelay(5000, function()
                    ExecuteInGameThread(function()
                        local ok, err = pcall(timed, "summary", deliver, false)
                        if not ok then log("Summary failed: %s", tostring(err)) end
                        log("Timing (summary): %s.", timingReport({ "summary" }))
                        saveState()
                    end)
                end)
            end)
        end)
    end)
end

-- Heartbeat and measuring -------------------------------------------------------------------

local prevSnap, lastClock = nil, nil
local prevWork, prevFarms = nil, nil

-- Which self-running work and breeding farms actually moved since the last measurement, so
-- catch-up only advances things that were really working.
local function sampleProgress()
    local now = os.time()
    local amounts = adapter.workAmounts()
    if prevWork then
        for id, a in pairs(amounts) do
            local p = prevWork[id]
            if p and a.amount > p.amount + 1e-6 then world.progressing[id] = now end
        end
    end
    prevWork = amounts
    for id, t in pairs(world.progressing) do
        if now - t > 3 * 86400 then world.progressing[id] = nil end
    end
    local farmsNow = {}
    for _, list in pairs(adapter.breedFarms()) do
        for _, f in ipairs(list) do
            farmsNow[f.id] = f.progress
            if prevFarms and prevFarms[f.id] ~= nil then
                world.farms[f.id] = { active = f.canProceed or f.progress ~= prevFarms[f.id], at = now }
            end
        end
    end
    prevFarms = farmsNow
end
local windowMeta, windowPhase, windowPhaseMixed, sinceSample = {}, nil, false, 0
local prevCrops = nil

local function resetWindow()
    windowMeta, windowPhase, windowPhaseMixed, sinceSample = {}, nil, false, 0
end

local function sampleClock()
    local c = adapter.clock()
    if not c then return nil end
    c.t = os.time()
    if lastClock then
        local realHours = (c.t - lastClock.t) / 3600
        local gameHours = (c.hour - lastClock.hour) % 24
        if realHours > 0 and c.phase and c.phase == lastClock.phase and gameHours > 0 then
            local r = gameHours / realHours
            local prev = rates.get(world.time, c.phase, 1)
            if not prev or (r < prev * 3 and r > prev / 3) then rates.scalar(world.time, c.phase, r, 0.3) end
        elseif c.phase and lastClock.phase and c.phase ~= lastClock.phase then
            local mid = (lastClock.hour + ((c.hour - lastClock.hour) % 24) / 2) % 24
            rates.scalar(world.time, c.phase == "day" and "dayStart" or "nightStart", mid, 0.3)
        end
    end
    lastClock = c
    return c
end

local function sampleCrops(hours)
    local now = {}
    for _, list in pairs(adapter.crops()) do
        for _, c in ipairs(list) do now[c.id] = { crop = c.crop, growing = c.growing, progress = c.progress } end
    end
    if prevCrops and hours > 0 then
        for id, c in pairs(now) do
            local p = prevCrops[id]
            if p and p.crop == c.crop and p.growing and c.growing and c.progress > p.progress then
                rates.scalar(world.crops, c.crop, (c.progress - p.progress) / hours, cfg.rateSmoothing)
            end
        end
    end
    prevCrops = now
end

local function sample(windowSeconds)
    local snap = adapter.snapshot()
    if prevSnap then
        local allClean, allFar = true, true
        for _, m in pairs(windowMeta) do
            allClean = allClean and m.clean
            allFar = allFar and m.far
        end
        local meta = {}
        for id in pairs(snap.bases) do
            meta[id] = windowMeta[id] or (id:match("^shared:") and { clean = allClean, far = allFar }) or { clean = false }
        end
        local known = {}
        for id, bs in pairs(world.bases) do known[id] = bs.processes end
        local phase = (not windowPhaseMixed) and windowPhase or nil
        local res = observe.compare(prevSnap, snap, windowSeconds, meta, phase, known)
        for _, o in ipairs(res.obs) do
            rates.observe(baseState(o.baseId), o.processId, o.kind, o.inputs, o.outputs, windowSeconds,
                cfg.rateSmoothing, o.tags)
        end
        for id, n in pairs(res.needs) do
            local bs = baseState(id)
            if n.decline then rates.scalar(bs.needs, "decline", n.decline, cfg.rateSmoothing) end
            if n.drift then rates.scalar(bs.needs, "drift", n.drift, cfg.rateSmoothing) end
        end
        for id, m in pairs(res.mix) do
            local bs = baseState(id)
            rates.mix(bs.foodEaten, m.eaten, cfg.rateSmoothing)
            rates.mix(bs.foodAdded, m.added, cfg.rateSmoothing)
        end
        for _, s in ipairs(res.spoil) do
            rates.scalar(state.spoil, "k", s.k, cfg.rateSmoothing)
            if s.threshold then rates.scalar(state.spoil, "threshold", s.threshold, cfg.rateSmoothing) end
        end
        log("Measured %d item change(s) over the last %d min%s.", #res.obs, windowSeconds // 60,
            phase and (" (" .. phase .. ")") or "")
    end
    prevSnap = snap
    sampleCrops(windowSeconds / 3600)
    local okP, errP = pcall(sampleProgress)
    if not okP then log("Progress sampling failed: %s", tostring(errP)) end
end

local function tick()
    if not active or not world then return end
    world.lastSeen = os.time()
    local c = sampleClock()
    if c and c.phase then
        if windowPhase == nil then windowPhase = c.phase elseif windowPhase ~= c.phase then windowPhaseMixed = true end
    else
        windowPhaseMixed = true
    end
    local presence, threshold = adapter.presence()
    for id, p in pairs(presence) do
        local m = windowMeta[id] or { clean = true, far = true }
        if p.inside then m.clean = false end
        if not threshold or not p.distance or p.distance < threshold then m.far = false end
        windowMeta[id] = m
    end
    local okDeliver, errDeliver = pcall(deliver, true)
    if not okDeliver then log("Summary failed: %s", tostring(errDeliver)) end
    sinceSample = sinceSample + cfg.heartbeatSeconds
    if sinceSample >= cfg.sampleSeconds then
        local window = sinceSample
        local ok, err = pcall(timed, "measuring", sample, window)
        if not ok then log("Rate sampling failed: %s", tostring(err)) end
        resetWindow()
        log("Timing (last %d min): %s.", window // 60, timingReport({ "heartbeat", "join check", "measuring" }))
    end
    saveState()
end

local loopStarted = false
local function startHeartbeat()
    if loopStarted then return end
    loopStarted = true
    LoopAsync(math.floor((cfg.summary and cfg.summary.joinCheckSeconds or 5) * 1000), function()
        ExecuteInGameThread(function()
            local ok, err = pcall(timed, "join check", checkJoins)
            if not ok then log("Join check failed: %s", tostring(err)) end
        end)
        return false -- keep looping
    end)
    LoopAsync(math.floor(cfg.heartbeatSeconds * 1000), function()
        ExecuteInGameThread(function()
            local ok, err = pcall(timed, "heartbeat", tick)
            if not ok then log("Heartbeat failed: %s", tostring(err)) end
        end)
        return false -- keep looping
    end)
end

-- Hooks ------------------------------------------------------------------------------------

-- The game state is also created for the title screen; only the real world counts.
local function isMainWorld(gameState)
    local ok, name = pcall(function() return gameState:GetFullName() end)
    return ok and type(name) == "string" and name:find("MainWorld", 1, true) ~= nil
end

-- Only the host (co-op host or dedicated server) owns the bases.
local function isHost(gameState)
    local ok, result = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):IsServer(gameState)
    end)
    if not ok then
        log("Couldn't tell whether this game is the host; assuming it is.")
        return true
    end
    return result
end

local loadedOnce = false

-- The game state handed to the load hook only half-works from Lua (reading its player list and
-- calling its functions fail), which forced slow full searches every few seconds. Look up the
-- real one once per load instead.
local function realGameState(fallback)
    for _, name in ipairs({ "PalGameStateInGame", "BP_PalGameStateInGame_C" }) do
        for _, gs in ipairs(FindAllOf(name) or {}) do
            local ok, usable = pcall(function() return gs:IsValid() and isMainWorld(gs) end)
            if ok and usable then return gs end
        end
    end
    return fallback
end

-- Backup reference time: when the game finishes writing the world save, remember it.
do
    local ok, err = pcall(function()
        RegisterHook("/Script/Pal.PalSaveGameManager:OnFinishedWorldAsyncSaveGameInternal",
            function(_, _, _, success)
                local saved = true
                pcall(function() saved = success:get() end)
                if saved and active and world then
                    world.lastSaveTime = os.time()
                    saveState()
                end
            end)
    end)
    if not ok then log("Couldn't watch for world saves (%s); using the save timestamp and heartbeat only.", tostring(err)) end
end

RegisterInitGameStatePostHook(function(context)
    local gameState = context:get()
    if not isMainWorld(gameState) then
        -- Back at the title screen: stop measuring until a world is loaded again.
        if active then saveState() end
        active, world, worldKey, prevSnap, lastClock, prevCrops = false, nil, nil, nil, nil, nil
        prevWork, prevFarms = nil, nil
        resetWindow()
        loadedOnce = false
        return
    end
    if loadedOnce then return end
    loadedOnce = true
    if not isHost(gameState) then
        log("Joined someone else's world; staying idle.")
        return
    end
    loadTime = os.time()
    adapter.setGameState(gameState)
    saveAgeAtLoad, saveAgeWhy = nil, nil
    pcall(function() saveAgeAtLoad, saveAgeWhy = adapter.saveAge() end)
    saveAgeReadAt = os.time()
    -- A few seconds in, note how far each machine and breeding farm has got; catch-up compares
    -- against this to see what is really running.
    baselineWork, baselineFarms = nil, nil
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                local work = adapter.workAmounts()
                local farms = {}
                for _, list in pairs(adapter.breedFarms()) do
                    for _, f in ipairs(list) do farms[f.id] = f.progress end
                end
                baselineWork, baselineFarms = work, farms
                -- The first 10-minute measurement compares against this, so one is enough.
                prevWork, prevFarms = prevWork or work, prevFarms or farms
            end)
            if not ok then log("Couldn't note progress after load: %s", tostring(err)) end
        end)
    end)
    jobs = {}
    ExecuteWithDelay(math.floor(cfg.startupDelaySeconds * 1000), function()
        ExecuteInGameThread(function()
            pcall(function() adapter.setGameState(realGameState(gameState)) end)
            local ok, err = pcall(runCatchup)
            if not ok then log("Catch-up stopped early: %s", tostring(err)) end
            if not world then selectWorld(adapter.worldId()) end
            active = true
            saveState()
            startHeartbeat()
        end)
    end)
end)

-- After a UE4SS hot reload (Ctrl+R) the world is already loaded and no load hook will fire;
-- attach to it so measuring and summaries carry on (no catch-up, the world never stopped).
ExecuteWithDelay(2000, function()
    ExecuteInGameThread(function()
        if active or loadedOnce then return end
        local ok, err = pcall(function()
            for _, name in ipairs({ "PalGameStateInGame", "BP_PalGameStateInGame_C" }) do
                for _, gs in ipairs(FindAllOf(name) or {}) do
                    if gs:IsValid() and isMainWorld(gs) and isHost(gs) then
                        loadedOnce = true
                        adapter.setGameState(gs)
                        selectWorld(adapter.worldId())
                        active = true
                        saveState()
                        startHeartbeat()
                        log("Attached to the world that was already running (mods reloaded); no catch-up.")
                        return
                    end
                end
            end
        end)
        if not ok then log("Couldn't attach to the running world: %s", tostring(err)) end
    end)
end)

log("OfflineProgress %s loaded (target Palworld %s, %s%s).", MOD_VERSION, cfg.targetGameVersion,
    cfg.dryRun and "dry run" or "live",
    state.safeMode and ", SAFE MODE" or "")

-- Offline catch-up math. Pure Lua with no UE4SS calls, so it can be tested outside the game.
--
-- A base is modelled as stocks of items plus processes that move items at per-hour rates:
--
--   base = {
--     stocks    = { wood = 300, food = 50, ore = 0 },
--     caps      = { wood = 999 },                      -- missing item = unlimited
--     processes = {
--       { id = "logging", kind = "work",   inputs = {},          outputs = { wood = 120 } },
--       { id = "smelt",   kind = "work",   inputs = { ore = 40 }, outputs = { ingot = 20 } },
--       { id = "eat",     kind = "upkeep", inputs = { food = 60 }, outputs = {} },
--     },
--   }
--
-- "work" processes slow down when upkeep (Pals eating) can't be met; "upkeep" ones don't.
-- A process with spillOf = "<id>" picks up whatever that process can't deliver because its
-- output is full (e.g. food that no longer fits in the feed box stays in chests instead).
-- A finite job (a crafting queue) is an input item such as "__queue:smelt" whose stock is the
-- number of crafts left, so the queue simply runs out like any other input.
--
-- Instead of replaying ticks, the gap is split into segments at each point where a rate
-- changes (an input runs out, a storage fills) and each segment is solved in closed form.

local M = {}

local EPS = 1e-6

local function copy(t)
    local r = {}
    for k, v in pairs(t or {}) do r[k] = v end
    return r
end

-- How fast each process runs this segment, from 0 (stopped) to 1 (full measured rate),
-- plus how well upkeep was met (1 = Pals fully fed).
local function solveScales(procs, stocks, caps, efficiency)
    local act, scale, index = {}, {}, {}
    for i, p in ipairs(procs) do
        act[i] = 1
        if p.id then index[p.id] = i end
    end

    local upkeep, hasUpkeep = 1, false
    local function computeScales()
        upkeep, hasUpkeep = 1, false
        for i, p in ipairs(procs) do
            if p.kind == "upkeep" then
                hasUpkeep = true
                upkeep = math.min(upkeep, act[i])
            end
        end
        local fed = hasUpkeep and upkeep or 1
        for i, p in ipairs(procs) do
            if p.kind == "upkeep" then
                scale[i] = act[i]
            elseif not p.spillOf then
                scale[i] = act[i] * efficiency * fed
            end
        end
        for i, p in ipairs(procs) do
            if p.spillOf then
                local j = index[p.spillOf]
                local potential = 0
                if j then potential = procs[j].kind == "upkeep" and 1 or efficiency * fed end
                scale[i] = act[i] * math.max(0, potential - (j and scale[j] or 0))
            end
        end
    end

    local function flows()
        local prod, cons = {}, {}
        for i, p in ipairs(procs) do
            for item, r in pairs(p.outputs or {}) do prod[item] = (prod[item] or 0) + r * scale[i] end
            for item, r in pairs(p.inputs or {}) do cons[item] = (cons[item] or 0) + r * scale[i] end
        end
        return prod, cons
    end

    -- Throttle until every empty item has consumption <= production and every full item
    -- has production <= consumption. Activities only ever shrink, so this settles quickly.
    for _ = 1, 200 do
        computeScales()
        local prod, cons = flows()
        local changed = false

        for item, c in pairs(cons) do
            local p = prod[item] or 0
            if (stocks[item] or 0) <= EPS and c > p + EPS then
                for i, proc in ipairs(procs) do
                    if proc.inputs and proc.inputs[item] then act[i] = act[i] * (p / c) end
                end
                changed = true
                break
            end
        end

        if not changed then
            for item, p in pairs(prod) do
                local c, cap = cons[item] or 0, caps[item]
                if cap and (stocks[item] or 0) >= cap - EPS and p > c + EPS then
                    for i, proc in ipairs(procs) do
                        if proc.outputs and proc.outputs[item] then act[i] = act[i] * (c / p) end
                    end
                    changed = true
                    break
                end
            end
        end

        if not changed then break end
    end

    computeScales()
    return scale, hasUpkeep and upkeep or 1
end

-- Runs `base` forward by `hours`. opts.efficiency scales work processes (default 1).
-- Result: stocks, deltas, segments (each with the upkeep level), hours, fedHours.
function M.simulate(base, hours, opts)
    opts = opts or {}
    local efficiency = opts.efficiency or 1
    local procs = base.processes or {}
    local caps = base.caps or {}
    local stocks = copy(base.stocks)
    local segments = {}
    local t, fedHours = 0, 0

    for _ = 1, (opts.maxSegments or 1000) do
        if hours - t <= EPS then break end

        local scale, upkeep = solveScales(procs, stocks, caps, efficiency)
        local net = {}
        for i, p in ipairs(procs) do
            for item, r in pairs(p.outputs or {}) do net[item] = (net[item] or 0) + r * scale[i] end
            for item, r in pairs(p.inputs or {}) do net[item] = (net[item] or 0) - r * scale[i] end
        end

        local dt, reason = hours - t, "end"
        for item, r in pairs(net) do
            local s = stocks[item] or 0
            if r < -EPS and s > EPS then
                local hit = s / -r
                if hit < dt then dt, reason = hit, item .. " ran out" end
            elseif r > EPS and caps[item] and s < caps[item] - EPS then
                local hit = (caps[item] - s) / r
                if hit < dt then dt, reason = hit, item .. " storage full" end
            end
        end

        for item, r in pairs(net) do
            local s = (stocks[item] or 0) + r * dt
            if s < EPS then s = 0 end
            if r > EPS and caps[item] and s > caps[item] - EPS then s = caps[item] end
            stocks[item] = s
        end

        local scales = {}
        for i, p in ipairs(procs) do scales[p.id or i] = scale[i] end
        segments[#segments + 1] = { from = t, hours = dt, reason = reason, scales = scales, upkeep = upkeep }
        fedHours = fedHours + dt * upkeep
        t = t + dt
    end

    local deltas = {}
    for item, s in pairs(stocks) do
        local d = s - ((base.stocks or {})[item] or 0)
        if math.abs(d) > EPS then deltas[item] = d end
    end
    return { stocks = stocks, deltas = deltas, segments = segments, hours = t, fedHours = fedHours }
end

-- Runs several stretches back to back, each with its own processes (day and night rates),
-- carrying stocks from one to the next. phases = { { phase = "day", hours = 2, processes = {...} }, ... }
function M.simulatePhased(base, phases, opts)
    local stocks = copy(base.stocks)
    local segments, hours, fedHours = {}, 0, 0
    for _, ph in ipairs(phases) do
        local r = M.simulate({ stocks = stocks, caps = base.caps, processes = ph.processes }, ph.hours, opts)
        for _, seg in ipairs(r.segments) do
            seg.from = seg.from + hours
            seg.phase = ph.phase
            segments[#segments + 1] = seg
        end
        stocks = r.stocks
        hours = hours + r.hours
        fedHours = fedHours + r.fedHours
    end
    local deltas = {}
    for item, s in pairs(stocks) do
        local d = s - ((base.stocks or {})[item] or 0)
        if math.abs(d) > EPS then deltas[item] = d end
    end
    return { stocks = stocks, deltas = deltas, segments = segments, hours = hours, fedHours = fedHours }
end

-- Seconds of downtime to catch up, after sanity checks. Returns seconds and an optional note.
function M.elapsedSeconds(lastSeen, now, cfg)
    if not lastSeen then return 0, "No reference time for this world; nothing to catch up." end
    local gap = now - lastSeen
    if gap < 0 then return 0, "Clock went backwards; skipping catch-up." end
    if gap < (cfg.minGapSeconds or 0) then return 0, nil end
    local cap = (cfg.maxCatchupHours or 24) * 3600
    if gap > cap then
        return cap, ("World was offline %.1fh; capping catch-up at %.1fh."):format(gap / 3600, cap / 3600)
    end
    return gap, nil
end

-- Splits fractional deltas into whole items to apply now and a remainder to carry forward,
-- so 0.4 wood per restart isn't lost forever.
function M.wholeItems(deltas, carry)
    local whole, rest = {}, copy(carry)
    for item, d in pairs(deltas) do
        local total = d + (rest[item] or 0)
        local n = total >= 0 and math.floor(total + EPS) or math.ceil(total - EPS)
        if n ~= 0 then whole[item] = n end
        rest[item] = total - n
    end
    return whole, rest
end

-- Timers (incubators, breeding) store time remaining; subtract the gap. `leftover` is the
-- part of the gap after the timer finished, for whatever comes next in line.
function M.advanceTimers(timers, seconds)
    local out = {}
    for _, tm in ipairs(timers or {}) do
        local left = tm.remaining - seconds
        out[#out + 1] = { id = tm.id, remaining = math.max(0, left), done = left <= 0,
                          leftover = math.max(0, -left), owner = tm.owner, power = tm.power, kind = tm.kind }
    end
    return out
end

-- Splits an amount across items by share, in whole units, with rounding error going to the
-- largest share so the total always matches.
function M.distribute(amount, shares)
    local out, given, best, bestShare = {}, 0, nil, -1
    for item, s in pairs(shares) do
        local n = amount >= 0 and math.floor(amount * s) or math.ceil(amount * s)
        out[item] = n
        given = given + n
        if s > bestShare then best, bestShare = item, s end
    end
    if best then out[best] = out[best] + (amount - given) end
    for item, n in pairs(out) do if n == 0 then out[item] = nil end end
    return out
end

return M

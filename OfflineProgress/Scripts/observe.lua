-- Turns two snapshots of the world, taken one measuring window apart, into measurements.
-- Pure Lua, no UE4SS calls.
--
-- A snapshot is { bases = { [baseId] = base } } where base is
--   items     = { [item] = count }      -- storage totals, feed boxes folded into "food"
--   caps      = { [item] = capacity }
--   foodItems = { [item] = count }      -- what's in the feed boxes, by item
--   workers   = { [palId] = { stomach = n, sanity = n } }
--   spoil     = { [slotKey] = { item, count, value, progress, mult, factor } }
--
-- meta[baseId] = { clean = bool, far = bool } describes the whole window: clean means no
-- player was inside that base at any point, far means the player stayed outside the distance
-- at which the game updates bases at full speed.

local rates = require("rates")

local M = {}

local FOOD = "food"

local function atCap(item, snap)
    local cap = snap.caps and snap.caps[item]
    return cap ~= nil and (snap.items[item] or 0) >= cap
end

local function average(list)
    if #list == 0 then return nil end
    local sum = 0
    for _, v in ipairs(list) do sum = sum + v end
    return sum / #list
end

-- known[baseId] = processes table from saved state, used to report zero output for processes
-- that could have run but didn't.
function M.compare(prev, cur, windowSeconds, meta, phase, known)
    local hours = windowSeconds / 3600
    local out = { obs = {}, needs = {}, spoil = {}, mix = {} }
    if hours <= 0 then return out end

    for id, c in pairs(cur.bases or {}) do
        local p = prev.bases and prev.bases[id]
        local m = meta[id] or {}
        if p and m.clean then
            local tags = rates.tagsFor(phase, m.far)
            local emitted = {}
            local function emit(procId, kind, inputs, outputs)
                emitted[procId] = true
                out.obs[#out.obs + 1] = { baseId = id, processId = procId, kind = kind,
                                          inputs = inputs, outputs = outputs, tags = tags }
            end

            local seen = {}
            for item in pairs(c.items) do seen[item] = true end
            for item in pairs(p.items) do seen[item] = true end
            for item in pairs(seen) do
                local d = (c.items[item] or 0) - (p.items[item] or 0)
                if d > 0 then
                    emit("make:" .. item, "work", {}, { [item] = d })
                elseif d < 0 and item == FOOD then
                    emit("eat", "upkeep", { [FOOD] = -d }, {})
                elseif d < 0 then
                    emit("use:" .. item, "work", { [item] = -d }, {})
                end
            end

            -- Nothing moved: count it as a real zero unless the process was blocked.
            for procId, proc in pairs((known and known[id]) or {}) do
                if not emitted[procId] then
                    local item = procId:match("^make:(.+)$")
                    if item then
                        if not atCap(item, c) and not atCap(item, p) then
                            emit(procId, proc.kind or "work", {}, { [item] = 0 })
                        end
                    else
                        item = procId == "eat" and FOOD or procId:match("^use:(.+)$")
                        if item and (c.items[item] or 0) > 0 and (p.items[item] or 0) > 0 then
                            emit(procId, proc.kind or "work", { [item] = 0 }, {})
                        end
                    end
                end
            end

            local eaten, added = {}, {}
            local foods = {}
            for item in pairs(c.foodItems or {}) do foods[item] = true end
            for item in pairs(p.foodItems or {}) do foods[item] = true end
            for item in pairs(foods) do
                local d = ((c.foodItems or {})[item] or 0) - ((p.foodItems or {})[item] or 0)
                if d < 0 then eaten[item] = -d elseif d > 0 then added[item] = d end
            end
            out.mix[id] = { eaten = eaten, added = added }

            local declines, drifts = {}, {}
            for palId, w in pairs(c.workers or {}) do
                local pw = p.workers and p.workers[palId]
                if pw then
                    local ds = w.stomach - pw.stomach
                    if ds < 0 then declines[#declines + 1] = -ds / hours end
                    drifts[#drifts + 1] = (w.sanity - pw.sanity) / hours
                end
            end
            out.needs[id] = { decline = average(declines), drift = average(drifts) }
        end

        -- Spoilage speed doesn't depend on players, only on the item and the container.
        if p then
            for key, s in pairs(c.spoil or {}) do
                local ps = p.spoil and p.spoil[key]
                if ps and ps.item == s.item and ps.count == s.count and s.value > ps.value
                    and (s.factor or 0) > 0 and (s.mult or 0) > 0 then
                    local k = (s.value - ps.value) / hours / (s.factor * s.mult)
                    local threshold = (s.progress or 0) > 0.01 and s.value / s.progress or nil
                    out.spoil[#out.spoil + 1] = { item = s.item, k = k, threshold = threshold }
                end
            end
        end
    end
    return out
end

return M

-- Learns each process's real per-hour rates from live play, so catch-up follows balance
-- patches automatically instead of relying on hand-tuned numbers.
--
-- Every process keeps a running average per condition ("tag"): all windows, windows while the
-- player was far away, day-only, night-only, and day/night while far. Catch-up uses the most
-- specific condition that has enough data.

local M = {}

local function newStats() return { inputs = {}, outputs = {}, samples = 0, pending = {} } end

-- Running average that jumps to a new level once two windows in a row disagree strongly in
-- the same direction, so a rebuilt or dismantled production line shows up in ~2 windows.
local function blend(stats, field, amounts, hours, alpha)
    local dst = stats[field]
    local seen = {}
    for item in pairs(amounts) do seen[item] = true end
    for item in pairs(dst) do seen[item] = true end
    for item in pairs(seen) do
        local r = (amounts[item] or 0) / hours
        local old = dst[item]
        local key = field .. ":" .. item
        if old == nil then
            dst[item] = r
        else
            local deviates = math.abs(r - old) > 0.5 * math.max(math.abs(old), 1)
            local prev = stats.pending[key]
            if deviates and prev ~= nil and (prev > old) == (r > old) then
                dst[item] = (prev + r) / 2
                stats.pending[key] = nil
            else
                dst[item] = old + alpha * (r - old)
                stats.pending[key] = deviates and r or nil
            end
        end
    end
end

-- Older state files stored one set of rates per process; keep them as the "all" condition.
local function migrate(p)
    if p.tags then return end
    p.tags = { all = { inputs = p.inputs or {}, outputs = p.outputs or {}, samples = p.samples or 0, pending = {} } }
    p.inputs, p.outputs, p.samples = nil, nil, nil
end

-- Tags for one measuring window.
function M.tagsFor(phase, far)
    local tags = { "all" }
    if far then tags[#tags + 1] = "far" end
    if phase then tags[#tags + 1] = phase end
    if phase and far then tags[#tags + 1] = phase .. ":far" end
    return tags
end

-- Records what a process moved during one window. inputs/outputs are amounts (not rates).
-- Zero amounts are meaningful: the caller only sends them when the process wasn't blocked.
function M.observe(baseState, procId, kind, inputs, outputs, windowSeconds, alpha, tags)
    local hours = windowSeconds / 3600
    if hours <= 0 then return end
    baseState.processes = baseState.processes or {}
    local p = baseState.processes[procId]
    if not p then
        p = { id = procId, kind = kind, tags = {} }
        baseState.processes[procId] = p
    end
    migrate(p)
    for _, tag in ipairs(tags or { "all" }) do
        local s = p.tags[tag]
        if not s then
            s = newStats()
            p.tags[tag] = s
        end
        s.pending = s.pending or {}
        blend(s, "inputs", inputs or {}, hours, alpha)
        blend(s, "outputs", outputs or {}, hours, alpha)
        s.samples = s.samples + 1
    end
end

-- Processes with enough data to trust, in the shape catchup.simulate expects.
-- phase ("day"/"night"/nil) picks phase-specific rates when they're available.
function M.processList(baseState, minSamples, phase)
    local order = phase and { phase .. ":far", phase, "far", "all" } or { "far", "all" }
    local list = {}
    for _, p in pairs(baseState.processes or {}) do
        migrate(p)
        for _, tag in ipairs(order) do
            local s = p.tags[tag]
            if s and s.samples >= minSamples then
                list[#list + 1] = { id = p.id, kind = p.kind, inputs = s.inputs, outputs = s.outputs, tag = tag }
                break
            end
        end
    end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return list
end

-- Single-number running averages (hunger decline, spoilage speed, clock speed, ...).
function M.scalar(store, key, value, alpha)
    local s = store[key]
    if not s then
        store[key] = { value = value, samples = 1 }
        return
    end
    s.value = s.value + alpha * (value - s.value)
    s.samples = s.samples + 1
end

function M.get(store, key, minSamples)
    local s = store and store[key]
    if s and s.samples >= (minSamples or 1) then return s.value end
    return nil
end

-- Running shares of a mix (e.g. which foods Pals eat), normalised when read.
function M.mix(store, amounts, alpha)
    for item, amt in pairs(amounts) do
        if amt > 0 then store[item] = (store[item] or 0) * (1 - alpha) + amt * alpha end
    end
end

function M.shares(store, onlyItems)
    local sum, out = 0, {}
    for item, w in pairs(store or {}) do
        if not onlyItems or onlyItems[item] then sum = sum + w end
    end
    if sum <= 0 then return nil end
    for item, w in pairs(store) do
        if not onlyItems or onlyItems[item] then out[item] = w / sum end
    end
    return out
end

return M

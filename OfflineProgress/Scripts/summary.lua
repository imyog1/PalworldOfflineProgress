-- "While you were away" summaries, kept per player until they're in the world to see them.
-- Pure Lua, no UE4SS calls.
--
-- pending[playerKey] = { hours, bases = { [baseId] = { name, items, eaten, hatched, machines, eggs, crafts, expeditions } } }

local M = {}

local function newBase(name)
    return { name = name, items = {}, eaten = 0, hatched = 0, machines = 0, eggs = 0, crafts = {}, expeditions = 0 }
end

-- Adds one base's gains from one catch-up to a player's pending summary.
-- gains = { items = {id=n}, eaten = n, hatched = n, machines = n, eggs = n, crafts = {id=n}, expeditions = n }
function M.add(pending, player, baseId, name, gains)
    local entry = pending[player] or { hours = 0, bases = {} }
    pending[player] = entry
    local b = entry.bases[baseId] or newBase(name)
    entry.bases[baseId] = b
    b.name = name or b.name
    for id, n in pairs(gains.items or {}) do b.items[id] = (b.items[id] or 0) + n end
    for id, n in pairs(gains.crafts or {}) do b.crafts[id] = (b.crafts[id] or 0) + n end
    b.eaten = b.eaten + (gains.eaten or 0)
    b.hatched = b.hatched + (gains.hatched or 0)
    b.machines = (b.machines or 0) + (gains.machines or 0)
    b.eggs = b.eggs + (gains.eggs or 0)
    b.expeditions = b.expeditions + (gains.expeditions or 0)
end

-- Counts the offline time once per catch-up for each player who got something.
function M.addHours(pending, players, hours)
    for player in pairs(players) do
        if pending[player] then pending[player].hours = pending[player].hours + hours end
    end
end

function M.number(n)
    local s = tostring(math.floor(math.abs(n) + 0.5))
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. s
end

local function duration(hours)
    local minutes = math.floor(hours * 60 + 0.5)
    if minutes < 60 then return ("%dm"):format(minutes) end
    local h, m = minutes // 60, minutes % 60
    return m > 0 and ("%dh %dm"):format(h, m) or ("%dh"):format(h)
end

local function plural(n, word) return ("%s %s%s"):format(M.number(n), word, n == 1 and "" or "s") end

local function sortedItems(items)
    local list = {}
    for id, n in pairs(items) do if n > 0 then list[#list + 1] = { item = id, n = n } end end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.item < b.item end)
    return list
end

-- Chat lines for one player, plus their biggest gains (for pickup popups).
-- Returns nil if there's nothing worth telling them.
function M.format(entry, itemName, maxItems)
    maxItems = maxItems or 6
    local bases = {}
    for id, b in pairs(entry.bases) do bases[#bases + 1] = { id = id, b = b } end
    table.sort(bases, function(x, y)
        return (x.b.name or x.id) < (y.b.name or y.id)
    end)

    local lines, totals = {}, {}
    for i, e in ipairs(bases) do
        local b = e.b
        local parts = {}
        local items = sortedItems(b.items)
        for j, it in ipairs(items) do
            totals[it.item] = (totals[it.item] or 0) + it.n
            if j <= maxItems then parts[#parts + 1] = "+" .. M.number(it.n) .. " " .. itemName(it.item) end
        end
        if #items > maxItems then parts[#parts + 1] = ("+%d more"):format(#items - maxItems) end
        for _, c in ipairs(sortedItems(b.crafts)) do
            parts[#parts + 1] = plural(c.n, itemName(c.item) .. " craft")
        end
        if b.hatched > 0 then parts[#parts + 1] = plural(b.hatched, "incubator") .. " finished" end
        if (b.machines or 0) > 0 then parts[#parts + 1] = plural(b.machines, "machine job") .. " finished" end
        if b.eggs > 0 then parts[#parts + 1] = plural(b.eggs, "egg") .. " laid" end
        if b.expeditions > 0 then parts[#parts + 1] = plural(b.expeditions, "expedition") .. " moved ahead" end
        if b.eaten > 0 then parts[#parts + 1] = "Pals ate " .. M.number(b.eaten) .. " food" end
        if #parts > 0 then
            lines[#lines + 1] = (b.name or ("Base " .. i)) .. ": " .. table.concat(parts, ", ")
        end
    end
    if #lines == 0 then return nil end
    table.insert(lines, 1, ("While you were away (%s), your bases kept working:"):format(duration(entry.hours)))
    return lines, sortedItems(totals)
end

return M

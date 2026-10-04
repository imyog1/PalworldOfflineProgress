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

-- Layout: the game wraps chat at roughly this many characters, so lines are packed to fit.
local WIDTH = 56
local INDENT = "    "
local SEP = " \u{B7} "    -- middle dot
local BULLET = "\u{2022} " -- bullet

local function width(text) return utf8.len(text) or #text end

-- Joins parts with separators into lines that fit the chat width.
local function pack(parts)
    local out, cur = {}, nil
    for _, p in ipairs(parts) do
        if cur and width(INDENT .. cur .. SEP .. p) <= WIDTH then
            cur = cur .. SEP .. p
        else
            if cur then out[#out + 1] = INDENT .. cur end
            cur = p
        end
    end
    if cur then out[#out + 1] = INDENT .. cur end
    return out
end

-- The summary for one player as blocks of lines: a header, then one block per base (its name,
-- its items, then what else happened there). Also returns their biggest gains, for pickup popups.
-- Returns nil if there's nothing worth telling them.
function M.format(entry, itemName, maxItems)
    maxItems = maxItems or 6
    local bases = {}
    for id, b in pairs(entry.bases) do bases[#bases + 1] = { id = id, b = b } end
    table.sort(bases, function(x, y)
        return (x.b.name or x.id) < (y.b.name or y.id)
    end)

    local blocks, totals = {}, {}
    for i, e in ipairs(bases) do
        local b = e.b
        local items, events = {}, {}
        local list = sortedItems(b.items)
        for j, it in ipairs(list) do
            totals[it.item] = (totals[it.item] or 0) + it.n
            if j <= maxItems then items[#items + 1] = "+" .. M.number(it.n) .. " " .. itemName(it.item) end
        end
        if #list > maxItems then items[#items + 1] = "+" .. plural(#list - maxItems, "more item") end
        for _, c in ipairs(sortedItems(b.crafts)) do
            events[#events + 1] = M.number(c.n) .. " " .. itemName(c.item) .. " crafted"
        end
        if b.hatched > 0 then events[#events + 1] = plural(b.hatched, "egg") .. " hatched" end
        if b.eggs > 0 then events[#events + 1] = plural(b.eggs, "egg") .. " laid" end
        if (b.machines or 0) > 0 then events[#events + 1] = plural(b.machines, "machine job") .. " done" end
        if b.expeditions > 0 then events[#events + 1] = plural(b.expeditions, "expedition") .. " moved ahead" end
        if b.eaten > 0 then events[#events + 1] = "Pals ate " .. M.number(b.eaten) .. " food" end
        if #items + #events > 0 then
            local block = { BULLET .. (b.name or ("Base " .. i)) }
            for _, l in ipairs(pack(items)) do block[#block + 1] = l end
            for _, l in ipairs(pack(events)) do block[#block + 1] = l end
            blocks[#blocks + 1] = block
        end
    end
    if #blocks == 0 then return nil end
    table.insert(blocks, 1, { ("While you were away (%s), your bases kept working:"):format(duration(entry.hours)) })
    return blocks, sortedItems(totals)
end

-- Groups the blocks into chat messages of at most maxLines lines each (a base is never split
-- unless it alone is longer). One message keeps the lines in order and shows one sender tag.
function M.messages(blocks, maxLines)
    maxLines = math.max(1, maxLines or 16)
    local out, cur = {}, {}
    local function flush()
        if #cur > 0 then out[#out + 1] = table.concat(cur, "\n") end
        cur = {}
    end
    for _, block in ipairs(blocks) do
        if #cur > 0 and #cur + #block > maxLines then flush() end
        for _, line in ipairs(block) do
            if #cur >= maxLines then flush() end
            cur[#cur + 1] = line
        end
    end
    flush()
    return out
end

return M

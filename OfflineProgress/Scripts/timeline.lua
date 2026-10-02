-- Splits a real-time gap into day and night stretches using the game's measured clock speed,
-- and works out where the in-game clock would have ended up. Pure Lua, no UE4SS calls.
--
--   clock = { hour = 13.5,              -- current in-game hour (0-24)
--             dayStart = 6, nightStart = 18,
--             rate = { day = 40, night = 40 } }  -- in-game hours per real hour

local M = {}

local function phaseAt(h, clock)
    if h >= clock.dayStart and h < clock.nightStart then return "day" end
    return "night"
end

-- In-game hours until the phase changes.
local function untilBoundary(h, phase, clock)
    local target = phase == "day" and clock.nightStart or clock.dayStart
    local d = (target - h) % 24
    if d <= 0 then d = 24 end
    return d
end

function M.usable(clock)
    return clock ~= nil and clock.hour ~= nil and clock.dayStart ~= nil and clock.nightStart ~= nil
        and clock.dayStart < clock.nightStart and clock.rate ~= nil
        and (clock.rate.day or 0) > 0 and (clock.rate.night or 0) > 0
end

-- Returns { segments = { {phase, hours}, ... }, endHour, gameHours, dawns } or nil if the clock
-- hasn't been measured yet.
function M.split(gapHours, clock)
    if not M.usable(clock) then return nil end
    local segments, h, gameHours, left = {}, clock.hour % 24, 0, gapHours
    for _ = 1, 100000 do
        if left <= 1e-9 then break end
        local phase = phaseAt(h, clock)
        local rate = clock.rate[phase]
        local toBoundary = untilBoundary(h, phase, clock)
        local realNeeded = toBoundary / rate
        local real, g
        if realNeeded <= left then
            real, g = realNeeded, toBoundary
        else
            real, g = left, left * rate
        end
        local last = segments[#segments]
        if last and last.phase == phase then
            last.hours = last.hours + real
        else
            segments[#segments + 1] = { phase = phase, hours = real }
        end
        h = (h + g) % 24
        gameHours = gameHours + g
        left = left - real
    end
    local startAbs = clock.hour
    local endAbs = clock.hour + gameHours
    local dawns = math.floor((endAbs - clock.dayStart) / 24) - math.floor((startAbs - clock.dayStart) / 24)
    return { segments = segments, endHour = h, gameHours = gameHours, dawns = dawns }
end

-- How to move the in-game clock with the tools the game offers: jump to the next morning
-- `nextDays` times, then set the hour within that day. Never moves time backwards.
-- `exact` is false when the target can only be approached (whole hours, or before dawn).
function M.advancePlan(clock, result)
    if not result or result.gameHours <= 0 then return nil end
    local plan = { nextDays = result.dawns, setHour = nil, exact = true }
    local target = math.floor(result.endHour)
    if result.dawns == 0 then
        if result.gameHours < 24 - (clock.hour % 24) and target > math.floor(clock.hour % 24) then
            plan.setHour = target
        else
            plan.exact = false
        end
    elseif result.endHour >= clock.dayStart then
        if target > clock.dayStart then plan.setHour = target end
    else
        -- Ended after midnight but before the next dawn; the closest reachable point is late
        -- on the last day jumped to.
        plan.setHour = 23
        plan.exact = false
    end
    if result.endHour % 1 > 0 then plan.exact = false end
    return plan
end

return M

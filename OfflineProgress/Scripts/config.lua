return {
    -- Palworld build this mod targets. If the running game reports a different version
    -- (or the adapter can't read it), the mod only logs what it would do.
    targetGameVersion = "1.0.5",
    allowUnknownVersion = false,

    -- true: only log what the catch-up would do, change nothing. Overrides everything in `live`.
    dryRun = false,

    -- Which kinds of change are actually written when dryRun is off. Anything false is only
    -- logged, so each one can be checked in the log before it's trusted.
    live = {
        items = true,       -- production added to / food taken from storage
        timers = true,      -- incubators and other self-running work
        spoilage = false,   -- perishable stacks age by the downtime
        palNeeds = false,   -- base Pals get hungry once food runs out; sanity drifts
        worldTime = false,  -- in-game clock and day counter move forward
        crafting = false,   -- crafting queues advance (needed for crafted items to be added)
        breeding = true,    -- breeding farms produce the eggs they would have
        crops = false,      -- crop plots keep growing (visual only; harvests come from rates)
        expeditions = true, -- expeditions and medical-bed revivals finish on time
    },

    -- "While you were away" summary for each player, about their own bases (the bases whose
    -- Palbox they placed): a private system chat message per base, plus pickup popups for the
    -- biggest gains. Players who are offline get theirs when they next join.
    summary = {
        enabled = true,
        popups = 5,           -- pickup popups for the biggest gains (0 = chat only)
        maxItemsPerBase = 6,  -- items listed per base before "+N more"
        -- "system": a system message (shows up for PS5 players too). "player": sent like a typed
        -- Global chat message instead; falls back to "system" if the game won't take it.
        chatStyle = "system",
        sender = "Offline Progress", -- name shown as the message's sender
        joinCheckSeconds = 5,     -- how often to look for players who just joined
        joinDelaySeconds = 5,     -- after a joining player's character appears
        maxJoinWaitSeconds = 45,  -- send anyway this long after they join
    },

    -- How catch-up changes storage:
    --   "topUpOnly": only grows existing stacks and never empties one, so no slot changes item.
    --   "full":      also starts new stacks in empty slots and can empty stacks.
    itemWriteMode = "topUpOnly",

    maxCatchupHours = 24,   -- longer outages are capped here
    minGapSeconds = 10,     -- shorter gaps are ignored
    workEfficiency = 0.75,  -- offline work runs at this fraction of the measured rate
    timerEfficiency = 1.0,  -- incubators/breeding advance at this fraction

    heartbeatSeconds = 60,  -- how often presence, the clock and "last seen" are recorded
    sampleSeconds = 600,    -- length of each rate-measuring window
    rateSmoothing = 0.2,    -- weight of the newest window in the running average
    minSamples = 6,         -- windows needed before a rate is trusted (~1 hour)
    maxCatchupPasses = 20,  -- follow-up rounds for queues (eggs, next crafts) per load

    startupDelaySeconds = 15, -- wait for bases to finish loading before catching up

    -- Log every single piece of work slower than slowMs, with how many full object searches it
    -- did, to track down stutters.
    debugTiming = { enabled = false, slowMs = 5 },

    -- Set to true to leave safe mode after checking the log entry that triggered it.
    clearSafeMode = false,
}

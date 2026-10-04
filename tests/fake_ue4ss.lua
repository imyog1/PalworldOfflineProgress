-- Fake UE4SS + Palworld objects for tests, shaped like the 1.0.5 dump.
-- This checks the mod's logic, not that UE4SS behaves exactly like these fakes.

local F = { calls = {} }
local calls = F.calls
local function count(name) calls[name] = (calls[name] or 0) + 1 end

local nameMeta = { __index = { ToString = function(self) return self.s end } }
function FName(s) return setmetatable({ s = s }, nameMeta) end
local function fstr(s) return { ToString = function() return s end } end

local nextAddress = 1000
local function obj(t)
    nextAddress = nextAddress + 1
    local addr = nextAddress
    t.IsValid = t.IsValid or function() return true end
    t.GetAddress = function() return addr end
    return t
end
F.obj = obj

function F.guid(n) return { A = n, B = 0, C = 0, D = -1 } end
function F.key(n) return ("%08X%08X%08X%08X"):format(n, 0, 0, 0xFFFFFFFF) end
F.zero = { A = 0, B = 0, C = 0, D = 0 }

function F.tarray(list)
    return {
        ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end,
        GetArrayNum = function() return #list end,
    }
end

function F.slot(id, n, max, opts)
    opts = opts or {}
    local s = obj({ StackCount = n, ItemId = { StaticId = FName(id or "None") }, max = max or 9999,
                    SlotIndex = opts.index or 0, CorruptionProgressValue = opts.spoil or 0,
                    DynamicItemData = { Get = function() return opts.dynamic end } })
    s.IsEmpty = function(self) return self.StackCount <= 0 end
    s.GetMaxStack = function(self) return self.max end
    s.GetCorruptionProgressRate = function(self) return self.CorruptionProgressValue end
    s.OnRep_ItemId = function() count("OnRep_ItemId") end
    s.OnRep_StackCount = function() count("OnRep_StackCount") end
    s.OnRep_CorruptionProgressValue = function() count("OnRep_Corruption") end
    return s
end

function F.container(idN, slots, opts)
    opts = opts or {}
    for i, s in ipairs(slots) do s.SlotIndex = i - 1 end
    return obj({
        ID = { ID = F.guid(idN) }, ItemSlotArray = F.tarray(slots), CorruptionMultiplier = opts.mult or 1,
        bIgnoreOnSave = opts.ignored or false,
        OnUpdateSlotContent = function() count("OnUpdateSlotContent") end,
        OnRep_ItemSlotArray = function() count("OnRep_ItemSlotArray") end,
    })
end

function F.storage(baseN, container)
    local module = obj({ GetContainer = function() return container end })
    return obj({ GetItemContainerModule = function() return module end,
                 GetBaseCampIdBelongTo = function() return F.guid(baseN) end })
end

local function module(name)
    return obj({ GetClass = function() return { GetFName = function() return FName(name) end } end,
                 OnUpdateItemContainer = function() count("module:" .. name) end })
end

function F.base(n, opts)
    opts = opts or {}
    return obj({
        ID = F.guid(n), bTemporary = false,
        BaseCampName = opts.name and fstr(opts.name) or nil,
        OwnerMapObjectInstanceId = F.guid(opts.palbox or (n + 5000)),
        IsAvailable = function() return true end,
        PlayerUIdsExistsInsideInServer = F.tarray(opts.inside and { 1 } or {}),
        GetTransform = function() return { Translation = opts.at or { X = 0, Y = 0, Z = 0 } } end,
        ModuleArray = F.tarray({ module("PalBaseCampModuleItemStorage"), module("PalBaseCampModuleItemStackInfo") }),
    })
end

function F.work(baseN, idN, required, current, rate, ownerN)
    local w = obj({ ID = F.guid(idN), BaseCampIdBelongTo = F.guid(baseN), RequiredWorkAmount = required,
                    CurrentWorkAmount = current, AutoWorkSelfAmountBySec = rate,
                    OwnerMapObjectConcreteModelId = F.guid(ownerN or 0),
                    CurrentState = 1 }) -- EPalWorkProgressState::Workable
    w.IsCompleted = function(self) return self.CurrentWorkAmount >= self.RequiredWorkAmount end
    w.OnRep_CurrentWorkAmount = function() count("OnRep_CurrentWorkAmount") end
    return w
end

function F.pal(baseN, idN, stomach, sanity)
    local p = obj({ BaseCampId = baseN and F.guid(baseN) or F.zero, IndividualId = { InstanceId = F.guid(idN) },
                    SaveParameter = { FullStomach = stomach, SanityValue = sanity, MaxFullStomach = 100 } })
    p.SetFullStomach = function(self, v) self.SaveParameter.FullStomach = v end
    return p
end

function F.station(baseN, idN, recipe, remain, opts)
    opts = opts or {}
    local s = obj({ CurrentRecipeId = FName(recipe), RemainProductNum = remain })
    s.IsProductNumInfinite = function() return opts.infinite or false end
    s.IsTransportToStorage = function() return opts.toStorage ~= false end
    s.GetBaseCampIdBelongTo = function() return F.guid(baseN) end
    s.GetInstanceId = function() return F.guid(idN) end
    s.OnRep_RemainProductNum = function() count("OnRep_RemainProductNum") end
    return s
end

-- World registry used by FindAllOf / StaticFindObject.
F.world = {}
F.items = {}   -- static item data by id
F.recipes = {} -- recipe rows by id
F.projectVersion = "1.0.5.102999"

F.searches = {}
function FindAllOf(name)
    F.searches[name] = (F.searches[name] or 0) + 1
    return F.world[name]
end

function StaticFindObject(path)
    if path == "/Script/EngineSettings.Default__GeneralProjectSettings" then
        return obj({ ProjectVersion = fstr(F.projectVersion) })
    elseif path == "/Script/Pal.Default__PalMasterDataTablesUtility" then
        return obj({ GetItemRecipeDataTable = function()
            return obj({ FindRow = function(_, id)
                local r = F.recipes[id]
                if not r then return nil end
                local row = { Product_Id = FName(r.product), Product_Count = r.count or 1 }
                for i = 1, 5 do
                    local m = r.materials[i]
                    row["Material" .. i .. "_Id"] = FName(m and m[1] or "None")
                    row["Material" .. i .. "_Count"] = m and m[2] or 0
                end
                return row
            end })
        end })
    elseif path == "/Script/Engine.Default__KismetSystemLibrary" then
        return obj({ IsServer = function() return F.isServer ~= false end })
    elseif path == "/Script/Engine.Default__KismetMathLibrary" then
        return F.kismet
    end
    return F.statics[path]
end
F.statics = {}

-- FDateTime / FTimespan stand-ins. Real FDateTime has no fields visible to Lua, so the mod
-- only ever touches them through these functions.
local function localOffset()
    local t = os.time()
    return os.difftime(t, os.time(os.date("!*t", t)))
end
function F.dt(unix) return { _t = unix } end
F.kismet = obj({
    UtcNow = function() return F.dt(os.time()) end,
    Now = function() return F.dt(os.time() + localOffset()) end,
    Subtract_DateTimeDateTime = function(_, a, b) return { _s = a._t - b._t } end,
    GetYear = function(_, a) return os.date("*t", math.floor(a._t)).year end,
    GetMonth = function(_, a) return os.date("*t", math.floor(a._t)).month end,
    GetDay = function(_, a) return os.date("*t", math.floor(a._t)).day end,
    GetHour = function(_, a) return os.date("*t", math.floor(a._t)).hour end,
    GetMinute = function(_, a) return os.date("*t", math.floor(a._t)).min end,
    GetSecond = function(_, a) return os.date("*t", math.floor(a._t)).sec end,
    Subtract_DateTimeTimespan = function(_, a, s) return F.dt(a._t - s._s) end,
    MakeTimespan = function(_, d, h, m, s, ms) return { _s = d * 86400 + h * 3600 + m * 60 + s + ms / 1000 } end,
    GetTotalSeconds = function(_, s) return s._s end,
})

function F.itemManager()
    return obj({ GetStaticItemData = function(_, fname)
        local d = F.items[fname:ToString()]
        if not d then return nil end
        return obj({ CorruptionFactor = d.factor or 0, MaxStackCount = d.max or 9999,
                     IsCorruptible = function() return (d.factor or 0) > 0 end,
                     DynamicItemDataClass = d.unique and obj({}) or nil })
    end })
end

function F.fstr(s) return fstr(s) end

-- A model whose date properties behave like UE4SS: assigning a date value directly is
-- silently ignored, but importing the date as text ("YYYY.MM.DD-HH.MM.SS") works.
function F.dateModel(fields)
    local store = {}
    for k, v in pairs(fields) do store[k] = v end
    local imports = 0
    local m = {}
    local reflection = { GetProperty = function(_, name)
        return {
            ContainerPtrToValuePtr = function() return name end,
            ImportText = function(_, text, ptr)
                local y, mo, d, h, mi, se = text:match("^(%d%d%d%d)%.(%d%d)%.(%d%d)%-(%d%d)%.(%d%d)%.(%d%d)$")
                assert(y, "bad date text: " .. tostring(text))
                store[ptr] = F.dt(os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se }))
                imports = imports + 1
            end,
        }
    end }
    store.Reflection = function() return reflection end
    store.IsValid = function() return true end
    store.imports = function() return imports end
    return setmetatable(m, {
        __index = store,
        __newindex = function(_, k, v)
            if type(v) == "table" and v._t then return end -- direct date writes don't stick
            store[k] = v
        end,
    })
end

return F

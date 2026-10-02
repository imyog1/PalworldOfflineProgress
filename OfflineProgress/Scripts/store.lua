-- Saves mod state as a Lua table literal. Writes go to a temp file first and the previous
-- file is kept as .bak, so a crash mid-save can't wipe the heartbeat or learned rates.

local M = {}

local function serialize(v, indent)
    local t = type(v)
    if t == "number" then
        return ("%.17g"):format(v)
    elseif t == "string" then
        return ("%q"):format(v)
    elseif t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local inner = indent .. "  "
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = inner .. "[" .. serialize(k, inner) .. "] = " .. serialize(v[k], inner)
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    error("can't serialize a " .. t)
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local src = f:read("a")
    f:close()
    local chunk = load(src, "=" .. path, "t", {})
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    if ok and type(result) == "table" then return result end
    return nil
end

function M.load(path)
    return readFile(path) or readFile(path .. ".bak")
end

function M.save(path, tbl)
    local tmp = path .. ".tmp"
    local f = assert(io.open(tmp, "w"))
    f:write("return ", serialize(tbl, ""), "\n")
    f:close()
    os.remove(path .. ".bak")
    os.rename(path, path .. ".bak")
    local ok, err = os.rename(tmp, path)
    if not ok then error(err) end
end

M.serialize = serialize

return M

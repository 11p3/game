local SnapshotCodec = {}
local VERSION = 1
local MAX_DEPTH = 24 -- Reject excessively nested snapshots.
local MAX_BYTES = 524288 -- Allow full snapshots without unbounded allocation.
type SnapshotValue = boolean | number | string | {[string | number]: SnapshotValue}

local function Same(first, second)
    if first == second then
        return true
    end
    if type(first) ~= type(second) then
        return false
    end
    if type(first) ~= "table" then
        return first == second
    end
    for key, value in first do if not Same(value, second[key]) then return false end end
    for key in second do if first[key] == nil then return false end end
    return true
end

function SnapshotCodec.Encode(value, baseline)
    local data = buffer.create(1024)
    local offset = 0

    local function Reserve(size)
        local required = offset + size
        assert(required <= MAX_BYTES, "Snapshot exceeds the size limit")
        if required <= buffer.len(data) then
            return
        end
        local expanded = buffer.create(math.min(MAX_BYTES, math.max(required, buffer.len(data) * 2)))
        buffer.copy(expanded, 0, data, 0, offset)
        data = expanded
    end

    local function Write(item: SnapshotValue?, previous: SnapshotValue?, depth: number)
        assert(depth <= MAX_DEPTH, "Snapshot nesting exceeds the limit")
        local kind = type(item)
        Reserve(1)
        if item == nil then
            buffer.writeu8(data, offset, 0)
            offset += 1
        elseif type(item) == "boolean" then
            buffer.writeu8(data, offset, if item then 2 else 1)
            offset += 1
        elseif type(item) == "number" then
            assert(item == item and math.abs(item) < math.huge, "Snapshot contains a nonfinite number")
            -- Use compact integers, but preserve negative zero and fractional values as doubles.
            local integer = item % 1 == 0 and item >= -2147483648 and item <= 2147483647 and (item ~= 0 or 1 / item ~= -math.huge)
            Reserve(if integer then 5 else 9)
            buffer.writeu8(data, offset, if integer then 3 else 4)
            if integer then buffer.writei32(data, offset + 1, item) else buffer.writef64(data, offset + 1, item) end
            offset += if integer then 5 else 9
        elseif type(item) == "string" then
            assert(#item <= 65535, "Snapshot string exceeds the limit")
            Reserve(3 + #item)
            buffer.writeu8(data, offset, 5)
            buffer.writeu16(data, offset + 1, #item)
            buffer.writestring(data, offset + 3, item)
            offset += 3 + #item
        elseif type(item) == "table" then
            local previous_table = if type(previous) == "table" then previous else nil
            local patch = previous_table ~= nil
            Reserve(3)
            buffer.writeu8(data, offset, if patch then 7 else 6)
            local count_at = offset + 1
            offset += 3
            local count = 0
            for key, child in item do
                if not previous_table or not Same(child, previous_table[key]) then
                    Write(key, nil, depth + 1)
                    Write(child, if previous_table then previous_table[key] else nil, depth + 1)
                    count += 1
                end
            end
            if previous_table then
                for key in previous_table do
                    if item[key] == nil then
                        Write(key, nil, depth + 1)
                        Write(nil, nil, depth + 1)
                        count += 1
                    end
                end
            end
            assert(count <= 65535, "Snapshot table exceeds the limit")
            buffer.writeu16(data, count_at, count)
        else
            error("Unsupported snapshot value: " .. kind)
        end
    end

    Reserve(1)
    buffer.writeu8(data, offset, VERSION)
    offset += 1
    Write(value, baseline, 0)
    local result = buffer.create(offset)
    buffer.copy(result, 0, data, 0, offset)
    return result
end

function SnapshotCodec.Decode(data, baseline)
    if typeof(data) ~= "buffer" or buffer.len(data) < 2 or buffer.len(data) > MAX_BYTES then
        return nil, "invalid_buffer"
    end

    local ok, result = pcall(function()
        assert(buffer.readu8(data, 0) == VERSION, "Unsupported snapshot version")
        local offset = 1

        local function Read(previous, depth)
            assert(depth <= MAX_DEPTH, "Snapshot nesting exceeds the limit")
            local tag = buffer.readu8(data, offset)
            offset += 1
            if tag == 0 then
                return nil
            end
            if tag == 1 then
                return false
            end
            if tag == 2 then
                return true
            end
            if tag == 3 then
                local value = buffer.readi32(data, offset)
                offset += 4
                return value
            end
            if tag == 4 then
                local value = buffer.readf64(data, offset)
                offset += 8
                assert(value == value and math.abs(value) < math.huge, "Nonfinite snapshot number")
                return value
            end
            if tag == 5 then
                local length = buffer.readu16(data, offset)
                offset += 2
                local value = buffer.readstring(data, offset, length)
                offset += length
                return value
            end
            assert(tag == 6 or tag == 7, "Unknown snapshot tag")
            assert(tag ~= 7 or type(previous) == "table", "Snapshot baseline is missing")
            local value = if tag == 7 then table.clone(previous) else {}
            local count = buffer.readu16(data, offset)
            offset += 2
            for _ = 1, count do
                local key = Read(nil, depth + 1)
                assert(type(key) == "string" or type(key) == "number", "Invalid snapshot key")
                value[key] = Read(if tag == 7 then previous[key] else nil, depth + 1)
            end
            return value
        end

        local decoded = Read(baseline, 0)
        assert(offset == buffer.len(data), "Trailing snapshot bytes")
        return decoded
    end)

    if not ok then
        return nil, tostring(result)
    end
    return result
end

return SnapshotCodec

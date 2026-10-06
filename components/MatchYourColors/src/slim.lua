-- Match Your Colors: reader for the game's slim data files, the runtime half of the research prototype
-- research/slim.py (byte-identical results, tests/test_slim.lua).
--
-- data/bundles.nxa is a DSAR file: a table of chunks (LZ4 blocks or stored bytes) whose concatenation is the
-- DSAA index (14.5 MB in build 25480438). The index starts with 24-byte item records sorted by name
-- ('<16 hex>', '<16 hex>.gpu_resources', '<16 hex>.stream'; size u64, name offset u32, entry count u32,
-- entry offset u64), the bundle name offsets and the names (about 460 KB in all), then each item's entries
-- {offset in the item u32, offset in a bundle's uncompressed space u32 at +8, bundle number u8 at +15}. Each
-- bundle data/bundles.NN.nxa is again a DSAR file. An archive's main item starts with its table of contents
-- (72-byte header, 32-byte type entries, 80-byte file entries) that locates each resource's main, stream and
-- GPU parts in the three items.
--
-- Nothing here runs per frame: the mod reads files only while a recolor job runs. Only the index's head is
-- kept (read once, binary-searched by name); entries and chunks are read on demand into reused buffers.
-- Every call raises on malformed data.
local ffi = require('ffi')
local bit = require('bit')
local band, rshift = bit.band, bit.rshift
local format, byte = string.format, string.byte

local Slim = {}

local HIGH = 4294967296
local CHUNK_RECORD = 32
local ITEM_RECORD = 24
local ENTRY_RECORD = 16
local TOC_HEADER, TOC_TYPE, TOC_FILE = 72, 32, 80
local STORED_DIRECT = 4194304 -- stored chunks above this size are read in place, never whole
-- Decoded chunks kept: reads alternating between two regions (an ID mask's layers) decode each chunk once, also
-- where a read crosses a chunk boundary.
local CHUNK_SLOTS = 3
local ENTRY_CACHE = 16
Slim.TOC_MAGIC = 0xF0000011

-- Little-endian unsigned readers over a uint8_t pointer (numbers, exact below 2^53).
local function u32(p, o)
    return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216
end
local function u64(p, o)
    return u32(p, o) + u32(p, o + 4) * HIGH
end
Slim.u32, Slim.u64 = u32, u64

-- The 16 lowercase hex digits of a 64-bit name given as two 32-bit halves.
function Slim.hex(high, low)
    return format('%08x%08x', high, low)
end

-- The length of a run of bytes that LZ4 encodes as 15 plus extension bytes; returns the length and the next
-- input position.
local function extended(src, ip, src_size, length)
    local b
    repeat
        if ip >= src_size then error('lz4: truncated length', 0) end
        b = src[ip]
        ip = ip + 1
        length = length + b
    until b ~= 255
    return length, ip
end

-- Copies one sequence's literals (count from the token's high nibble); returns the next input and output
-- positions.
local function copy_literals(src, ip, src_size, dst, op, capacity, count)
    if count == 15 then count, ip = extended(src, ip, src_size, count) end
    if ip + count > src_size or op + count > capacity then error('lz4: literals overrun', 0) end
    ffi.copy(dst + op, src + ip, count)
    return ip + count, op + count
end

-- Copies one sequence's match (offset, then length from the token's low nibble plus 4); overlapping matches
-- copy byte by byte. Returns the next input and output positions.
local function copy_match(src, ip, src_size, dst, op, capacity, token)
    if ip + 2 > src_size then error('lz4: truncated offset', 0) end
    local offset = src[ip] + src[ip + 1] * 256
    ip = ip + 2
    if offset == 0 or offset > op then error('lz4: bad offset', 0) end
    local length = band(token, 15)
    if length == 15 then length, ip = extended(src, ip, src_size, length) end
    length = length + 4
    if op + length > capacity then error('lz4: match overrun', 0) end
    local from = op - offset
    if offset >= length then
        ffi.copy(dst + op, dst + from, length)
    else
        for k = 0, length - 1 do dst[op + k] = dst[from + k] end
    end
    return ip, op + length
end

-- LZ4 block decoder (the block format, no frame). src: uint8_t pointer, src_size bytes; dst: uint8_t
-- pointer with room for capacity bytes; pause (optional): called after every LZ4_PAUSE bytes of output, so a
-- job can pause inside a chunk (a 256 KB chunk is several ms of work in the game). Returns the decoded size,
-- or raises on malformed input.
local LZ4_PAUSE = 32768
function Slim.lz4(src, src_size, dst, capacity, pause)
    local ip, op = 0, 0
    local next_pause = pause and LZ4_PAUSE or math.huge
    while ip < src_size do
        local token = src[ip]
        ip, op = copy_literals(src, ip + 1, src_size, dst, op, capacity, rshift(token, 4))
        if ip >= src_size then break end
        ip, op = copy_match(src, ip, src_size, dst, op, capacity, token)
        if op >= next_pause then
            pause()
            next_pause = op + LZ4_PAUSE
        end
    end
    return op
end

-- A growable byte buffer: get(size) returns a uint8_t array of at least size bytes, reused between calls.
local function grower(initial)
    local size, data = initial, ffi.new('uint8_t[?]', initial)
    return function(wanted)
        if wanted > size then
            while size < wanted do size = size * 2 end
            data = ffi.new('uint8_t[?]', size)
        end
        return data
    end
end
Slim.grower = grower

-- One DSAR file: its chunk table (uncompressed offset u64, compressed offset u64, uncompressed size u32,
-- compressed size u32, compression u8; 32 bytes each) read once, and read(at, size, out, out_offset) copying
-- bytes of its uncompressed space. files: the file adapter (see Slim.open); scratch: shared buffers.
local function dsar(files, path, scratch)
    local handle = files.open(path)
    local head = scratch.head(32)
    files.read(handle, 0, 32, head)
    if u32(head, 0) ~= 0x52415344 then error('not a DSAR file: ' .. path, 0) end -- 'DSAR'
    local count = u32(head, 8)
    local chunks = ffi.new('uint8_t[?]', count * CHUNK_RECORD)
    files.read(handle, 32, count * CHUNK_RECORD, chunks)
    local self = {count = count, path = path}

    -- The chunk holding uncompressed offset `at` (binary search; chunks are sorted and contiguous).
    local function find(at)
        local lo, hi = 0, count - 1
        while lo <= hi do
            local mid = rshift(lo + hi, 1)
            local start = u64(chunks, mid * CHUNK_RECORD)
            if at < start then
                hi = mid - 1
            elseif at >= start + u32(chunks, mid * CHUNK_RECORD + 16) then
                lo = mid + 1
            else
                return mid
            end
        end
        error(format('offset %.0f outside %s', at, path), 0)
    end

    -- The decoded bytes of chunk k: a pointer into one of the shared chunk slots (every file's), valid until
    -- CHUNK_SLOTS other chunks were decoded. The least recently used slot takes a new chunk; a slot's buffer is
    -- made when first needed.
    local function decoded(k)
        local slots = scratch.slots
        scratch.tick = scratch.tick + 1
        local slot = slots[1]
        for i = 1, #slots do
            local s = slots[i]
            if s.owner == self and s.k == k then
                s.used = scratch.tick
                return s.data
            end
            if s.used < slot.used then slot = s end
        end
        if #slots < CHUNK_SLOTS and slots[1].owner then
            slot = {chunk = grower(262144), used = 0}
            slots[#slots + 1] = slot
        end
        local base = k * CHUNK_RECORD
        local packed_at, size = u64(chunks, base + 8), u32(chunks, base + 16)
        local packed_size, compression = u32(chunks, base + 20), chunks[base + 24]
        slot.owner = nil -- a decode the job abandons at a pause leaves no slot that looks valid
        local out = slot.chunk(size)
        if compression == 0 then
            files.read(handle, packed_at, size, out)
        elseif compression == 3 then
            local packed = scratch.packed(packed_size)
            files.read(handle, packed_at, packed_size, packed)
            if Slim.lz4(packed, packed_size, out, size, scratch.yield) ~= size then
                error('lz4: short chunk in ' .. path, 0)
            end
        else
            error(format('compression %d in %s', compression, path), 0)
        end
        slot.owner, slot.k, slot.data, slot.used = self, k, out, scratch.tick
        scratch.decodes = scratch.decodes + 1
        if scratch.yield then scratch.yield() end -- a job may pause between chunks (the chunk stays decoded)
        return out
    end

    function self.read(at, size, out, out_offset)
        out_offset = out_offset or 0
        while size > 0 do
            local k = find(at)
            local base = k * CHUNK_RECORD
            local start, length = u64(chunks, base), u32(chunks, base + 16)
            local skip = at - start
            local take = math.min(size, length - skip)
            if chunks[base + 24] == 0 and length > STORED_DIRECT then
                files.read(handle, u64(chunks, base + 8) + skip, take, out + out_offset)
            else
                ffi.copy(out + out_offset, decoded(k) + skip, take)
            end
            at, size, out_offset = at + take, size - take, out_offset + take
        end
    end

    function self.close() files.close(handle) end
    return self
end

-- -1, 0 or 1: the NUL-terminated name at names[at] against the Lua string `name`, bytewise.
local function compare(names, at, limit, name)
    local length = #name
    for i = 1, length + 1 do
        local a = at + i - 1 < limit and names[at + i - 1] or 0
        local b = i <= length and byte(name, i) or 0
        if a ~= b then return a < b and -1 or 1 end
        if a == 0 then return 0 end
    end
    return 0
end

-- The slim data reader. files: {open(path) -> handle, read(handle, offset, size, uint8_t *), close(handle)},
-- raising on failure; data: the game's data folder with a trailing separator; yield (optional): called after
-- each chunk is decoded, so a job can pause there (about 1 ms of work per 256 KB chunk).
function Slim.open(files, data, yield)
    local scratch = {head = grower(128), slots = {{chunk = grower(262144), used = 0}}, packed = grower(262144), decodes = 0,
                     tick = 0, yield = yield}
    local index = dsar(files, data .. 'bundles.nxa', scratch)
    local head = scratch.head(24)
    index.read(0, 24, head)
    if u32(head, 0) ~= 0x41415344 then error('bundles.nxa holds no DSAA index', 0) end -- 'DSAA'
    local bundle_count, item_count = u32(head, 12), u32(head, 16)
    local self = {items = item_count, bundles = bundle_count, scratch = scratch}
    -- Item records and the bundle name offsets after them, then the names (item names, then bundle names).
    local records_size = item_count * ITEM_RECORD + bundle_count * 4
    local records = ffi.new('uint8_t[?]', records_size)
    index.read(24, records_size, records)
    local names_at = u32(records, 8)
    local names_end = names_at
    for b = 0, bundle_count - 1 do
        names_end = math.max(names_end, u32(records, item_count * ITEM_RECORD + 4 * b) + 64)
    end
    names_end = math.min(names_end, u64(records, 16))
    local names = ffi.new('uint8_t[?]', names_end - names_at)
    index.read(names_at, names_end - names_at, names)
    local names_size = names_end - names_at

    local function name_at(at)
        local o = at - names_at
        for n = o, names_size - 1 do
            if names[n] == 0 then return ffi.string(names + o, n - o) end
        end
        error('index name runs past the names', 0)
    end

    local bundle_files = {}
    local function bundle(number)
        local found = bundle_files[number]
        if found then return found end
        if number >= bundle_count then error('bundle number out of range', 0) end
        found = dsar(files, data .. name_at(u32(records, item_count * ITEM_RECORD + 4 * number)), scratch)
        bundle_files[number] = found
        return found
    end

    -- The item number of `name` (binary search over the sorted records), or nil.
    function self.item(name)
        local lo, hi = 0, item_count - 1
        while lo <= hi do
            local mid = rshift(lo + hi, 1)
            local order = compare(names, u32(records, mid * ITEM_RECORD + 8) - names_at, names_size, name)
            if order == 0 then return mid end
            if order < 0 then lo = mid + 1 else hi = mid - 1 end
        end
        return nil
    end

    -- Entry tables of recently read items (item number -> uint8_t array), at most ENTRY_CACHE.
    local entry_tables, entry_order = {}, {}
    local function entries_of(k)
        local found = entry_tables[k]
        if found then return found end
        local base = k * ITEM_RECORD
        local count = u32(records, base + 12)
        found = ffi.new('uint8_t[?]', math.max(1, count * ENTRY_RECORD))
        index.read(u64(records, base + 16), count * ENTRY_RECORD, found)
        if #entry_order >= ENTRY_CACHE then entry_tables[table.remove(entry_order, 1)] = nil end
        entry_tables[k] = found
        entry_order[#entry_order + 1] = k
        return found
    end

    -- The last entry whose item offset is at or below `at` (binary search).
    local function entry_for(table_bytes, count, at)
        local lo, hi, best = 0, count - 1, 0
        while lo <= hi do
            local mid = rshift(lo + hi, 1)
            if u32(table_bytes, mid * ENTRY_RECORD) <= at then best, lo = mid, mid + 1 else hi = mid - 1 end
        end
        return best
    end

    -- Copies bytes [at, at + size) of item `name`'s virtual file into out (uint8_t *) at out_offset.
    function self.read(name, at, size, out, out_offset)
        local k = self.item(name)
        if not k then error('archive item missing: ' .. name, 0) end
        local base = k * ITEM_RECORD
        local total, count = u64(records, base), u32(records, base + 12)
        if at < 0 or at + size > total then error('read outside archive item ' .. name, 0) end
        local table_bytes = entries_of(k)
        out_offset = out_offset or 0
        local e = entry_for(table_bytes, count, at)
        while size > 0 do
            if e >= count then error('archive item entries end early: ' .. name, 0) end
            local o = e * ENTRY_RECORD
            local start, bundle_at, number = u32(table_bytes, o), u32(table_bytes, o + 8), table_bytes[o + 15]
            local stop = e + 1 < count and u32(table_bytes, (e + 1) * ENTRY_RECORD) or total
            local take = math.min(size, stop - at)
            bundle(number).read(bundle_at + (at - start), take, out, out_offset)
            at, size, out_offset, e = at + take, size - take, out_offset + take, e + 1
        end
    end

    -- An archive's table of contents, kept raw: {raw, base, count, heads = {[name low half] = first entry},
    -- nexts (the next entry with the same low half, -1 at the end)}, or nil when the archive is not in the index.
    -- Building it touches each entry once and makes no strings (the shared archive lists 4,241 files), with a
    -- pause point every 512 entries.
    local tocs, found_records = {}, {}
    local function toc(archive)
        local found = tocs[archive]
        if found ~= nil then return found or nil end
        if not self.item(archive) then
            tocs[archive] = false
            return nil
        end
        local head72 = scratch.head(TOC_HEADER)
        self.read(archive, 0, TOC_HEADER, head72)
        if u32(head72, 0) ~= Slim.TOC_MAGIC then error('bad archive header: ' .. archive, 0) end
        local types, count = u32(head72, 4), u32(head72, 8)
        local base = TOC_HEADER + TOC_TYPE * types
        local raw = ffi.new('uint8_t[?]', base + TOC_FILE * count)
        self.read(archive, 0, base + TOC_FILE * count, raw)
        local heads, nexts = {}, ffi.new('int32_t[?]', math.max(1, count))
        for i = count - 1, 0, -1 do -- backwards, so each chain lists entries in file order
            local low = u32(raw, base + TOC_FILE * i)
            nexts[i] = heads[low] or -1
            heads[low] = i
            if i % 512 == 0 and scratch.yield then scratch.yield() end
        end
        found = {raw = raw, base = base, count = count, heads = heads, nexts = nexts}
        tocs[archive] = found
        return found
    end
    self.toc = toc

    -- A resource's TOC record {main_at, main_size, stream_at, stream_size, gpu_at, gpu_size} in one archive
    -- (file entry: name u64, type u64, part offsets u64 at +16/+24/+32, part sizes u32 at +56/+60/+64), or nil.
    -- name_hex, type_hex: 16 hex digits. Records found are kept.
    function self.locate(archive, name_hex, type_hex)
        local t = toc(archive)
        if not t then return nil end
        local key = archive .. name_hex .. type_hex
        local record = found_records[key]
        if record ~= nil then return record or nil end
        local name_high, name_low = tonumber(name_hex:sub(1, 8), 16), tonumber(name_hex:sub(9, 16), 16)
        local type_high, type_low = tonumber(type_hex:sub(1, 8), 16), tonumber(type_hex:sub(9, 16), 16)
        local raw, i = t.raw, t.heads[name_low]
        while i and i >= 0 do
            local o = t.base + TOC_FILE * i
            if u32(raw, o + 4) == name_high and u32(raw, o + 8) == type_low and u32(raw, o + 12) == type_high then
                record = {u64(raw, o + 16), u32(raw, o + 56), u64(raw, o + 24), u32(raw, o + 60),
                          u64(raw, o + 32), u32(raw, o + 64)}
                break
            end
            i = t.nexts[i]
        end
        found_records[key] = record or false
        return record
    end

    local PARTS = {main = {1, ''}, stream = {3, '.stream'}, gpu = {5, '.gpu_resources'}}
    -- The size of a resource part ('main', 'stream' or 'gpu'); record from locate().
    function self.part_size(record, part)
        return record[PARTS[part][1] + 1]
    end

    -- Copies bytes [at, at + size) of a resource part into out at out_offset; raises when the part is shorter.
    function self.part(archive, record, part, at, size, out, out_offset)
        local p = PARTS[part]
        if at < 0 or at + size > record[p[1] + 1] then error('read outside a resource part', 0) end
        self.read(archive .. p[2], record[p[1]] + at, size, out, out_offset)
    end

    function self.close()
        index.close()
        for _, found in pairs(bundle_files) do found.close() end
    end
    return self
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Slim.hex, grower, dsar, compare, Slim.open}) do
        jit.off(fn, true)
    end
end

return Slim

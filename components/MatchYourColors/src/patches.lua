-- Match Your Colors: mods' loose patch files, read with the priority the game gives them, over the slim data
-- (src/slim.lua).
--
-- Mod managers install every mod as patches of the boot archive 9ba626afa44a3aa3: data/9ba626afa44a3aa3.patch_0,
-- _1, ..., each a classic archive file (at offset 0 the table of contents src/slim.lua reads from an archive item:
-- 72-byte header, 32-byte type entries, 80-byte file entries) with its stream and GPU parts in .stream and
-- .gpu_resources files beside it. The game loads that archive's patches at boot, before any helmet, armor or cape
-- archive, so a texture, material or unit a patch holds replaces the archived one of the same name and type for the
-- whole session, and between patches the higher number wins (KB arsenal-hd2mm-deploy-internals; Bingus Shared
-- Loader ranks them the same way). Patches of another archive (<archive>.patch_N) count when that archive is
-- searched. Up to v1.3 the mod read only the archived resources and replaced modded helmets' and armors' LUTs with
-- recolored vanilla ones (user report 2026-10-06, KB match-your-colors-modded-luts).
--
-- Patches.index runs once per session inside the first recolor job (never per frame): the data folder's patch files
-- are listed, their tables of contents read (two reads a patch), and the entries of the resource types the mod reads
-- indexed. Its signature is a checksum of every indexed entry (name, type, part offsets and sizes), so the analysis
-- cache is discarded when the installed mods change what they hold. Two variants of one mod can hold the same entries
-- and differ only in their bytes (managers zero the files' dates; a black and a blue visor: same name, same sizes), so
-- each analysis also carries a content hash of every byte range it read from patched resources (Patches.content_hash,
-- src/recolor.lua): a cached analysis is checked against the patches when first used and made again when one differs.
-- Until v1.3 the signature also read the bytes of every indexed part up to 64 KB (2,121 entries, about 4,000 reads, in
-- a user's first job with 176 patch files) and each analysis hashed the whole of every patched resource it touched
-- (a mod's meshes and 4K masks: 2.6 GB read in one Armory session, user report 2026-10-08). Patches.over(slim, index,
-- files) is the job's reader: slim's locate, part and part_size, with patch resources first, noting what it reads of
-- them (ranges); Patches.record looks a resource up in the patches alone.
local ffi = require('ffi')

local Patches = {}

Patches.BOOT = '9ba626afa44a3aa3'
Patches.MAX_ENTRIES = 262144 -- a table of contents above this is not indexed (no mod comes near)
local TOC_HEADER, TOC_TYPE, TOC_FILE, TOC_MAGIC = 72, 32, 80, 0xF0000011
local PARTS = {main = {1, ''}, stream = {3, '.stream'}, gpu = {5, '.gpu_resources'}}
local PART_ORDER = {'main', 'stream', 'gpu'}
local UNINDEXED = -2 -- an entry of another type (chains end with -1)

local function u32(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
local function u64(p, o) return u32(p, o) + u32(p, o + 4) * 4294967296 end

-- The patch files among names, in priority order: the boot archive's first, then every other archive's (by
-- name); within an archive the highest number first. {{file, archive, number}, ...}.
function Patches.order(names)
    local out = {}
    for _, name in ipairs(names) do
        local archive, number = name:match('^(%x+)%.patch_(%d+)$')
        if archive and #archive == 16 and #number <= 6 then
            out[#out + 1] = {file = name, archive = archive:lower(), number = tonumber(number)}
        end
    end
    table.sort(out, function(a, b)
        if a.archive ~= b.archive then
            if a.archive == Patches.BOOT or b.archive == Patches.BOOT then return a.archive == Patches.BOOT end
            return a.archive < b.archive
        end
        return a.number > b.number
    end)
    return out
end

-- Adler-32 over p[0 .. size - 1] from (a, b), reduced every 4,096 bytes (the sums stay exact): the hot loop of the
-- index's signature and of a content hash, left to compile (about 1 ms per MB outside the game). Until v1.3 the
-- signature summed bytes in an interpreted loop with two modulo steps per byte: about 3.2 ms per 64 KB part in the
-- game's VM, in one piece.
local function adler(p, size, a, b)
    local i = 0
    while i < size do
        local stop = math.min(i + 4096, size)
        for k = i, stop - 1 do
            a = a + p[k]
            b = b + a
        end
        a, b = a % 65521, b % 65521
        i = stop
    end
    return a, b
end

-- A running Adler-32 over byte arrays (adler) and strings.
local function checksum()
    local a, b = 1, 0
    local self = {}
    function self.bytes(p, size) a, b = adler(p, size, a, b) end
    function self.text(s)
        for i = 1, #s do
            a = (a + s:byte(i)) % 65521
            b = (b + a) % 65521
        end
    end
    function self.value() return b * 65536 + a end
    return self
end

-- One patch file's table of contents with its entries of the wanted types ({['low:high'] = true}) chained by
-- their name's low half (as src/slim.lua's archive tables); nil when it holds none of them.
local function read_toc(files, patch, wanted, scratch, yield)
    local handle = files.open(patch.file)
    local ok, toc = pcall(function()
        local head = scratch(TOC_HEADER)
        files.read(handle, 0, TOC_HEADER, head)
        if u32(head, 0) ~= TOC_MAGIC then error('bad patch header: ' .. patch.file, 0) end
        local type_count, count = u32(head, 4), u32(head, 8)
        if count == 0 or count > Patches.MAX_ENTRIES or type_count > 4096 then return nil end
        local base = TOC_HEADER + TOC_TYPE * type_count
        local raw = ffi.new('uint8_t[?]', base + TOC_FILE * count)
        files.read(handle, 0, base + TOC_FILE * count, raw)
        local heads, nexts, indexed = {}, ffi.new('int32_t[?]', count), 0
        for i = count - 1, 0, -1 do -- backwards, so each chain lists entries in file order
            local o = base + TOC_FILE * i
            nexts[i] = UNINDEXED
            if wanted[u32(raw, o + 8) .. ':' .. u32(raw, o + 12)] then
                local low = u32(raw, o)
                nexts[i] = heads[low] or -1
                heads[low] = i
                indexed = indexed + 1
            end
            if i % 512 == 0 then yield() end
        end
        if indexed == 0 then return nil end
        return {raw = raw, base = base, count = count, heads = heads, nexts = nexts, indexed = indexed}
    end)
    files.close(handle)
    if not ok then error(toc, 0) end
    return toc
end

-- Adds an indexed patch's entries to sum: its file name and each entry's 80 bytes (name, type, part offsets and
-- sizes), in file order, with a pause point every 64 entries (an entry is a few microseconds, interpreted).
local function sum_entries(patch, sum, yield)
    local t = patch.toc
    for i = 0, t.count - 1 do
        if t.nexts[i] ~= UNINDEXED then
            sum.text(patch.file)
            sum.bytes(t.raw + (t.base + TOC_FILE * i), TOC_FILE)
        end
        if i % 64 == 63 then yield() end
    end
end

-- The session's patch index. files: a file adapter (src/files.lua: open, read, close, list) on the folder holding
-- the patches; types: {type hex, ...} of the resources the mod reads; scratch: a grower (src/slim.lua); yield: the
-- job's pause. {patches (priority order, each {file, archive, number, toc}), signature, entries, skipped}. A patch
-- that cannot be read is left out and counted in skipped.
function Patches.index(files, types, scratch, yield)
    local wanted = {}
    for _, hex in ipairs(types) do
        wanted[tonumber(hex:sub(9, 16), 16) .. ':' .. tonumber(hex:sub(1, 8), 16)] = true
    end
    local sum = checksum()
    local out = {patches = {}, entries = 0, skipped = 0}
    for _, patch in ipairs(Patches.order(files.list('*.patch_*'))) do
        local ok, toc = pcall(read_toc, files, patch, wanted, scratch, yield)
        if ok and toc then
            patch.toc = toc
            sum_entries(patch, sum, yield)
            out.patches[#out.patches + 1] = patch
            out.entries = out.entries + toc.indexed
        end
        if not ok then out.skipped = out.skipped + 1 end
    end
    out.signature = string.format('%d:%d:%d:%08x', #out.patches, out.entries, out.skipped, sum.value())
    return out
end

-- The record of name and type in one patch ({main at, main size, stream at, stream size, GPU at, GPU size, file =
-- the patch file}), or nil.
local function record_in(patch, name_high, name_low, type_high, type_low)
    local t = patch.toc
    local raw, i = t.raw, t.heads[name_low]
    while i and i >= 0 do
        local o = t.base + TOC_FILE * i
        if u32(raw, o + 4) == name_high and u32(raw, o + 8) == type_low and u32(raw, o + 12) == type_high then
            return {u64(raw, o + 16), u32(raw, o + 56), u64(raw, o + 24), u32(raw, o + 60), u64(raw, o + 32),
                    u32(raw, o + 64), file = patch.file}
        end
        i = t.nexts[i]
    end
    return nil
end

-- The record the patches give for name and type when `archive` is searched (the boot archive's patches, then the
-- archive's own), or nil (the archive's own resource then counts).
function Patches.record(index, archive, name_hex, type_hex)
    local name_high, name_low = tonumber(name_hex:sub(1, 8), 16), tonumber(name_hex:sub(9, 16), 16)
    local type_high, type_low = tonumber(type_hex:sub(1, 8), 16), tonumber(type_hex:sub(9, 16), 16)
    for _, patch in ipairs(index.patches) do
        if patch.archive == Patches.BOOT or patch.archive == archive then
            local record = record_in(patch, name_high, name_low, type_high, type_low)
            if record then return record end
        end
    end
    return nil
end

Patches.CHUNK = 262144 -- bytes a content hash reads at a time (v1.3: 64 KB, four times the reads)

-- Byte ranges read of one patched resource: {main = {from, to, from, to, ...}, stream = ..., gpu = ...} (offsets in
-- the part, half-open), as Patches.over notes them; merged: sorted, overlapping and adjacent ones joined.
local function merged(list)
    local pairs_ = {}
    for i = 1, #list, 2 do pairs_[#pairs_ + 1] = {list[i], list[i + 1]} end
    table.sort(pairs_, function(x, y) return x[1] < y[1] end)
    local out = {}
    for _, r in ipairs(pairs_) do
        if out[#out] and r[1] <= out[#out] then
            out[#out] = math.max(out[#out], r[2])
        else
            out[#out + 1], out[#out + 2] = r[1], r[2]
        end
    end
    return out
end

-- Ranges as text (the disk cache keeps them): 'main:0+116,4096+200|gpu:0+1472' (offset + length per range, parts in
-- order), '-' for none; and back (nil when malformed).
function Patches.ranges_text(ranges)
    local parts = {}
    for _, part in ipairs(PART_ORDER) do
        local list = ranges and ranges[part] and merged(ranges[part]) or {}
        if #list > 0 then
            local items = {}
            for i = 1, #list, 2 do items[#items + 1] = string.format('%.0f+%.0f', list[i], list[i + 1] - list[i]) end
            parts[#parts + 1] = part .. ':' .. table.concat(items, ',')
        end
    end
    return #parts > 0 and table.concat(parts, '|') or '-'
end
function Patches.parse_ranges(text)
    if text == '-' then return {} end
    local out = {}
    for piece in text:gmatch('[^|]+') do
        local part, items = piece:match('^(%a+):(.+)$')
        if not part or not PARTS[part] or out[part] then return nil end
        local list = {}
        for from, length in items:gmatch('(%d+)%+(%d+)') do
            list[#list + 1], list[#list + 2] = tonumber(from), tonumber(from) + tonumber(length)
        end
        if #list == 0 then return nil end
        out[part] = list
    end
    return out
end

-- A patch record's content hash over the byte ranges an analysis read of it (Patches.over's ranges; none: only its
-- presence counted), 'bytes:adler32' over the ranges, parts in order and ranges in offset order, read in CHUNK pieces
-- from the patch's files with yield() after each. files: the adapter on the patch folder; scratch: a grower
-- (src/slim.lua). v1.3 hashed every byte of the resource: the whole mesh of a mod's unit, every mip of its masks.
function Patches.content_hash(files, record, scratch, yield, ranges)
    local a, b, total = 1, 0, 0
    for _, part in ipairs(PART_ORDER) do
        local list = ranges and ranges[part] and merged(ranges[part]) or {}
        local p = PARTS[part]
        if #list > 0 then
            if list[#list] > record[p[1] + 1] then error('content range outside ' .. record.file .. ' ' .. part, 0) end
            local handle = files.open(record.file .. p[2])
            local ok, why = pcall(function()
                for i = 1, #list, 2 do
                    for done = list[i], list[i + 1] - 1, Patches.CHUNK do
                        local n = math.min(Patches.CHUNK, list[i + 1] - done)
                        local buffer = scratch(n)
                        files.read(handle, record[p[1]] + done, n, buffer)
                        a, b = adler(buffer, n, a, b)
                        total = total + n
                        if yield then yield() end
                    end
                end
            end)
            files.close(handle)
            if not ok then error(why, 0) end
        end
    end
    return string.format('%d:%08x', total, b * 65536 + a)
end

-- The job's reader: slim (src/slim.lua's reader) with the patches of index first; files: the adapter on the folder
-- holding them. locate(archive, name, type) -> a record (a patch's carries its file), part_size, part, close; base:
-- slim itself (the archived resources, for comparing a patched LUT with its original); slim's other fields as they are.
-- ranges: while the caller sets it to a table, every read of a patched resource is noted there ({[record] = ranges},
-- Patches.content_hash's).
function Patches.over(slim, index, files)
    local handles, found = {}, {}
    local self = {base = slim}
    for k, v in pairs(slim) do self[k] = v end

    -- The boot archive's patches, then the searched archive's, then the archive itself.
    function self.locate(archive, name_hex, type_hex)
        local key = archive .. name_hex .. type_hex
        local record = found[key]
        if record ~= nil then return record or nil end
        record = Patches.record(index, archive, name_hex, type_hex) or slim.locate(archive, name_hex, type_hex)
        found[key] = record or false
        return record
    end

    function self.part(archive, record, part, at, size, out, out_offset)
        if not record.file then return slim.part(archive, record, part, at, size, out, out_offset) end
        local p = PARTS[part]
        if at < 0 or at + size > record[p[1] + 1] then error('read outside a resource part', 0) end
        local name = record.file .. p[2]
        handles[name] = handles[name] or files.open(name)
        files.read(handles[name], record[p[1]] + at, size, out + (out_offset or 0))
        local ranges = self.ranges
        if ranges and size > 0 then
            local r = ranges[record] or {}
            ranges[record] = r
            local list = r[part] or {}
            r[part] = list
            list[#list + 1], list[#list + 2] = at, at + size
        end
    end

    function self.close()
        for name, handle in pairs(handles) do
            files.close(handle)
            handles[name] = nil
        end
        slim.close()
    end
    return self
end

-- Runs inside recolor jobs only: interpreted (no traces in the LuaJIT code cache every mod shares).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({u32, u64, Patches.order, checksum, read_toc, sum_entries, Patches.index, record_in,
                         Patches.record, merged, Patches.ranges_text, Patches.parse_ranges, Patches.content_hash,
                         Patches.over}) do
        jit.off(fn, true)
    end
end

return Patches

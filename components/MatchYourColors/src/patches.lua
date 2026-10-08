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
-- are listed, their tables of contents read, and the entries of the resource types the mod reads indexed (a patch
-- holding none of them, such as a Lua addon, costs its list entry and two reads). Its signature is a checksum of
-- every indexed entry and of the bytes of their small parts (LUTs, materials, units), so the analysis cache is
-- discarded when the installed mods change: managers zero the files' dates, and two variants of one LUT mod differ
-- only in their pixels. Parts over SMALL enter it by offset and size only, so the analyses themselves carry the
-- full content hash of every patched resource they read (Patches.content_hash, src/recolor.lua): a cached analysis is
-- checked against the patches when first used and made again when one differs (an equal-size replacement of an ID
-- mask or a unit). Patches.over(slim, index, files) is the job's reader: slim's locate, part and part_size, with
-- patch resources first; Patches.record looks a resource up in the patches alone.
local ffi = require('ffi')

local Patches = {}

Patches.BOOT = '9ba626afa44a3aa3'
Patches.SMALL = 65536 -- parts up to this size enter the signature with their bytes; larger ones with their size
Patches.MAX_ENTRIES = 262144 -- a table of contents above this is not indexed (no mod comes near)
local TOC_HEADER, TOC_TYPE, TOC_FILE, TOC_MAGIC = 72, 32, 80, 0xF0000011
-- A file entry's parts in a fixed order: offset field, size field, the file beside the patch.
local PART_FIELDS = {{16, 56, ''}, {24, 60, '.stream'}, {32, 64, '.gpu_resources'}}
local PARTS = {main = {1, ''}, stream = {3, '.stream'}, gpu = {5, '.gpu_resources'}}
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

-- A running Adler-32 over byte arrays and strings.
local function checksum()
    local a, b = 1, 0
    local self = {}
    function self.bytes(p, size)
        for i = 0, size - 1 do
            a = (a + p[i]) % 65521
            b = (b + a) % 65521
        end
    end
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

-- Adds an indexed patch's entries to sum: its file name, each entry's 80 bytes and the bytes of each of its parts
-- up to SMALL, in file order.
local function sum_entries(files, patch, sum, scratch, yield)
    local t = patch.toc
    local handles = {}
    local ok, why = pcall(function()
        for i = 0, t.count - 1 do
            if t.nexts[i] ~= UNINDEXED then
                local o = t.base + TOC_FILE * i
                sum.text(patch.file)
                sum.bytes(t.raw + o, TOC_FILE)
                for _, field in ipairs(PART_FIELDS) do
                    local at, size = u64(t.raw, o + field[1]), u32(t.raw, o + field[2])
                    if size > 0 and size <= Patches.SMALL then
                        local name = patch.file .. field[3]
                        handles[name] = handles[name] or files.open(name)
                        local buffer = scratch(size)
                        files.read(handles[name], at, size, buffer)
                        sum.bytes(buffer, size)
                    end
                end
                yield()
            end
        end
    end)
    for _, handle in pairs(handles) do files.close(handle) end
    if not ok then error(why, 0) end
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
            ok = pcall(sum_entries, files, patch, sum, scratch, yield)
            if ok then
                out.patches[#out.patches + 1] = patch
                out.entries = out.entries + toc.indexed
            end
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

-- Adler-32 over p[0 .. size - 1] from (a, b), reduced every 4,096 bytes (the sums stay exact): the hot loop of a
-- content hash, left to compile (about 1 ms per MB outside the game).
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

Patches.CHUNK = 65536
-- A record's parts: {offset field, size field, the file beside the patch} (record_in's layout).
local RECORD_PARTS = {{1, 2, ''}, {3, 4, '.stream'}, {5, 6, '.gpu_resources'}}

-- A patch record's content hash, 'bytes:adler32' over its three parts in order, read in CHUNK pieces from the patch
-- files with yield() after each. files: the adapter on the patch folder; scratch: a grower (src/slim.lua).
function Patches.content_hash(files, record, scratch, yield)
    local a, b, total = 1, 0, 0
    for _, part in ipairs(RECORD_PARTS) do
        local at, size = record[part[1]], record[part[2]]
        if size and size > 0 then
            local handle = files.open(record.file .. part[3])
            local ok, why = pcall(function()
                for done = 0, size - 1, Patches.CHUNK do
                    local n = math.min(Patches.CHUNK, size - done)
                    local buffer = scratch(n)
                    files.read(handle, at + done, n, buffer)
                    a, b = adler(buffer, n, a, b)
                    if yield then yield() end
                end
            end)
            files.close(handle)
            if not ok then error(why, 0) end
            total = total + size
        end
    end
    return string.format('%d:%08x', total, b * 65536 + a)
end

-- The job's reader: slim (src/slim.lua's reader) with the patches of index first; files: the adapter on the folder
-- holding them. locate(archive, name, type) -> a record (a patch's carries its file), part_size, part, close; base:
-- slim itself (the archived resources, for comparing a patched LUT with its original); slim's other fields as they are.
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
                         Patches.record, Patches.content_hash, Patches.over}) do
        jit.off(fn, true)
    end
end

return Patches
